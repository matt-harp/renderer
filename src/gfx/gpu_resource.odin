package gfx

import hm "handle_map"
import vma "thirdparty:odin-vma"
import vk "vendor:vulkan"


Buffer_Id :: distinct hm.Handle

GPUBuffer :: struct {
	handle:     Buffer_Id,
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	info:       vma.Allocation_Info,
	address:    Maybe(vk.DeviceAddress),
	name:       string,
}

Image_Id :: distinct hm.Handle

GPUImage :: struct {
	handle:         Image_Id,
	image:          vk.Image,
	image_view:     vk.ImageView,
	allocation:     vma.Allocation,
	extent:         vk.Extent3D,
	format:         vk.Format,
	mip_levels:     u32,
	array_layers:   u32,
	current_layout: vk.ImageLayout,
	usage:          vk.ImageUsageFlags,
	name:           string,
}


GPU_Shader_Resource_Table :: struct {
	buffers:  hm.Handle_Map(GPUBuffer, Buffer_Id, 1024),
	images:   hm.Handle_Map(GPUImage, Image_Id, 1024),
	// samplers: hm.Handle_Map(, 1024),
}

STORAGE_BUFFER_BINDING :: 0
STORAGE_IMAGE_BINDING :: 1
SAMPLED_IMAGE_BINDING :: 2
SAMPLER_BINDING :: 3
BUFFER_DEVICE_ADDRESS_BUFFER_BINDING :: 4

init_descriptors :: proc(r: ^Renderer) -> (ok: bool) {
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .STORAGE_BUFFER, descriptorCount = u32(hm.max(r.shader_resources.buffers))},
		{type = .STORAGE_IMAGE, descriptorCount = u32(hm.max(r.shader_resources.images))},
		{type = .SAMPLED_IMAGE, descriptorCount = u32(hm.max(r.shader_resources.images))},
		// {type = .SAMPLER, descriptorCount = u32(hm.max(r.shader_resources.samplers))},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}
	vk.CreateDescriptorPool(r.device.device, &pool_info, nil, &r.bindless_pool)

	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = STORAGE_BUFFER_BINDING,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = u32(hm.max(r.shader_resources.buffers)),
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = STORAGE_IMAGE_BINDING,
			descriptorType = .STORAGE_IMAGE,
			descriptorCount = u32(hm.max(r.shader_resources.images)),
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = SAMPLED_IMAGE_BINDING,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = u32(hm.max(r.shader_resources.images)),
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		// {
		// 	binding         = SAMPLER_BINDING,
		// 	descriptorType  = .SAMPLER,
		// 	descriptorCount = u32(hm.max(r.shader_resources.samplers)),
		// 	stageFlags      = vk.ShaderStageFlags_ALL,
		// },
	}

	flags := []vk.DescriptorBindingFlags {
		{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
		{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
		{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
	}

	flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(flags)),
		pBindingFlags = raw_data(flags),
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &flags_info,
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
		flags        = {.UPDATE_AFTER_BIND_POOL},
	}
	vk.CreateDescriptorSetLayout(r.device.device, &layout_info, nil, &r.bindless_layout)

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = r.bindless_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &r.bindless_layout,
	}
	vk.AllocateDescriptorSets(r.device.device, &alloc_info, &r.bindless_set)

	return true
}

destroy_descriptors :: proc(r: ^Renderer) {
	vk.DestroyDescriptorSetLayout(r.device.device, r.bindless_layout, nil)
	vk.DestroyDescriptorPool(r.device.device, r.bindless_pool, nil)
}

destroy_gpu_resources :: proc(r: ^Renderer) {
	for &e in r.shader_resources.buffers.items {
		if e.handle.idx == 0 {
			continue
		}
		destroy_buffer_unsafe(r, &e)
	}
	for &e in r.shader_resources.images.items {
		if e.handle.idx == 0 {
			continue
		}
		destroy_image_unsafe(r, &e)
	}
}
