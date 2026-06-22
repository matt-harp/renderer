package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"

import "gfx"

import glfw "vendor:glfw"

Instance :: struct #align (16) {
	model_matrix:    matrix[4, 4]f32,
	meshlet_offset:  u32,
	meshlet_count:   u32,
	_:               [2]u32,
	bounding_sphere: [4]f32, // Not used yet
}

// Mouse input state
last_mouse_x: f64 = 0.0
last_mouse_y: f64 = 0.0
mouse_held: bool = false

camera: Camera

main :: proc() {
	when ODIN_DEBUG {
		logger := log.create_console_logger(opt = {.Level, .Terminal_Color})
		defer log.destroy_console_logger(logger)

		context.logger = logger

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

	renderer: gfx.Renderer
	if err := gfx.init_renderer(&renderer); err != nil {
		log.errorf("Encountered error during renderer init: %v", err)
		return
	}
	defer gfx.destroy_renderer(&renderer)

	camera_init(&camera)


	glfw.SetMouseButtonCallback(
		renderer.window,
		proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
			if button == glfw.MOUSE_BUTTON_LEFT {
				mouse_held = (action == glfw.PRESS)
				// Reset last pos on press to prevent "jumping" when clicking
				if mouse_held {
					last_mouse_x, last_mouse_y = glfw.GetCursorPos(window)
				}
			}
		},
	)
	glfw.SetCursorPosCallback(
		renderer.window,
		proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
			if mouse_held {
				dx := f32(xpos - last_mouse_x)
				dy := f32(ypos - last_mouse_y)

				context = runtime.default_context()
				camera_handle_mouse(&camera, dx, dy)
			}
			last_mouse_x = xpos
			last_mouse_y = ypos
		},
	)

	model, model_load_err := load_model_from_file("boulder_01.glb")
	if !model_load_err {
		log.errorf("couldn't load model")
		return
	}
	prim := model.meshes[0].primitives[0]

	instances := make([]Instance, 16)
	for i := 0; i < 16; i += 1 {
		x := f32(i % 4) * 2.0 - 3.0
		y := f32(i / 4) * 2.0 - 3.0

		instances[i] = Instance {
			model_matrix   = linalg.matrix4_translate_f32(
				{x, y, 0},
			) * linalg.matrix4_scale_f32({3.0, 3.0, 3.0}),
			meshlet_offset = 0,
			meshlet_count  = u32(len(prim.meshlets)),
		}
	}

	instance_buffer, _ := gfx.create_buffer(
		renderer,
		Instance,
		"model instances",
		16,
		{.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		{.Host_Access_Sequential_Write, .Mapped},
	)
	gfx.write_to_buffer(
		renderer,
		instance_buffer,
		raw_data(instances),
		0,
		size_of(Instance) * len(instances),
	)

	vertex_buffer, _ := gfx.create_buffer(
		renderer,
		gfx.Meshlet,
		"mesh vertices",
		len(prim.vertices),
		{.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		{.Host_Access_Sequential_Write, .Mapped},
	)
	gfx.write_to_buffer(
		renderer,
		vertex_buffer,
		raw_data(prim.vertices),
		0,
		size_of(Vertex) * len(prim.vertices),
	)

	meshlet_metadata, _ := gfx.create_buffer(
		renderer,
		gfx.Meshlet,
		"meshlet metadata",
		len(prim.meshlets),
		{.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		{.Host_Access_Sequential_Write, .Mapped},
	)
	gfx.write_to_buffer(
		renderer,
		meshlet_metadata,
		raw_data(prim.meshlets),
		0,
		size_of(gfx.Meshlet) * len(prim.meshlets),
	)

	vertices_buffer, _ := gfx.create_buffer(
		renderer,
		u32,
		"meshlet vertices",
		len(prim.local_vertices),
		{.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		{.Host_Access_Sequential_Write, .Mapped},
	)
	gfx.write_to_buffer(
		renderer,
		vertices_buffer,
		raw_data(prim.local_vertices),
		0,
		size_of(u32) * len(prim.local_vertices),
	)

	index_buffer, _ := gfx.create_buffer(
		renderer,
		u8,
		"meshlet indices",
		len(prim.local_triangles),
		{.SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER},
		{.Host_Access_Sequential_Write, .Mapped},
	)
	gfx.write_to_buffer(
		renderer,
		index_buffer,
		raw_data(prim.local_triangles),
		0,
		size_of(u8) * len(prim.local_triangles),
	)

	renderer.mesh_vertex_buffer = vertex_buffer
	renderer.meshlet_buffer = meshlet_metadata
	renderer.meshlet_vertex_buffer = vertices_buffer
	renderer.meshlet_index_buffer = index_buffer
	renderer.meshlet_count = u32(len(prim.meshlets))
	renderer.instance_buffer = instance_buffer
	renderer.instance_count = u32(len(instances))

	gfx.build_scene_data(&renderer)

	last_time := glfw.GetTime()

	for !glfw.WindowShouldClose(renderer.window) {
		width, height := glfw.GetWindowSize(renderer.window)
		glfw.PollEvents()
		time := glfw.GetTime()
		delta_time := f32(time - last_time)
		last_time = time

		camera_update(&camera, renderer.window, delta_time)

		view := camera_get_view_matrix(&camera)

		aspect := f32(width) / f32(height)

		proj := gfx.matrix4_perspective_f32(
			camera.fov * (math.PI / 180.0),
			aspect,
			camera.near,
			camera.far,
		)

		// gfx.model = model
		gfx.view = view
		gfx.projection = proj
		gfx.camera_origin = camera.pos

		if draw_err := gfx.draw_frame(&renderer); draw_err != nil {
			log.errorf("Failed to draw frame: %v", draw_err)
			break
		}
	}

	unload_model(model)
}
