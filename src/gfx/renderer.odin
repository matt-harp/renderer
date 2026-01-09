package gfx

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:reflect"
import "vendor:stb/image"

import glfw "vendor:glfw"
import vk "vendor:vulkan"

import vma "thirdparty:odin-vma"
import vkb "vkbootstrap"

MAX_FRAMES_IN_FLIGHT :: 2
MINIMUM_API_VERSION :: vk.API_VERSION_1_3

vk_check :: proc(result: vk.Result, loc := #caller_location) {
	p := context.assertion_failure_proc
	if result != .SUCCESS {
		when ODIN_DEBUG {
			p("vk_check failed", reflect.enum_string(result), loc)
		} else {
			p("vk_check failed", "NOT SUCCESS", loc)
		}
	}
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

	// Assets TODO move to asset manager
	pipeline_layout:       vk.PipelineLayout,
	graphics_pipeline:     vk.Pipeline,

	// gbuffer
	depth_image:           GPUImage,

	// buffers
	vertex_buffer:         GPUBuffer,
	index_buffer:          GPUBuffer,

	// resources
	textures:              [10]GPUImage,
	samplers:              [3]vk.Sampler,

	// bindless
	bindless_layout:       vk.DescriptorSetLayout,
	bindless_pool:         vk.DescriptorPool,
	bindless_set:          vk.DescriptorSet,
}

Push_Constants :: struct {
	mvp:                linalg.Matrix4f32,
	vertex_buffer_addr: vk.DeviceAddress,
	index_buffer_addr:  vk.DeviceAddress,
	texture:            u32,
	sampler:            u32,
}

init_renderer :: proc(r: ^Renderer) -> (ok: bool) {
	init_device(r) or_return

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

	init_descriptors(r) or_return

	sampler := create_sampler(r^)
	r.samplers[0] = sampler

	sampler_info := vk.DescriptorImageInfo {
		sampler = sampler,
	}
	sampler_write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = r.bindless_set,
		dstBinding      = 1,
		dstArrayElement = 0,
		descriptorCount = 1,
		descriptorType  = .SAMPLER,
		pImageInfo      = &sampler_info,
	}
	vk.UpdateDescriptorSets(r.device.device, 1, &sampler_write, 0, nil)

	tex := load_texture_from_file(r, "textures/texture.jpg") or_return
	r.textures[0] = tex

	image_info := vk.DescriptorImageInfo {
		imageView = tex.image_view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	image_write := vk.WriteDescriptorSet {
		sType = .WRITE_DESCRIPTOR_SET,
		dstSet = r.bindless_set,
		dstBinding = 0,
		dstArrayElement = 0,
		descriptorType = .SAMPLED_IMAGE,
		descriptorCount = 1,
		pImageInfo = &image_info,
	}
	vk.UpdateDescriptorSets(r.device.device, 1, &image_write, 0, nil)

	create_graphics_pipeline(r) or_return

	// create gbuffers
	{
		r.vertex_buffer = create_buffer(
			r^,
			Vertex,
			"Vertex Buffer",
			len(vertices),
			{.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS},
			{.Host_Access_Sequential_Write, .Mapped},
		)
		mem.copy(r.vertex_buffer.info.mapped_data, raw_data(vertices), int(r.vertex_buffer.info.size))
		r.index_buffer = create_buffer(
			r^,
			u32,
			"Index Buffer",
			len(indices),
			{.INDEX_BUFFER, .SHADER_DEVICE_ADDRESS},
			{.Host_Access_Sequential_Write, .Mapped},
		)
		mem.copy(r.index_buffer.info.mapped_data, raw_data(indices), int(r.index_buffer.info.size))

		extent := vk.Extent3D{r.swapchain.extent.width, r.swapchain.extent.height, 1}
		r.depth_image = create_image(r^, "Depth Image", .D32_SFLOAT, extent, {.DEPTH_STENCIL_ATTACHMENT})
	}

	return true
}

destroy_renderer :: proc(r: ^Renderer) {
	vk.DeviceWaitIdle(r.device.device)

	destroy_image(r, r.textures[0])
	destroy_image(r, r.depth_image)
	destroy_buffer(r, r.index_buffer)
	destroy_buffer(r, r.vertex_buffer)

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

	vk.DestroyDescriptorSetLayout(r.device.device, r.bindless_layout, nil)
	vk.DestroySampler(r.device.device, r.samplers[0], nil)

	vk.DestroyDescriptorPool(r.device.device, r.bindless_pool, nil)

	destroy_sync_objects(r)

	vk.DestroyCommandPool(r.device.device, r.graphics_command_pool, nil)
	vk.DestroyCommandPool(r.device.device, r.transfer_command_pool, nil)
	vk.DestroyCommandPool(r.device.device, r.imm_command_pool, nil)

	vk.DestroyPipeline(r.device.device, r.graphics_pipeline, nil)
	vk.DestroyPipelineLayout(r.device.device, r.pipeline_layout, nil)

	destroy_swapchain(r)

	vkb.destroy_device(r.device)
	vkb.destroy_physical_device(r.physical_device)
	vkb.destroy_surface(r.instance, r.surface)
	vkb.destroy_instance(r.instance)

	destroy_glfw_window(r.window)
}

init_descriptors :: proc(r: ^Renderer) -> (ok: bool) {
	// 1. Layout Bindings
	bindings := [2]vk.DescriptorSetLayoutBinding {
		{
			binding         = 0, // Textures
			descriptorType  = .SAMPLED_IMAGE,
			descriptorCount = 1000,
			stageFlags      = {.FRAGMENT},
		},
		{
			binding         = 1, // Samplers
			descriptorType  = .SAMPLER,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		},
	}

	// 2. Flags to allow "Partially Bound" (so you don't need 1000 textures to start)
	flags := [2]vk.DescriptorBindingFlags {
		{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}, // For textures
		{}, // For samplers
	}

	flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = 2,
		pBindingFlags = raw_data(&flags),
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &flags_info,
		bindingCount = 2,
		pBindings    = &bindings[0],
		flags        = {.UPDATE_AFTER_BIND_POOL},
	}
	vk.CreateDescriptorSetLayout(r.device.device, &layout_info, nil, &r.bindless_layout)

	// 3. Pool (Must support UPDATE_AFTER_BIND)
	pool_sizes := [2]vk.DescriptorPoolSize {
		{type = .SAMPLED_IMAGE, descriptorCount = 1000},
		{type = .SAMPLER, descriptorCount = 10},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = 2,
		pPoolSizes    = &pool_sizes[0],
	}
	vk.CreateDescriptorPool(r.device.device, &pool_info, nil, &r.bindless_pool)

	// 4. Allocate the one Global Set
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = r.bindless_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &r.bindless_layout,
	}
	vk.AllocateDescriptorSets(r.device.device, &alloc_info, &r.bindless_set)

	return true
}

SwapchainConfig :: struct {
	extent:       vk.Extent2D,
	present_mode: vk.PresentModeKHR,
}

create_swapchain :: proc(r: ^Renderer, config: SwapchainConfig) -> (ok: bool) {
	builder := vkb.create_swapchain_builder(r.device)
	defer vkb.destroy_swapchain_builder(builder)

	vkb.swapchain_builder_set_old_swapchain(builder, r.swapchain)
	vkb.swapchain_builder_set_desired_extent(builder, config.extent.width, config.extent.height)
	// Set default surface format and color space: `B8G8R8A8_SRGB, SRGB_NONLINEAR`
	vkb.swapchain_builder_use_default_format_selection(builder)
	vkb.swapchain_builder_set_desired_present_mode(builder, config.present_mode)

	new_swapchain, err := vkb.swapchain_builder_build(builder)
	if err != nil {
		log.errorf("Failed to build swapchain: %#v", err)
		return
	}
	if r.swapchain != nil {
		vkb.destroy_swapchain(r.swapchain)
	}

	img, img_err := vkb.swapchain_get_images(new_swapchain)
	if img_err != nil {
		log.errorf("Failed to get swapchain images: %#v", img_err)
	}

	img_views, img_views_err := vkb.swapchain_get_image_views(new_swapchain)
	if img_views_err != nil {
		log.errorf("Failed to get swapchain image views: %#v", img_views_err)
	}

	r.swapchain = new_swapchain
	r.swapchain_images = img
	r.swapchain_image_views = img_views

	return true
}

recreate_swapchain :: proc(r: ^Renderer, config: SwapchainConfig) -> (ok: bool) {
	vk.DeviceWaitIdle(r.device.device)

	// clean up old swapchain without destroying it
	vkb.swapchain_destroy_image_views(r.swapchain, r.swapchain_image_views)
	delete(r.swapchain_image_views)
	delete(r.swapchain_images)

	// old swapchain used to create new one
	create_swapchain(r, config) or_return

	return true
}

destroy_swapchain :: proc(r: ^Renderer) {
	vkb.swapchain_destroy_image_views(r.swapchain, r.swapchain_image_views)
	vkb.destroy_swapchain(r.swapchain)
	delete(r.swapchain_images)
	delete(r.swapchain_image_views)
}

get_queues :: proc(r: ^Renderer) -> (ok: bool) {
	graphics_queue, graphics_queue_err := vkb.device_get_queue(r.device, .Graphics)
	if graphics_queue_err != nil {
		log.errorf("Failed to get graphics queue: %#v", graphics_queue_err)
		return
	}

	present_queue, present_queue_err := vkb.device_get_queue(r.device, .Present)
	if present_queue_err != nil {
		log.errorf("Failed to get present queue: %#v", present_queue_err)
		return
	}

	transfer_queue, transfer_queue_err := vkb.device_get_queue(r.device, .Transfer)
	if transfer_queue_err != nil {
		log.errorf("Failed to get transfer queue: %#v", transfer_queue_err)
		return
	}

	r.graphics_queue = graphics_queue
	r.present_queue = present_queue
	r.transfer_queue = transfer_queue

	return true
}

create_sync_objects :: proc(r: ^Renderer) -> (ok: bool) {
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for &frame in r.frames {
		if res := vk.CreateSemaphore(
			r.device.device,
			&semaphore_info,
			nil,
			&frame.swapchain_semaphore,
		); res != .SUCCESS {
			log.errorf("Failed to create frame swapchain semaphore: [%v]", res)
			return
		}

		if res := vk.CreateFence(r.device.device, &fence_info, nil, &frame.render_fence);
		   res != .SUCCESS {
			log.errorf("Failed to create frame render fence: [%v]", res)
			return
		}
	}

	vk.CreateFence(r.device.device, &fence_info, nil, &r.imm_fence)

	image_count := len(r.swapchain_images)
	r.render_semaphores = make([]vk.Semaphore, image_count)
	defer if !ok {
		delete(r.render_semaphores)
	}

	for i in 0 ..< image_count {
		if res := vk.CreateSemaphore(
			r.device.device,
			&semaphore_info,
			nil,
			&r.render_semaphores[i],
		); res != .SUCCESS {
			log.errorf("Failed to create render semaphore: [%v]", res)
			return
		}
	}

	return true
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

	transition_vk_image(
		buffer,
		r.depth_image.image,
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
		imageView   = r.depth_image.image_view,
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

	pc := Push_Constants {
		vertex_buffer_addr = r.vertex_buffer.address.?,
		index_buffer_addr  = r.index_buffer.address.?,
		mvp                = mvp,
		sampler            = 0,
		texture            = 0,
	}
	vk.CmdPushConstants(buffer, r.pipeline_layout, {.VERTEX, .FRAGMENT}, 0, size_of(Push_Constants), &pc)

	vk.CmdSetViewport(buffer, 0, 1, &viewport)
	vk.CmdSetScissor(buffer, 0, 1, &scissor)

	vk.CmdDraw(buffer, u32(len(indices)), 1, 0, 0)

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

begin_immediate_submit :: proc(r: ^Renderer) -> vk.CommandBuffer {
	vk_check(vk.ResetFences(r.device.device, 1, &r.imm_fence))
	vk_check(vk.ResetCommandBuffer(r.imm_command_buffer, {}))

	cmd := r.imm_command_buffer

	cmd_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}

	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))

	return cmd
}

end_immediate_submit :: proc(r: ^Renderer) {
	cmd := r.imm_command_buffer

	vk_check(vk.EndCommandBuffer(cmd))

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
	vk_check(vk.QueueSubmit2(r.graphics_queue, 1, &submit, r.imm_fence))

	vk_check(vk.WaitForFences(r.device.device, 1, &r.imm_fence, true, 9_999_999_999))
}

mvp: linalg.Matrix4f32

Vertex :: struct {
	pos:   [3]f32,
	color: [3]f32,
	uv:    [2]f32,
}

vertices :: []Vertex {
	// Front Face (Z+)
	{pos = {-0.5, -0.5, 0.5}, color = {1, 1, 1}, uv = {0, 1}},
	{pos = {0.5, -0.5, 0.5}, color = {1, 1, 1}, uv = {1, 1}},
	{pos = {0.5, 0.5, 0.5}, color = {1, 1, 1}, uv = {1, 0}},
	{pos = {-0.5, 0.5, 0.5}, color = {1, 1, 1}, uv = {0, 0}},

	// Back Face (Z-)
	{pos = {0.5, -0.5, -0.5}, color = {1, 1, 1}, uv = {0, 1}},
	{pos = {-0.5, -0.5, -0.5}, color = {1, 1, 1}, uv = {1, 1}},
	{pos = {-0.5, 0.5, -0.5}, color = {1, 1, 1}, uv = {1, 0}},
	{pos = {0.5, 0.5, -0.5}, color = {1, 1, 1}, uv = {0, 0}},

	// Top Face (Y+)
	{pos = {-0.5, 0.5, 0.5}, color = {1, 1, 1}, uv = {0, 1}},
	{pos = {0.5, 0.5, 0.5}, color = {1, 1, 1}, uv = {1, 1}},
	{pos = {0.5, 0.5, -0.5}, color = {1, 1, 1}, uv = {1, 0}},
	{pos = {-0.5, 0.5, -0.5}, color = {1, 1, 1}, uv = {0, 0}},

	// Bottom Face (Y-)
	{pos = {-0.5, -0.5, -0.5}, color = {1, 1, 1}, uv = {0, 1}},
	{pos = {0.5, -0.5, -0.5}, color = {1, 1, 1}, uv = {1, 1}},
	{pos = {0.5, -0.5, 0.5}, color = {1, 1, 1}, uv = {1, 0}},
	{pos = {-0.5, -0.5, 0.5}, color = {1, 1, 1}, uv = {0, 0}},

	// Right Face (X+)
	{pos = {0.5, -0.5, 0.5}, color = {1, 1, 1}, uv = {0, 1}},
	{pos = {0.5, -0.5, -0.5}, color = {1, 1, 1}, uv = {1, 1}},
	{pos = {0.5, 0.5, -0.5}, color = {1, 1, 1}, uv = {1, 0}},
	{pos = {0.5, 0.5, 0.5}, color = {1, 1, 1}, uv = {0, 0}},

	// Left Face (X-)
	{pos = {-0.5, -0.5, -0.5}, color = {1, 1, 1}, uv = {0, 1}},
	{pos = {-0.5, -0.5, 0.5}, color = {1, 1, 1}, uv = {1, 1}},
	{pos = {-0.5, 0.5, 0.5}, color = {1, 1, 1}, uv = {1, 0}},
	{pos = {-0.5, 0.5, -0.5}, color = {1, 1, 1}, uv = {0, 0}},
}

// odinfmt: disable
indices :: []u32 {
    0, 1, 2,  0, 2, 3,       // Front Face
    4, 5, 6,  4, 6, 7,       // Back Face
    8, 9, 10, 8, 10, 11,     // Top Face
    12, 13, 14, 12, 14, 15,  // Bottom Face
    16, 17, 18, 16, 18, 19,  // Right Face
    20, 21, 22, 20, 22, 23,  // Left Face
}
// odinfmt: enable


load_texture_from_file :: proc(r: ^Renderer, path: cstring) -> (tex: GPUImage, ok: bool) {
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
	)
	defer destroy_buffer(r, staging)
	mem.copy(staging.info.mapped_data, pixels, img_size)

	// Create the GPU Image
	tex = create_image(r^, "texture", .R8G8B8A8_SRGB, extent, {.TRANSFER_DST, .SAMPLED})

	// copy staging -> image
	cb := begin_immediate_submit(r)

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
	vk.CmdCopyBufferToImage(cb, staging.buffer, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)

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

	return tex, true
}

draw_frame :: proc(r: ^Renderer) -> (ok: bool) {
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
		return
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

	if res := vk.QueueSubmit2(r.graphics_queue, 1, &submit_info, frame.render_fence);
	   res != .SUCCESS {
		log.errorf("failed to submit draw command buffer: [%v]", res)
		return
	}

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
		return
	}

	// When `MAX_FRAMES_IN_FLIGHT` is a power of 2 you can update the current frame without modulo
	// division. Doing a logical "and" operation is a lot cheaper than doing division.
	when (MAX_FRAMES_IN_FLIGHT & (MAX_FRAMES_IN_FLIGHT - 1)) == 0 {
		r.frame_index = (r.frame_index + 1) & (MAX_FRAMES_IN_FLIGHT - 1)
	} else {
		r.frame_index = (r.frame_index + 1) % MAX_FRAMES_IN_FLIGHT
	}

	return true
}
