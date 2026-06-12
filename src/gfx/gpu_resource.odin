package gfx

import hm "core:container/handle_map"
import vma "thirdparty:odin-vma"
import vk "vendor:vulkan"

import vkb "vkbootstrap"

Buffer_Id :: distinct hm.Handle64

GPUBuffer :: struct {
	handle:     Buffer_Id,
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	info:       vma.Allocation_Info,
	address:    Maybe(vk.DeviceAddress),
	name:       string,
}

Image_Id :: distinct hm.Handle64

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
	buffers:  hm.Static_Handle_Map(1024, GPUBuffer, Buffer_Id),
	images:   hm.Static_Handle_Map(1024, GPUImage, Image_Id),
	samplers: [4]vk.Sampler,
}

SAMPLER_BINDING :: 0
SAMPLED_IMAGE_BINDING :: 1
STORAGE_BUFFER_BINDING :: 2
STORAGE_IMAGE_BINDING :: 3
BUFFER_DEVICE_ADDRESS_BUFFER_BINDING :: 4

init_descriptors :: proc(r: ^Renderer) -> (err: Error) {
	pool_sizes := [?]vk.DescriptorPoolSize {
		{type = .SAMPLER, descriptorCount = u32(len(r.shader_resources.samplers))},
		{type = .SAMPLED_IMAGE, descriptorCount = u32(hm.cap(r.shader_resources.images))},
		{type = .STORAGE_BUFFER, descriptorCount = u32(hm.cap(r.shader_resources.buffers))},
		{type = .STORAGE_IMAGE, descriptorCount = u32(hm.cap(r.shader_resources.images))},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = &pool_sizes[0],
	}
	vkb.vk_check(
		vk.CreateDescriptorPool(r.device.device, &pool_info, nil, &r.bindless_pool),
	) or_return

	flags := [?]vk.DescriptorBindingFlags {
		{},
		{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
		{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
		{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
	}

	flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(flags)),
		pBindingFlags = &flags[0],
	}

	bindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = SAMPLER_BINDING,
			descriptorType = .SAMPLER,
			descriptorCount = u32(len(r.shader_resources.samplers)),
			stageFlags = vk.ShaderStageFlags_ALL,
			pImmutableSamplers = &r.shader_resources.samplers[0],
		},
		{
			binding = SAMPLED_IMAGE_BINDING,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = u32(hm.cap(r.shader_resources.images)),
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = STORAGE_BUFFER_BINDING,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = u32(hm.cap(r.shader_resources.buffers)),
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = STORAGE_IMAGE_BINDING,
			descriptorType = .STORAGE_IMAGE,
			descriptorCount = u32(hm.cap(r.shader_resources.images)),
			stageFlags = vk.ShaderStageFlags_ALL,
		},
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &flags_info,
		bindingCount = u32(len(bindings)),
		pBindings    = &bindings[0],
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

	return
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
	for &sampler in r.shader_resources.samplers {
		vk.DestroySampler(r.device.device, sampler, nil)
	}
}
