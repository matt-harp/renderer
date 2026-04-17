package gfx

import "core:log"
import "core:os"

import vk "vendor:vulkan"

import vkb "vkbootstrap"

load_shader_module :: proc(
	r: ^Renderer,
	file_name: string,
) -> (
	module: vk.ShaderModule,
	err: Error,
) {
	bytes, read_err := os.read_entire_file(file_name, context.allocator)
	if read_err != nil {
		log.fatalf("failed to read file %s", file_name)
		return
	}
	defer delete(bytes)

	return create_shader_module(r, bytes)
}

create_shader_module :: proc(r: ^Renderer, code: []u8) -> (module: vk.ShaderModule, err: Error) {
	vertex_module_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}

	vkb.vk_check(vk.CreateShaderModule(r.device.device, &vertex_module_info, nil, &module)) or_return

	return
}

create_graphics_pipeline :: proc(r: ^Renderer) -> (err: Error) {
	module := load_shader_module(r, "shaders/slang.spv") or_return
	defer vk.DestroyShaderModule(r.device.device, module, nil)

	// Dynamic state
	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = cast(u32)len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}

	// State for vertex input, empty for aura
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		// vertexBindingDescriptionCount   = 0,
		// pVertexBindingDescriptions      = nil,
		// vertexAttributeDescriptionCount = u32(len(vert_attr_desc)),
		// pVertexAttributeDescriptions    = raw_data(vert_attr_desc),
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
		width    = cast(f32)r.swapchain.extent.width,
		height   = cast(f32)r.swapchain.extent.height,
		minDepth = 0.0,
		maxDepth = 1.0,
	}

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = r.swapchain.extent,
	}

	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissor,
	}

	depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthCompareOp   = .LESS,
		depthWriteEnable = true,
	}

	// State for rasteriser
	rasteriser := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		lineWidth               = 1.0,
		cullMode                = {.BACK},
		frontFace               = .COUNTER_CLOCKWISE,
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
	pc_range := vk.PushConstantRange {
		stageFlags = {.TASK_EXT, .MESH_EXT, .FRAGMENT},
		offset     = 0,
		size       = size_of(Push_Constants),
	}

	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &r.bindless_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pc_range,
	}

	if res := vk.CreatePipelineLayout(
		r.device.device,
		&pipeline_layout_info,
		nil,
		&r.pipeline_layout,
	); res != .SUCCESS {
		log.fatalf("Failed to create pipeline layout: [%v]", res)
		return
	}

	color_format := r.swapchain.image_format
	pipeline_rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_format,
		depthAttachmentFormat   = .D32_SFLOAT,
	}

	// Create stage info for each shader
	task_stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.TASK_EXT},
		module = module,
		pName  = "taskMain",
	}

	mesh_stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.MESH_EXT},
		module = module,
		pName  = "meshMain",
	}

	fragment_stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = module,
		pName  = "fragmentMain",
	}

	shader_stages := [?]vk.PipelineShaderStageCreateInfo{task_stage_info, mesh_stage_info, fragment_stage_info}

	// pipeline finally
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &pipeline_rendering_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly_info,
		pViewportState      = &viewport_state,
		pDepthStencilState  = &depth_stencil_state,
		pRasterizationState = &rasteriser,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = r.pipeline_layout,
	}

	vkb.vk_check(vk.CreateGraphicsPipelines(
		r.device.device,
		0,
		1,
		&pipeline_info,
		nil,
		&r.graphics_pipeline,
	)) or_return

	return
}
