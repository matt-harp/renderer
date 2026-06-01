package main

import "core:log"
import "core:mem"
import "gfx"
import "thirdparty:glTF2"
import meshopt "thirdparty:odin-meshoptimizer"

MAX_VERTICES_PER_MESHLET :: 64
MAX_TRIANGLES_PER_MESHLET :: 124
CONE_WEIGHT :: 0.0

Model :: struct {
	meshes: []Mesh,
	transform: matrix[4,4]f32,
}

Mesh :: struct {
	primitives: []Primitive,
}

Vertex :: struct {
	position: [3]f32,
}

Primitive :: struct {
	vertices:        []Vertex,
	meshlets:        []gfx.Meshlet,
	local_vertices:  []u32,
	local_triangles: []u8,
}

load_model_from_file :: proc(src: string) -> (model: Model, err: bool) {
	model_data, load_err := glTF2.load_from_file(src)
	if load_err != nil {
		return {}, false
	}
	defer glTF2.unload(model_data)

	model.meshes = make([]Mesh, len(model_data.meshes))

	for gl_mesh, mesh_idx in model_data.meshes {
		mesh: Mesh
		mesh.primitives = make([]Primitive, len(gl_mesh.primitives))

		for gl_primitive, prim_idx in gl_mesh.primitives {
			primitive: Primitive
			primitive_positions: [][3]f32

			// Extract Positions
			{
				attr := gl_primitive.attributes["POSITION"]
				accessor := model_data.accessors[attr]
				view := model_data.buffer_views[accessor.buffer_view.(glTF2.Integer)]
				buffer := model_data.buffers[view.buffer]
				raw_bytes: []byte
				if bytes, bytes_ok := buffer.uri.([]byte); bytes_ok {
					raw_bytes = bytes
				}
				offset := view.byte_offset + accessor.byte_offset
				primitive_positions = mem.slice_data_cast(
					[][3]f32,
					raw_bytes[offset:],
				)[:accessor.count]
			}

			// Extract Indices
			primitive_indices: []u16
			{
				accessor := model_data.accessors[gl_primitive.indices.(glTF2.Integer)]
				view := model_data.buffer_views[accessor.buffer_view.(glTF2.Integer)]
				buffer := model_data.buffers[view.buffer]
				raw_bytes: []byte
				if bytes, bytes_ok := buffer.uri.([]byte); bytes_ok {
					raw_bytes = bytes
				}
				offset := view.byte_offset + accessor.byte_offset
				#partial switch accessor.component_type {
				case .Unsigned_Short:
					primitive_indices = mem.slice_data_cast(
						[]u16,
						raw_bytes[offset:],
					)[:accessor.count]
				}
			}

			// Allocate and populate own vertex buffer copy
			primitive.vertices = make([]Vertex, len(primitive_positions))
			for pos, i in primitive_positions {
				primitive.vertices[i] = Vertex {
					position = pos,
				}
			}

			positions_32 := mem.slice_data_cast([]f32, primitive_positions)
			indices_32 := make([]u32, len(primitive_indices))
			defer delete(indices_32)
			for index, i in primitive_indices {
				indices_32[i] = u32(index)
			}

			max_meshlets := meshopt.meshopt_buildMeshletsBound(
				len(primitive_indices),
				MAX_VERTICES_PER_MESHLET,
				MAX_TRIANGLES_PER_MESHLET,
			)

			meshlets := make([dynamic]meshopt.meshopt_Meshlet, uint(max_meshlets))
			defer delete(meshlets)
			meshlet_vertices := make([dynamic]u32, max_meshlets * MAX_VERTICES_PER_MESHLET)
			meshlet_triangles := make([dynamic]u8, max_meshlets * MAX_TRIANGLES_PER_MESHLET * 3)

			built_meshlets := meshopt.meshopt_buildMeshlets(
				raw_data(meshlets),
				raw_data(meshlet_vertices),
				raw_data(meshlet_triangles),
				raw_data(indices_32),
				len(indices_32),
				raw_data(positions_32),
				len(primitive_positions),
				size_of([3]f32),
				MAX_VERTICES_PER_MESHLET,
				MAX_TRIANGLES_PER_MESHLET,
				CONE_WEIGHT,
			)
			resize(&meshlets, built_meshlets)
			log.info("made", built_meshlets, "meshlets")

			for &meshlet in meshlets {
				meshopt.meshopt_optimizeMeshlet(
					&meshlet_vertices[meshlet.vertex_offset],
					&meshlet_triangles[meshlet.triangle_offset],
					uint(meshlet.triangle_count),
					uint(meshlet.vertex_count),
				)
			}

			{
				last := meshlets[len(meshlets) - 1]
				resize(&meshlet_vertices, last.vertex_offset + last.vertex_count)
				resize(&meshlet_triangles, last.triangle_offset + last.triangle_count * 3)
			}

			primitive.meshlets = make([]gfx.Meshlet, len(meshlets))
			for meshlet, i in meshlets {
				bounds := meshopt.meshopt_computeMeshletBounds(
					&meshlet_vertices[meshlet.vertex_offset],
					&meshlet_triangles[meshlet.triangle_offset],
					uint(meshlet.triangle_count),
					raw_data(positions_32),
					len(positions_32),
					size_of(Vertex),
				)
				primitive.meshlets[i] = gfx.Meshlet {
					bounding_sphere = {
						bounds.center[0],
						bounds.center[1],
						bounds.center[2],
						bounds.radius,
					},
					cone_apex       = bounds.cone_apex,
					cone_cutoff     = bounds.cone_cutoff,
					cone_axis       = bounds.cone_axis,
					vertices_offset = meshlet.vertex_offset,
					vertices_count  = u16(meshlet.vertex_count),
					triangle_offset = meshlet.triangle_offset,
					triangle_count  = u16(meshlet.triangle_count),
				}
			}

			primitive.local_vertices = meshlet_vertices[:]
			primitive.local_triangles = meshlet_triangles[:]
			mesh.primitives[prim_idx] = primitive
		}
		model.meshes[mesh_idx] = mesh
	}
	return model, true
}

unload_model :: proc(model: Model) {
	for mesh in model.meshes {
		for primitive in mesh.primitives {
			delete(primitive.vertices)
			delete(primitive.meshlets)
			delete(primitive.local_vertices)
			delete(primitive.local_triangles)
		}
		delete(mesh.primitives)
	}
	delete(model.meshes)
}
