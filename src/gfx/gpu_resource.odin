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
