package gfx

import "core:math/linalg"
import "core:mem"
import hm "handle_map"
import vk "vendor:vulkan"

Voxel :: struct {
	color: [4]u8,
}

init_voxel_volume :: proc(r: ^Renderer) {
	size :: 64
	count :: size * size * size
	center := linalg.Vector3f32{size / 2.0, size / 2.0, size / 2.0}
	radius: f32 = size / 2.5

	voxels := make([]Voxel, count)
	defer delete(voxels)

	for z in 0 ..< size {
		for y in 0 ..< size {
			for x in 0 ..< size {
				pos := linalg.Vector3f32{f32(x), f32(y), f32(z)}
				dist := linalg.distance(pos, center)

				idx := x + y * size + z * size * size
				if dist <= radius {
					voxels[idx] = Voxel {
						color = {
							u8((f32(x) / size) * 255),
							u8((f32(y) / size) * 255),
							u8((f32(z) / size) * 255),
							u8(255),
						},
					}
				} else {
					voxels[idx] = Voxel {
						color = {0, 0, 0, 0},
					}
				}
			}
		}
	}

	staging_handle := create_buffer(
		r^,
		Voxel,
		"voxel staging",
		count,
		{.TRANSFER_SRC},
		{.Host_Access_Sequential_Write, .Mapped},
	)
	defer destroy_buffer(r, staging_handle)

	staging_buf := hm.get(r.shader_resources.buffers, staging_handle)
	mem.copy(staging_buf.info.mapped_data, raw_data(voxels), size_of(Voxel) * count)

	r.voxel_volume = create_buffer(
		r^,
		Voxel,
		"voxel volume",
		count,
		{.TRANSFER_DST, .STORAGE_BUFFER},
		{},
	)
	dest_buf := hm.get(r.shader_resources.buffers, r.voxel_volume)

	cb := begin_immediate_submit(r)
	region := vk.BufferCopy {
		srcOffset = 0,
		dstOffset = 0,
		size      = vk.DeviceSize(size_of(Voxel) * count),
	}
	vk.CmdCopyBuffer(cb, staging_buf.buffer, dest_buf.buffer, 1, &region)
	end_immediate_submit(r)

	buffer_info := vk.DescriptorBufferInfo {
		buffer = dest_buf.buffer,
		offset = 0,
		range = dest_buf.info.size,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = r.bindless_set,
		dstBinding      = STORAGE_BUFFER_BINDING,
		dstArrayElement = r.voxel_volume.idx,
		descriptorCount = 1,
		descriptorType  = .STORAGE_BUFFER,
		pBufferInfo     = &buffer_info,
	}
	vk.UpdateDescriptorSets(r.device.device, 1, &write, 0, nil)
}

