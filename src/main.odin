package main

import "base:builtin"
import "base:runtime"
// Packages
import "core:fmt"
import "core:log"
import "core:mem"
import glfw "vendor:glfw"
import vk "vendor:vulkan"

// Local packages
import vkb "../thirdparty/odin-vk-bootstrap/vkb"
import vma "../thirdparty/odin-vma"

State :: struct {
	window:          glfw.WindowHandle,
	instance:        ^vkb.Instance,
	surface:         vk.SurfaceKHR,
	physical_device: ^vkb.Physical_Device,
	device:          ^vkb.Device,
	swapchain:       ^vkb.Swapchain,
	allocator:       vma.Allocator,
	is_minimized:    bool,
}

Render_Data :: struct {
	graphics_queue:               vk.Queue,
	present_queue:                vk.Queue,
	swapchain_images:             []vk.Image,
	swapchain_image_views:        []vk.ImageView,
	pipeline_layout:              vk.PipelineLayout,
	graphics_pipeline:            vk.Pipeline,
	command_pool:                 vk.CommandPool,
	command_buffers:              []vk.CommandBuffer,
	vertex_buffer:                vk.Buffer,
	vertex_allocation:            vma.Allocation,
	ready_for_present_semaphores: []vk.Semaphore,
	image_acquired_semaphores:    [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight_fences:             [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	current_frame:                uint,
}

MAX_FRAMES_IN_FLIGHT :: 2
MINIMUM_API_VERSION :: vk.API_VERSION_1_3

glfw_error :: proc "c" (error: i32, description: cstring) {
	context = runtime.default_context()
	fmt.println(description, error)
}
create_window_sdl :: proc(
	window_title: cstring,
	resize := true,
) -> (
	window: glfw.WindowHandle,
	ok: bool,
) {
	glfw.SetErrorCallback(glfw_error)
	if !glfw.Init() {
		return
	}
	defer if !ok {
		glfw.Terminate()
	}

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)

	if !resize {
		glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	}

	window = glfw.CreateWindow(800, 600, window_title, nil, nil)
	if window == nil {
		log.errorf("Failed to create a GLFW window")
		return
	}

	return window, true
}

destroy_window_sdl :: proc(window: glfw.WindowHandle) {
	glfw.DestroyWindow(window)
	glfw.Terminate()
}

device_initialization :: proc(s: ^State) -> (ok: bool) {
	// Window
	s.window = create_window_sdl("Vulkan Triangle", false) or_return
	defer if !ok {
		destroy_window_sdl(s.window)
	}

	// Instance
	instance_builder := vkb.init_instance_builder() or_return
	defer vkb.destroy_instance_builder(&instance_builder)
	vkb.instance_set_minimum_version(&instance_builder, MINIMUM_API_VERSION)

	when ODIN_DEBUG {
		vkb.instance_enable_validation_layers(&instance_builder)
		vkb.instance_use_default_debug_messenger(&instance_builder)

		VK_LAYER_LUNARG_MONITOR :: "VK_LAYER_LUNARG_monitor"

		if vkb.is_layer_available(&instance_builder.info, VK_LAYER_LUNARG_MONITOR) {
			// Displays FPS in the application's title bar. It is only compatible with the
			// Win32 and XCB windowing systems. Mark as not required layer.
			// https://vulkan.lunarg.com/doc/sdk/latest/windows/monitor_layer.html
			when ODIN_OS == .Windows || ODIN_OS == .Linux {
				vkb.instance_enable_layer(&instance_builder, VK_LAYER_LUNARG_MONITOR)
			}
		}
	}

	s.instance = vkb.build_instance(&instance_builder) or_return
	defer if !ok {
		vkb.destroy_instance(s.instance)
	}


	// Surface
	if glfw.CreateWindowSurface(s.instance.handle, s.window, nil, &s.surface) != .SUCCESS {
		log.errorf("glfw couldn't create vulkan surface")
		return
	}
	defer if !ok {
		vkb.destroy_surface(s.instance, s.surface)
	}

	// Physical device
	selector := vkb.init_physical_device_selector(s.instance) or_return
	defer vkb.destroy_physical_device_selector(&selector)

	vkb.selector_set_minimum_version(&selector, MINIMUM_API_VERSION)
	vkb.selector_set_surface(&selector, s.surface)

	s.physical_device = vkb.select_physical_device(&selector) or_return
	defer if !ok {
		vkb.destroy_physical_device(s.physical_device)
	}

	// Device
	device_builder := vkb.init_device_builder(s.physical_device) or_return
	defer vkb.destroy_device_builder(&device_builder)

	// vulkan 1.1 features
	vk11 := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		shaderDrawParameters = true,
	}
	vkb.device_builder_add_p_next(&device_builder, &vk11)

	// vulkan 1.2 features
	vk12 := vk.PhysicalDeviceVulkan12Features {
		sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		bufferDeviceAddress = true,
	}
	vkb.device_builder_add_p_next(&device_builder, &vk12)

	// vulkan 1.3 features
	vk13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		synchronization2 = true,
	}
	vkb.device_builder_add_p_next(&device_builder, &vk13)

	s.device = vkb.build_device(&device_builder) or_return

	return true
}

create_swapchain :: proc(s: ^State, width, height: u32) -> (ok: bool) {
	builder := vkb.init_swapchain_builder(s.device) or_return
	defer vkb.destroy_swapchain_builder(&builder)

	vkb.swapchain_builder_set_old_swapchain(&builder, s.swapchain)
	vkb.swapchain_builder_set_desired_extent(&builder, width, height)
	// Set default surface format and color space: `B8G8R8A8_SRGB, SRGB_NONLINEAR`
	vkb.swapchain_builder_use_default_format_selection(&builder)
	// Use hard VSync, which will limit the FPS to the speed of the monitor
	vkb.swapchain_builder_set_present_mode(&builder, .MAILBOX)

	swapchain := vkb.build_swapchain(&builder) or_return
	if s.swapchain != nil {
		vkb.destroy_swapchain(s.swapchain)
	}
	s.swapchain = swapchain

	return true
}

get_queue :: proc(s: ^State, data: ^Render_Data) -> (ok: bool) {
	data.graphics_queue = vkb.device_get_queue(s.device, .Graphics) or_return
	data.present_queue = vkb.device_get_queue(s.device, .Present) or_return
	return true
}

create_shader_module :: proc(s: ^State, code: []u8) -> (shader_module: vk.ShaderModule, ok: bool) {
	vertex_module_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}

	if res := vk.CreateShaderModule(s.device.handle, &vertex_module_info, nil, &shader_module);
	   res != .SUCCESS {
		log.fatalf("failed to create shader module: [%v]", res)
		return
	}

	return shader_module, true
}

create_graphics_pipeline :: proc(s: ^State, data: ^Render_Data) -> (ok: bool) {
	shader_code := #load("./slang.spv")
	shader_module := create_shader_module(s, shader_code) or_return
	defer vk.DestroyShaderModule(s.device.handle, shader_module, nil)

	// Create stage info for each shader
	vertex_stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.VERTEX},
		module = shader_module,
		pName  = "vertMain",
	}

	fragment_stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = shader_module,
		pName  = "fragMain",
	}

	shader_stages := []vk.PipelineShaderStageCreateInfo{vertex_stage_info, fragment_stage_info}

	// Dynamic state
	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = cast(u32)len(dynamic_states),
		pDynamicStates    = raw_data(dynamic_states),
	}

	// State for vertex input
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &vert_binding_desc,
		vertexAttributeDescriptionCount = u32(len(vert_attr_desc)),
		pVertexAttributeDescriptions    = raw_data(vert_attr_desc),
	}

	// State for assembly
	input_assembly_info := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	// State for viewport scissor
	viewport := vk.Viewport {
		x        = 0.0,
		y        = 0.0,
		width    = cast(f32)s.swapchain.extent.width,
		height   = cast(f32)s.swapchain.extent.height,
		minDepth = 0.0,
		maxDepth = 1.0,
	}

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = s.swapchain.extent,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissor,
	}

	// State for rasteriser
	rasteriser := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		lineWidth               = 1.0,
		cullMode                = {},
		frontFace               = .CLOCKWISE,
		depthBiasEnable         = false,
	}

	// State for multisampling
	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                 = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable   = false,
		rasterizationSamples  = {._1},
		minSampleShading      = 1.0,
		pSampleMask           = nil,
		alphaToCoverageEnable = false,
		alphaToOneEnable      = false,
	}

	// State for colour blending
	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
	}

	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
		blendConstants  = {0.0, 0.0, 0.0, 0.0},
	}

	// Pipeline layout
	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 0,
		pSetLayouts            = nil,
		pushConstantRangeCount = 0,
		pPushConstantRanges    = nil,
	}

	if res := vk.CreatePipelineLayout(
		s.device.handle,
		&pipeline_layout_info,
		nil,
		&data.pipeline_layout,
	); res != .SUCCESS {
		log.fatalf("Failed to create pipeline layout: [%v]", res)
		return
	}

	pipeline_rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = raw_data([]vk.Format{s.swapchain.image_format}),
	}

	// pipeline finally
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &pipeline_rendering_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly_info,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasteriser,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = data.pipeline_layout,
	}

	if res := vk.CreateGraphicsPipelines(
		s.device.handle,
		0,
		1,
		&pipeline_info,
		nil,
		&data.graphics_pipeline,
	); res != .SUCCESS {
		log.fatalf("Failed to create graphics pipeline: [%v]", res)
		return
	}

	return true
}

create_command_pool :: proc(s: ^State, data: ^Render_Data) -> (ok: bool) {
	create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = vkb.device_get_queue_index(s.device, .Graphics) or_return,
	}

	if res := vk.CreateCommandPool(s.device.handle, &create_info, nil, &data.command_pool);
	   res != .SUCCESS {
		log.fatalf("Failed to create command pool: [%v]", res)
		return
	}

	return true
}

create_command_buffers :: proc(s: ^State, data: ^Render_Data) -> (ok: bool) {
	data.command_buffers = make([]vk.CommandBuffer, MAX_FRAMES_IN_FLIGHT)
	defer if !ok {
		delete(data.command_buffers)
	}

	allocate_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = data.command_pool,
		level              = .PRIMARY,
		commandBufferCount = u32(len(data.command_buffers)),
	}

	if res := vk.AllocateCommandBuffers(
		s.device.handle,
		&allocate_info,
		raw_data(data.command_buffers),
	); res != .SUCCESS {
		log.fatalf("Failed to allocate command buffers: [%v]", res)
		return
	}

	return true
}

create_vert_buffer :: proc(s: ^State, data: ^Render_Data) -> (ok: bool) {
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		flags       = {},
		size        = vk.DeviceSize(size_of(Vertex) * len(vertices)),
		usage       = {.VERTEX_BUFFER},
		sharingMode = .EXCLUSIVE,
	}

	alloc_create_info := vma.Allocation_Create_Info {
		usage = .Auto,
		flags = {.Host_Access_Sequential_Write, .Mapped},
	}

	alloc_info: vma.Allocation_Info
	if res := vma.create_buffer(
		s.allocator,
		buffer_info,
		alloc_create_info,
		&data.vertex_buffer,
		&data.vertex_allocation,
		&alloc_info,
	); res != .SUCCESS {
		log.errorf("Error allocating buffer %v", res)
		return false
	}
	vma.set_allocation_name(s.allocator, data.vertex_allocation, "Vertex Buffer")

	mem.copy(alloc_info.mapped_data, raw_data(vertices), size_of(Vertex) * len(vertices))

	return true
}

transition_image_layout :: proc(
	data: ^Render_Data,
	buffer: vk.CommandBuffer,
	image_index: u32,
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
	src_access_mask: vk.AccessFlags2,
	dst_access_mask: vk.AccessFlags2,
	src_stage_mask: vk.PipelineStageFlags2,
	dst_stage_mask: vk.PipelineStageFlags2,
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage_mask,
		srcAccessMask = src_access_mask,
		dstStageMask = dst_stage_mask,
		dstAccessMask = dst_access_mask,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = data.swapchain_images[image_index],
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		pImageMemoryBarriers    = &barrier,
		imageMemoryBarrierCount = 1,
	}
	vk.CmdPipelineBarrier2(buffer, &dependency_info)
}

record_command_buffer :: proc(
	s: ^State,
	data: ^Render_Data,
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

	transition_image_layout(
		data,
		buffer,
		image_index,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
	)

	clear_color := vk.ClearValue {
		color = {float32 = {0.0, 0.0, 0.0, 1.0}},
	}

	attachment_info := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = data.swapchain_image_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = clear_color,
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = s.swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &attachment_info,
	}

	viewport: vk.Viewport
	viewport.x = 0.0
	viewport.y = 0.0
	viewport.width = f32(s.swapchain.extent.width)
	viewport.height = f32(s.swapchain.extent.height)
	viewport.minDepth = 0.0
	viewport.maxDepth = 1.0

	scissor: vk.Rect2D
	scissor.offset = {0, 0}
	scissor.extent = s.swapchain.extent

	vk.CmdBeginRendering(buffer, &rendering_info)
	// vk.CmdBeginRenderPass(buffer, &render_pass_info, .INLINE)

	vk.CmdBindPipeline(buffer, .GRAPHICS, data.graphics_pipeline)
	offset := vk.DeviceSize(0)
	vk.CmdBindVertexBuffers(buffer, 0, 1, &data.vertex_buffer, &offset)

	vk.CmdSetViewport(buffer, 0, 1, &viewport)
	vk.CmdSetScissor(buffer, 0, 1, &scissor)

	vk.CmdDraw(buffer, 3, 1, 0, 0)

	vk.CmdEndRendering(buffer)
	// vk.CmdEndRenderPass(buffer)

	transition_image_layout(
		data,
		buffer,
		image_index,
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_WRITE},
		{},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.ALL_COMMANDS},
	)

	if res := vk.EndCommandBuffer(buffer); res != .SUCCESS {
		log.errorf("Failed to record command buffer: [%v]", res)
		return
	}

	return true
}

create_sync_objects :: proc(s: ^State, data: ^Render_Data) -> (ok: bool) {
	data.ready_for_present_semaphores = make([]vk.Semaphore, len(data.swapchain_images))

	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for i in 0 ..< len(data.swapchain_images) {
		if res := vk.CreateSemaphore(
			s.device.handle,
			&semaphore_info,
			nil,
			&data.ready_for_present_semaphores[i],
		); res != .SUCCESS {
			log.errorf("Failed to create \"ready_for_present\" semaphore: [%v]", res)
			return
		}
	}

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if res := vk.CreateSemaphore(
			s.device.handle,
			&semaphore_info,
			nil,
			&data.image_acquired_semaphores[i],
		); res != .SUCCESS {
			log.errorf("Failed to create \"image_acquired\" semaphore: [%v]", res)
			return
		}

		if res := vk.CreateFence(s.device.handle, &fence_info, nil, &data.in_flight_fences[i]);
		   res != .SUCCESS {
			log.errorf("Failed to create \"in_flight\" fence: [%v]", res)
			return
		}
	}

	return true
}

recreate_swapchain :: proc(s: ^State, data: ^Render_Data) -> (ok: bool) {
	width, height := glfw.GetWindowSize(s.window)

	vk.DeviceWaitIdle(s.device.handle)

	vk.DestroyCommandPool(s.device.handle, data.command_pool, nil)

	delete(data.command_buffers)

	// for &v in data.frame_buffers {
	// 	vk.DestroyFramebuffer(s.device.handle, v, nil)
	// }
	// delete(data.frame_buffers)

	vkb.swapchain_destroy_image_views(s.swapchain, data.swapchain_image_views)
	delete(data.swapchain_images)
	delete(data.swapchain_image_views)

	if !create_swapchain(s, u32(width), u32(height)) {
		return
	}
	// if !create_framebuffers(s, data) {
	// 	return
	// }
	if !create_command_pool(s, data) {
		return
	}
	if !create_command_buffers(s, data) {
		return
	}

	return true
}

draw_frame :: proc(s: ^State, data: ^Render_Data) -> (ok: bool) {
	vk.WaitForFences(
		s.device.handle,
		1,
		&data.in_flight_fences[data.current_frame],
		true,
		max(u64),
	)
	vk.ResetFences(s.device.handle, 1, &data.in_flight_fences[data.current_frame])

	image_index: u32 = 0
	if res := vk.AcquireNextImageKHR(
		s.device.handle,
		s.swapchain.handle,
		max(u64),
		data.image_acquired_semaphores[data.current_frame],
		0,
		&image_index,
	); res == .ERROR_OUT_OF_DATE_KHR {
		return recreate_swapchain(s, data)
	} else if res != .SUCCESS && res != .SUBOPTIMAL_KHR {
		log.errorf("Failed to acquire swap chain image: [%v]", res)
		return
	}

	vk.ResetCommandBuffer(data.command_buffers[data.current_frame], {})
	record_command_buffer(s, data, data.command_buffers[data.current_frame], image_index)

	wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = data.image_acquired_semaphores[data.current_frame],
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = data.command_buffers[data.current_frame],
	}

	signal_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = data.ready_for_present_semaphores[image_index],
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

	if res := vk.QueueSubmit2(
		data.graphics_queue,
		1,
		&submit_info,
		data.in_flight_fences[data.current_frame],
	); res != .SUCCESS {
		log.errorf("failed to submit draw command buffer: [%v]", res)
		return
	}

	swapchains := []vk.SwapchainKHR{s.swapchain.handle}
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &data.ready_for_present_semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = raw_data(swapchains),
		pImageIndices      = &image_index,
	}

	if res := vk.QueuePresentKHR(data.present_queue, &present_info);
	   res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
		return recreate_swapchain(s, data)
	} else if res != .SUCCESS {
		log.errorf("failed to present swapchain image: [%v]", res)
		return
	}

	// When `MAX_FRAMES_IN_FLIGHT` is a power of 2 you can update the current frame without modulo
	// division. Doing a logical "and" operation is a lot cheaper than doing division.
	when (MAX_FRAMES_IN_FLIGHT & (MAX_FRAMES_IN_FLIGHT - 1)) == 0 {
		data.current_frame = (data.current_frame + 1) & (MAX_FRAMES_IN_FLIGHT - 1)
	} else {
		data.current_frame = (data.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	}

	return true
}

cleanup :: proc(s: ^State, data: ^Render_Data) {
	vk.DeviceWaitIdle(s.device.handle)

	vma.destroy_buffer(s.allocator, data.vertex_buffer, data.vertex_allocation)
	vma.destroy_allocator(s.allocator)

	for i in 0 ..< len(data.swapchain_images) {
		vk.DestroySemaphore(s.device.handle, data.ready_for_present_semaphores[i], nil)
	}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.DestroySemaphore(s.device.handle, data.image_acquired_semaphores[i], nil)
		vk.DestroyFence(s.device.handle, data.in_flight_fences[i], nil)
	}

	delete(data.ready_for_present_semaphores)

	vk.FreeCommandBuffers(
		s.device.handle,
		data.command_pool,
		u32(len(data.command_buffers)),
		raw_data(data.command_buffers),
	)

	vk.DestroyCommandPool(s.device.handle, data.command_pool, nil)

	delete(data.command_buffers)
	delete(data.swapchain_images)

	vk.DestroyPipeline(s.device.handle, data.graphics_pipeline, nil)
	vk.DestroyPipelineLayout(s.device.handle, data.pipeline_layout, nil)

	vkb.swapchain_destroy_image_views(s.swapchain, data.swapchain_image_views)
	delete(data.swapchain_image_views)

	vkb.destroy_swapchain(s.swapchain)
	vkb.destroy_device(s.device)
	vkb.destroy_physical_device(s.physical_device)
	vkb.destroy_surface(s.instance, s.surface)
	vkb.destroy_instance(s.instance)

	destroy_window_sdl(s.window)
}

Vertex :: struct {
	pos:   [2]f32,
	color: [3]f32,
}

vert_binding_desc := vk.VertexInputBindingDescription {
	binding   = 0,
	stride    = size_of(Vertex),
	inputRate = .VERTEX,
}

vert_attr_desc := []vk.VertexInputAttributeDescription {
	{binding = 0, location = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
	{
		binding = 0,
		location = 1,
		format = .R32G32B32_SFLOAT,
		offset = u32(offset_of(Vertex, color)),
	},
}

vertices :: []Vertex {
	{{0.0, -0.5}, {1.0, 0.0, 0.0}},
	{{0.5, 0.5}, {0.0, 1.0, 0.0}},
	{{-0.5, 0.5}, {0.0, 0.0, 1.0}},
}

main :: proc() {
	when ODIN_DEBUG {
		logger := log.create_console_logger(opt = {.Level, .Terminal_Color})
		defer log.destroy_console_logger(logger)

		context.logger = logger
		vkb.set_logger(logger)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer mem.tracking_allocator_destroy(&track)

		defer {
			for _, leak in track.allocation_map {
				fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
			}
			for bad_free in track.bad_free_array {
				fmt.printf(
					"%v allocation %p was freed badly\n",
					bad_free.location,
					bad_free.memory,
				)
			}
		}
	}

	state: State
	render_data: Render_Data

	if !device_initialization(&state) {
		return
	}

	width, height := glfw.GetWindowSize(state.window)

	if !create_swapchain(&state, u32(width), u32(height)) {
		return
	}

	if !get_queue(&state, &render_data) {
		return
	}

	if !create_graphics_pipeline(&state, &render_data) {
		return
	}

	render_data.swapchain_images = vkb.swapchain_get_images(state.swapchain)
	render_data.swapchain_image_views = vkb.swapchain_get_image_views(state.swapchain)

	if !create_command_pool(&state, &render_data) {
		return
	}
	if !create_command_buffers(&state, &render_data) {
		return
	}
	if !create_sync_objects(&state, &render_data) {
		return
	}

	vma_vulkan_functions := vma.create_vulkan_functions()
	allocator_create_info := vma.Allocator_Create_Info {
		flags              = {.Buffer_Device_Address},
		instance           = state.instance.handle,
		vulkan_api_version = MINIMUM_API_VERSION,
		physical_device    = state.physical_device.handle,
		device             = state.device.handle,
		vulkan_functions   = &vma_vulkan_functions,
	}
	if res := vma.create_allocator(allocator_create_info, &state.allocator); res != .SUCCESS {
		log.errorf("Failed to create Vulkan Memory Allocator: [%v]", res)
		return
	}
	if !create_vert_buffer(&state, &render_data) {
		return
	}

	// perf_count := sdl.GetPerformanceFrequency()
	// prev_frame := sdl.GetPerformanceCounter()
	main_loop: for !glfw.WindowShouldClose(state.window) {
		glfw.PollEvents()
		if !state.is_minimized {
			if ok := draw_frame(&state, &render_data); !ok {
				log.errorf("Failed to draw frame.")
				break main_loop
			}
		}
	}

	cleanup(&state, &render_data)

	log.info("Exiting...")
}
