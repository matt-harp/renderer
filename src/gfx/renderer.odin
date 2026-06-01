package gfx

import "core:log"
import "core:math/linalg"
import "core:mem"
import "vendor:stb/image"

import glfw "vendor:glfw"
import vk "vendor:vulkan"

import hm "handle_map"
import meshopt "thirdparty:odin-meshoptimizer"
import vma "thirdparty:odin-vma"
import vkb "vkbootstrap"

MAX_FRAMES_IN_FLIGHT :: 1
MINIMUM_API_VERSION :: vk.API_VERSION_1_3

Vma_Error :: union {}

Error :: union {
	vkb.Error,
	Window_Error,
}

// per-frame data
Frame_Data :: struct {
	command_buffer:      vk.CommandBuffer,
	swapchain_semaphore: vk.Semaphore, // signaled when the swapchain gives us an image
	render_fence:        vk.Fence, // signaled when the CPU can reuse this frame
}

Renderer :: struct {
	window:                glfw.WindowHandle,
	instance:              ^vkb.Instance,
	surface:               vk.SurfaceKHR,
	physical_device:       ^vkb.Physical_Device,
	device:                ^vkb.Device,
	allocator:             vma.Allocator,

	// Swapchain
	swapchain:             ^vkb.Swapchain,
	swapchain_images:      []vk.Image,
	swapchain_image_views: []vk.ImageView,
	is_minimized:          bool,
	render_semaphores:     []vk.Semaphore,

	// Queues
	graphics_queue:        vk.Queue,
	present_queue:         vk.Queue,
	transfer_queue:        vk.Queue,
	graphics_command_pool: vk.CommandPool,
	transfer_command_pool: vk.CommandPool,

	// Frame data
	frames:                [MAX_FRAMES_IN_FLIGHT]Frame_Data,
	frame_index:           uint,

	// Immediate submit
	imm_fence:             vk.Fence,
	imm_command_pool:      vk.CommandPool,
	imm_command_buffer:    vk.CommandBuffer,

	// shader resources
	shader_resources:      ^GPU_Shader_Resource_Table,

	// Assets TODO move to asset manager
	pipeline_layout:       vk.PipelineLayout,
	graphics_pipeline:     vk.Pipeline,
	compute_layout:        vk.PipelineLayout,
	compute_pipeline:      vk.Pipeline,

	// gbuffer
	depth_image:           Image_Id,
	meshlet_count:         u32,
	mesh_vertex_buffer:    Buffer_Id,
	meshlet_buffer:        Buffer_Id,
	meshlet_vertex_buffer: Buffer_Id,
	meshlet_index_buffer:  Buffer_Id,
	scene_data_buffer:     Buffer_Id,

	// bindless
	bindless_layout:       vk.DescriptorSetLayout,
	bindless_pool:         vk.DescriptorPool,
	bindless_set:          vk.DescriptorSet,
}

Scene_Data :: struct {
	viewProj:      linalg.Matrix4f32,
	mesh_vertex:   vk.DeviceAddress,
	meshlets:      vk.DeviceAddress,
	vertices:      vk.DeviceAddress,
	indices:       vk.DeviceAddress,
	meshlet_count: uint,
}

Push_Constants :: struct {
	model_matrix: matrix[4,4]f32,
	scene_data: vk.DeviceAddress,
}

init_renderer :: proc(r: ^Renderer) -> (err: Error) {
	init_device(r) or_return
	r.shader_resources = new(GPU_Shader_Resource_Table)
	defer if err != nil {
		free(r.shader_resources)
	}

	width, height := glfw.GetWindowSize(r.window)
	config := SwapchainConfig {
		extent = vk.Extent2D{width = u32(width), height = u32(height)},
		present_mode = .MAILBOX,
	}
	create_swapchain(r, config) or_return

	// create allocator
	{
		vma_funcs := vma.create_vulkan_functions()
		vma_funcs.get_buffer_memory_requirements2_khr = vk.GetBufferMemoryRequirements2
		vma_funcs.get_image_memory_requirements2_khr = vk.GetImageMemoryRequirements2
		vma_funcs.bind_buffer_memory2_khr = vk.BindBufferMemory2
		vma_funcs.bind_image_memory2_khr = vk.BindImageMemory2
		vma_funcs.get_physical_device_memory_properties2_khr =
			vk.GetPhysicalDeviceMemoryProperties2

		allocator_create_info := vma.Allocator_Create_Info {
			flags              = {.Buffer_Device_Address},
			instance           = r.instance.instance,
			vulkan_api_version = MINIMUM_API_VERSION,
			physical_device    = r.physical_device.physical_device,
			device             = r.device.device,
			vulkan_functions   = &vma_funcs,
		}
		if res := vma.create_allocator(allocator_create_info, &r.allocator); res != .SUCCESS {
			log.errorf("Failed to create Vulkan Memory Allocator: [%v]", res)
			return
		}
	}

	get_queues(r) or_return

	// create command pools
	{
		g_idx, _ := vkb.device_get_queue_index(r.device, .Graphics)
		create_info_graphics := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = g_idx,
		}

		if res := vk.CreateCommandPool(
			r.device.device,
			&create_info_graphics,
			nil,
			&r.graphics_command_pool,
		); res != .SUCCESS {
			log.fatalf("Failed to create graphics command pool: [%v]", res)
			return
		}

		if res := vk.CreateCommandPool(
			r.device.device,
			&create_info_graphics,
			nil,
			&r.imm_command_pool,
		); res != .SUCCESS {
			log.fatalf("Failed to create immediate command pool: [%v]", res)
			return
		}

		t_idx, _ := vkb.device_get_queue_index(r.device, .Transfer)
		create_info_transfer := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = t_idx,
		}

		if res := vk.CreateCommandPool(
			r.device.device,
			&create_info_transfer,
			nil,
			&r.transfer_command_pool,
		); res != .SUCCESS {
			log.fatalf("Failed to create transfer command pool: [%v]", res)
			return
		}
	}

	// allocate command buffers
	{
		allocate_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = r.graphics_command_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}

		for &frame in r.frames {
			if res := vk.AllocateCommandBuffers(
				r.device.device,
				&allocate_info,
				&frame.command_buffer,
			); res != .SUCCESS {
				log.fatalf("Failed to allocate command buffers: [%v]", res)
				return
			}
		}

		if res := vk.AllocateCommandBuffers(
			r.device.device,
			&allocate_info,
			&r.imm_command_buffer,
		); res != .SUCCESS {
			log.fatalf("Failed to allocate immediate command buffer: [%v]", res)
			return
		}
	}

	create_sync_objects(r) or_return

	r.shader_resources.samplers[0] = create_sampler(
		r^,
		.LINEAR,
		.LINEAR,
		.LINEAR,
		.REPEAT,
		.REPEAT,
		.REPEAT,
		16.0,
	) or_return
	r.shader_resources.samplers[1] = create_sampler(
		r^,
		.LINEAR,
		.LINEAR,
		.LINEAR,
		.CLAMP_TO_EDGE,
		.CLAMP_TO_EDGE,
		.CLAMP_TO_EDGE,
		16.0,
	) or_return
	r.shader_resources.samplers[2] = create_sampler(
		r^,
		.NEAREST,
		.NEAREST,
		.NEAREST,
		.REPEAT,
		.REPEAT,
		.REPEAT,
	) or_return
	r.shader_resources.samplers[3] = create_sampler(
		r^,
		.NEAREST,
		.NEAREST,
		.NEAREST,
		.CLAMP_TO_EDGE,
		.CLAMP_TO_EDGE,
		.CLAMP_TO_EDGE,
	) or_return

	init_descriptors(r) or_return

	tex_handle := load_texture_from_file(r, "textures/texture.jpg") or_return
	tex := hm.get(r.shader_resources.images, tex_handle)

	image_info := vk.DescriptorImageInfo {
		imageView   = tex.image_view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	image_write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = r.bindless_set,
		dstBinding      = SAMPLED_IMAGE_BINDING,
		dstArrayElement = tex_handle.idx,
		descriptorType  = .SAMPLED_IMAGE,
		descriptorCount = 1,
		pImageInfo      = &image_info,
	}
	vk.UpdateDescriptorSets(r.device.device, 1, &image_write, 0, nil)

	create_graphics_pipeline(r) or_return

	// create gbuffers
	{
		extent := vk.Extent3D{r.swapchain.extent.width, r.swapchain.extent.height, 1}
		r.depth_image = create_image(
			r^,
			"Depth Image",
			.D32_SFLOAT,
			extent,
			{.DEPTH_STENCIL_ATTACHMENT},
		) or_return
	}

	

	return
}

build_scene_data :: proc(r: ^Renderer) {
	scene_data_buf, _ := create_buffer(r^, Scene_Data, "scene data", 1, {.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER}, {.Host_Access_Sequential_Write, .Mapped})
	
	r.scene_data_buffer = scene_data_buf
}

destroy_renderer :: proc(r: ^Renderer) {
	log.debug("begin cleanup")
	vk.DeviceWaitIdle(r.device.device)

	destroy_gpu_resources(r)

	// --- LEAK DETECTION START ---
	stats: vma.Total_Statistics
	vma.calculate_statistics(r.allocator, &stats)

	if stats.total.statistics.allocation_bytes > 0 {
		log.warn("VMA Leaked Memory.")

		stats_string: cstring
		vma.build_stats_string(r.allocator, &stats_string, true)

		if stats_string != nil {
			// You can check if total bytes > 0 here to log only on leaks
			log.infof("VMA Leak Report: %s", stats_string)
			vma.free_stats_string(r.allocator, stats_string)
		}
	}
	// --- LEAK DETECTION END ---

	vma.destroy_allocator(r.allocator)

	destroy_descriptors(r)

	destroy_sync_objects(r)

	vk.DestroyCommandPool(r.device.device, r.graphics_command_pool, nil)
	vk.DestroyCommandPool(r.device.device, r.transfer_command_pool, nil)
	vk.DestroyCommandPool(r.device.device, r.imm_command_pool, nil)

	vk.DestroyPipeline(r.device.device, r.compute_pipeline, nil)
	vk.DestroyPipelineLayout(r.device.device, r.compute_layout, nil)

	destroy_swapchain(r)

	vkb.destroy_device(r.device)
	vkb.destroy_physical_device(r.physical_device)
	vkb.destroy_surface(r.instance, r.surface)
	vkb.destroy_instance(r.instance)

	destroy_glfw_window(r.window)

	hm.delete(&r.shader_resources.buffers)
	free(r.shader_resources)
}

SwapchainConfig :: struct {
	extent:       vk.Extent2D,
	present_mode: vk.PresentModeKHR,
}

create_swapchain :: proc(r: ^Renderer, config: SwapchainConfig) -> (err: Error) {
	builder := vkb.create_swapchain_builder(r.device)
	defer vkb.destroy_swapchain_builder(builder)

	vkb.swapchain_builder_set_old_swapchain(builder, r.swapchain)
	vkb.swapchain_builder_set_desired_extent(builder, config.extent.width, config.extent.height)
	// Set default surface format and color space: `B8G8R8A8_SRGB, SRGB_NONLINEAR`
	vkb.swapchain_builder_use_default_format_selection(builder)
	vkb.swapchain_builder_add_image_usage_flags(builder, {.TRANSFER_DST})
	vkb.swapchain_builder_set_desired_present_mode(builder, config.present_mode)

	new_swapchain := vkb.swapchain_builder_build(builder) or_return
	if r.swapchain != nil {
		vkb.destroy_swapchain(r.swapchain)
	}

	img := vkb.swapchain_get_images(new_swapchain) or_return
	img_views := vkb.swapchain_get_image_views(new_swapchain) or_return

	r.swapchain = new_swapchain
	r.swapchain_images = img
	r.swapchain_image_views = img_views

	return
}

recreate_swapchain :: proc(r: ^Renderer, config: SwapchainConfig) -> (err: Error) {
	vk.DeviceWaitIdle(r.device.device)

	// clean up old swapchain without destroying it
	vkb.swapchain_destroy_image_views(r.swapchain, r.swapchain_image_views)
	delete(r.swapchain_image_views)
	delete(r.swapchain_images)

	// old swapchain used to create new one
	create_swapchain(r, config) or_return

	return
}


destroy_swapchain :: proc(r: ^Renderer) {
	vkb.swapchain_destroy_image_views(r.swapchain, r.swapchain_image_views)
	vkb.destroy_swapchain(r.swapchain)
	delete(r.swapchain_images)
	delete(r.swapchain_image_views)
}

get_queues :: proc(r: ^Renderer) -> (err: Error) {
	r.graphics_queue = vkb.device_get_queue(r.device, .Graphics) or_return
	r.present_queue = vkb.device_get_queue(r.device, .Present) or_return
	r.transfer_queue = vkb.device_get_queue(r.device, .Transfer) or_return

	return
}

create_sync_objects :: proc(r: ^Renderer) -> (err: Error) {
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for &frame in r.frames {
		vkb.vk_check(
			vk.CreateSemaphore(r.device.device, &semaphore_info, nil, &frame.swapchain_semaphore),
		) or_return

		vkb.vk_check(
			vk.CreateFence(r.device.device, &fence_info, nil, &frame.render_fence),
		) or_return
	}

	vkb.vk_check(vk.CreateFence(r.device.device, &fence_info, nil, &r.imm_fence)) or_return

	image_count := len(r.swapchain_images)
	r.render_semaphores = make([]vk.Semaphore, image_count)
	defer if err != nil {
		delete(r.render_semaphores)
	}

	for i in 0 ..< image_count {
		vkb.vk_check(
			vk.CreateSemaphore(r.device.device, &semaphore_info, nil, &r.render_semaphores[i]),
		) or_return
	}

	return
}

destroy_sync_objects :: proc(r: ^Renderer) {
	for &frame in r.frames {
		vk.DestroySemaphore(r.device.device, frame.swapchain_semaphore, nil)
		vk.DestroyFence(r.device.device, frame.render_fence, nil)
	}

	for i in 0 ..< len(r.swapchain_images) {
		vk.DestroySemaphore(r.device.device, r.render_semaphores[i], nil)
	}

	vk.DestroyFence(r.device.device, r.imm_fence, nil)

	delete(r.render_semaphores)
}

record_command_buffer :: proc(
	r: ^Renderer,
	buffer: vk.CommandBuffer,
	image_index: u32,
) -> (
	ok: bool,
) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		// flags = {.ONE_TIME_SUBMIT},
	}

	if res := vk.BeginCommandBuffer(buffer, &begin_info); res != .SUCCESS {
		log.errorf("Failed to begin recording command buffer: [%v]", res)
		return
	}

	transition_vk_image(
		buffer,
		r.swapchain_images[image_index],
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
		{},
		{.COLOR_ATTACHMENT_WRITE},
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
	)

	depth_image := hm.get(r.shader_resources.images, r.depth_image)
	if depth_image == nil {
		panic("depth image isn't valid")
	}
	transition_vk_image(
		buffer,
		depth_image.image,
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		.UNDEFINED,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{.DEPTH},
	)

	clear_color := vk.ClearValue {
		color = {float32 = {0.1, 0.12, 0.32, 1.0}},
	}

	attachment_info := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = r.swapchain_image_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = clear_color,
	}

	depth_clear := vk.ClearValue {
		depthStencil = {depth = 1.0},
	}

	depth_attachment_info := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = depth_image.image_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = depth_clear,
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = r.swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &attachment_info,
		pDepthAttachment = &depth_attachment_info,
	}

	viewport: vk.Viewport
	viewport.x = 0.0
	viewport.y = 0.0
	viewport.width = f32(r.swapchain.extent.width)
	viewport.height = f32(r.swapchain.extent.height)
	viewport.minDepth = 0.0
	viewport.maxDepth = 1.0

	scissor: vk.Rect2D
	scissor.offset = {0, 0}
	scissor.extent = r.swapchain.extent

	vk.CmdBeginRendering(buffer, &rendering_info)

	vk.CmdBindPipeline(buffer, .GRAPHICS, r.graphics_pipeline)

	vk.CmdBindDescriptorSets(buffer, .GRAPHICS, r.pipeline_layout, 0, 1, &r.bindless_set, 0, nil)

	scene_data := Scene_Data {
		viewProj    = projection * view,
		meshlet_count = uint(r.meshlet_count),
		mesh_vertex = hm.get(r.shader_resources.buffers, r.mesh_vertex_buffer).address.?,
		meshlets    = hm.get(r.shader_resources.buffers, r.meshlet_buffer).address.?,
		vertices    = hm.get(r.shader_resources.buffers, r.meshlet_vertex_buffer).address.?,
		indices     = hm.get(r.shader_resources.buffers, r.meshlet_index_buffer).address.?,
	}
	write_to_buffer(r^, r.scene_data_buffer, &scene_data, 0, size_of(Scene_Data))

	pc := Push_Constants {
		scene_data = hm.get(r.shader_resources.buffers, r.scene_data_buffer).address.?,
		model_matrix = model,
	}
	vk.CmdPushConstants(
		buffer,
		r.pipeline_layout,
		{.TASK_EXT, .MESH_EXT, .FRAGMENT},
		0,
		size_of(Push_Constants),
		&pc,
	)

	vk.CmdSetViewport(buffer, 0, 1, &viewport)
	vk.CmdSetScissor(buffer, 0, 1, &scissor)

	wave_count := (r.meshlet_count + 31) / 32
	log.infof("dispatching %d waves for %d meshlets", wave_count, r.meshlet_count)
	vk.CmdDrawMeshTasksEXT(buffer, wave_count, 1, 1)

	vk.CmdEndRendering(buffer)

	transition_vk_image(
		buffer,
		r.swapchain_images[image_index],
		{.COLOR_ATTACHMENT_OUTPUT},
		{.ALL_COMMANDS},
		{.COLOR_ATTACHMENT_WRITE},
		{},
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
	)

	if res := vk.EndCommandBuffer(buffer); res != .SUCCESS {
		log.errorf("Failed to record command buffer: [%v]", res)
		return
	}

	return true
}

begin_immediate_submit :: proc(r: ^Renderer) -> (buffer: vk.CommandBuffer, err: Error) {
	vkb.vk_check(vk.ResetFences(r.device.device, 1, &r.imm_fence)) or_return
	vkb.vk_check(vk.ResetCommandBuffer(r.imm_command_buffer, {})) or_return

	buffer = r.imm_command_buffer

	cmd_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}

	vkb.vk_check(vk.BeginCommandBuffer(buffer, &cmd_begin_info)) or_return

	return
}

end_immediate_submit :: proc(r: ^Renderer) -> (err: Error) {
	cmd := r.imm_command_buffer

	vkb.vk_check(vk.EndCommandBuffer(cmd)) or_return

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	submit := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 0,
		pWaitSemaphoreInfos      = nil,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_info,
		signalSemaphoreInfoCount = 0,
		pSignalSemaphoreInfos    = nil,
	}

	// submit command buffer to the queue and execute it.
	// imm_fence will now block until the graphic commands finish execution
	vkb.vk_check(vk.QueueSubmit2(r.graphics_queue, 1, &submit, r.imm_fence)) or_return

	vkb.vk_check(vk.WaitForFences(r.device.device, 1, &r.imm_fence, true, 9_999_999_999)) or_return

	return
}

model: linalg.Matrix4f32
view: linalg.Matrix4f32
projection: linalg.Matrix4f32
camera_origin: [3]f32

Vertex :: struct {
	pos:   [3]f32,
	color: [3]f32,
	uv:    [2]f32,
}

load_texture_from_file :: proc(r: ^Renderer, path: cstring) -> (image_id: Image_Id, err: Error) {
	w, h, c: i32
	pixels := image.load(path, &w, &h, &c, 4)
	if pixels == nil {
		log.errorf("Failed to load image %s: %s", path, image.failure_reason())
		return
	}
	defer image.image_free(pixels)

	img_size := int(w * h * 4)
	extent := vk.Extent3D{u32(w), u32(h), 1}

	// Create a staging buffer
	staging := create_buffer(
		r^,
		byte,
		"staging buffer",
		img_size,
		{.TRANSFER_SRC},
		{.Host_Access_Sequential_Write, .Mapped},
	) or_return
	defer destroy_buffer(r, staging)
	stag_buf := hm.get(r.shader_resources.buffers, staging)
	mem.copy(stag_buf.info.mapped_data, pixels, img_size)

	// Create the GPU Image
	image_id = create_image(
		r^,
		"texture",
		.R8G8B8A8_SRGB,
		extent,
		{.TRANSFER_DST, .SAMPLED},
	) or_return
	tex := hm.get(r.shader_resources.images, image_id)

	// copy staging -> image
	cb := begin_immediate_submit(r) or_return

	transition_vk_image(
		cb,
		tex.image,
		{.ALL_COMMANDS},
		{.TRANSFER},
		{},
		{.TRANSFER_WRITE},
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
	)

	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent = extent,
	}
	vk.CmdCopyBufferToImage(cb, stag_buf.buffer, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)

	transition_vk_image(
		cb,
		tex.image,
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		{.TRANSFER_WRITE},
		{.SHADER_READ},
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
	)

	end_immediate_submit(r)

	return
}

draw_frame :: proc(r: ^Renderer) -> (err: Error) {
	frame := &r.frames[r.frame_index]
	swap_conf := SwapchainConfig {
		extent       = r.swapchain.extent,
		present_mode = .MAILBOX,
	}

	// wait until ready for present
	vk.WaitForFences(r.device.device, 1, &frame.render_fence, true, max(u64))

	image_index: u32 = 0
	if res := vk.AcquireNextImageKHR(
		r.device.device,
		r.swapchain.swapchain,
		max(u64),
		frame.swapchain_semaphore,
		0,
		&image_index,
	); res == .ERROR_OUT_OF_DATE_KHR {
		return recreate_swapchain(r, swap_conf)
	} else if res != .SUCCESS && res != .SUBOPTIMAL_KHR {
		log.errorf("Failed to acquire swap chain image: [%v]", res)
		counts := vk.DeviceFaultCountsEXT {
			sType = .DEVICE_FAULT_COUNTS_EXT,
		}
		if res == .ERROR_DEVICE_LOST &&
		   vk.GetDeviceFaultInfoEXT(r.device.device, &counts, nil) == .SUCCESS {
			info := vk.DeviceFaultInfoEXT {
				sType = .DEVICE_FAULT_INFO_EXT,
			}

			address_infos := make([]vk.DeviceFaultAddressInfoEXT, counts.addressInfoCount)
			vendor_infos := make([]vk.DeviceFaultVendorInfoEXT, counts.vendorInfoCount)
			defer delete(address_infos)
			defer delete(vendor_infos)

			info.pAddressInfos = raw_data(address_infos)
			info.pVendorInfos = raw_data(vendor_infos)

			if vk.GetDeviceFaultInfoEXT(r.device.device, &counts, &info) == .SUCCESS {
				log.errorf("Device Fault: %s", cstring(&info.description[0]))
				for i in 0 ..< counts.addressInfoCount {
					a := address_infos[i]
					log.errorf(
						"  Address Info [%d]: Type %v, Address 0x%x, Precision %v",
						i,
						a.addressType,
						a.reportedAddress,
						a.addressPrecision,
					)
				}
				for i in 0 ..< counts.vendorInfoCount {
					v := vendor_infos[i]
					log.errorf(
						"  Vendor Info [%d]: %s, Code: %v, Data: %v",
						i,
						cstring(&v.description[0]),
						v.vendorFaultCode,
						v.vendorFaultData,
					)
				}
			}
		}
		return vkb.Error(vkb.General_Error{result = res})
	}

	vk.ResetFences(r.device.device, 1, &frame.render_fence)
	vk.ResetCommandBuffer(frame.command_buffer, {})

	record_command_buffer(r, frame.command_buffer, image_index)

	wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = frame.swapchain_semaphore,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = frame.command_buffer,
	}

	signal_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = r.render_semaphores[image_index],
		stageMask = {.ALL_COMMANDS},
	}

	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &wait_info,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal_info,
	}

	vkb.vk_check(vk.QueueSubmit2(r.graphics_queue, 1, &submit_info, frame.render_fence)) or_return

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &r.render_semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = &r.swapchain.swapchain,
		pImageIndices      = &image_index,
	}

	if res := vk.QueuePresentKHR(r.present_queue, &present_info);
	   res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
		return recreate_swapchain(r, swap_conf)
	} else if res != .SUCCESS {
		log.errorf("failed to present swapchain image: [%v]", res)
		return vkb.Error(vkb.General_Error{result = res})
	}

	// When `MAX_FRAMES_IN_FLIGHT` is a power of 2 you can update the current frame without modulo
	// division. Doing a logical "and" operation is a lot cheaper than doing division.
	when (MAX_FRAMES_IN_FLIGHT & (MAX_FRAMES_IN_FLIGHT - 1)) == 0 {
		r.frame_index = (r.frame_index + 1) & (MAX_FRAMES_IN_FLIGHT - 1)
	} else {
		r.frame_index = (r.frame_index + 1) % MAX_FRAMES_IN_FLIGHT
	}

	return
}
