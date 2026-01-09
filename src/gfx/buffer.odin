package gfx

import vma "thirdparty:odin-vma"
import vk "vendor:vulkan"

GPUBuffer :: struct {
	buffer:     vk.Buffer,
	allocation: vma.Allocation,
	info:       vma.Allocation_Info,
	address:    Maybe(vk.DeviceAddress),
}

create_buffer :: proc(
	r: Renderer,
	$T: typeid,
	#any_int size: vk.DeviceSize = 1,
	vk_usage: vk.BufferUsageFlags,
	vma_flags: vma.Allocation_Create_Flags,
	loc := #caller_location,
) -> (
	buffer: GPUBuffer,
) {
	assert(r.allocator != nil, "VMA needs to be initialized first")

	alloc_size := cast(vk.DeviceSize)(size_of(T) * size)
	buffer_create_info := vk.BufferCreateInfo {
		sType                 = .BUFFER_CREATE_INFO,
		size                  = alloc_size,
		usage                 = vk_usage,
	}

	alloc_create_info := vma.Allocation_Create_Info {
		usage = .Auto,
		flags = vma_flags,
	}

	vk_check(
		vma.create_buffer(
			r.allocator,
			buffer_create_info,
			alloc_create_info,
			&buffer.buffer,
			&buffer.allocation,
			&buffer.info,
		),
	)

	if .SHADER_DEVICE_ADDRESS in vk_usage {
		device_address_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = buffer.buffer,
		}
		buffer.address = vk.GetBufferDeviceAddress(r.device.device, &device_address_info)
	}

	return buffer
}

destroy_buffer :: proc(r: ^Renderer, buffer: GPUBuffer) {
	vma.destroy_buffer(r.allocator, buffer.buffer, buffer.allocation)
}
