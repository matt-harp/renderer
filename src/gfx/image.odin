package gfx

import vma "thirdparty:odin-vma"
import vk "vendor:vulkan"

GPUImage :: struct {
	image:          vk.Image,
	image_view:     vk.ImageView,
	allocation:     vma.Allocation,
	extent:         vk.Extent3D,
	format:         vk.Format,
	mip_levels:     u32,
	array_layers:   u32,
	current_layout: vk.ImageLayout,
	usage:          vk.ImageUsageFlags,
}

create_image :: proc(
	format: vk.Format,
	extent: vk.Extent3D,
	image_usage_flags: vk.ImageUsageFlags,
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	image_type: vk.ImageType = .D2,
	msaa_samples: vk.SampleCountFlag = ._1,
	tiling: vk.ImageTiling = .OPTIMAL,
	flags: vk.ImageCreateFlags = {},
	alloc_flags: vma.Allocation_Create_Flags = {},
	usage: vma.Memory_Usage = .Gpu_Only,
	debug_name: cstring = nil,
	loc := #caller_location,
) -> GPUImage {
	img_alloc_info := vma.Allocation_Create_Info {
		usage          = usage,
		required_flags = {.DEVICE_LOCAL},
		flags          = alloc_flags,
	}


}
