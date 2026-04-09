package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "base:runtime"

import "gfx"

import glfw "vendor:glfw"

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

	last_time := glfw.GetTime()

	for !glfw.WindowShouldClose(renderer.window) {
		width, height := glfw.GetWindowSize(renderer.window)
		glfw.PollEvents()
		time := glfw.GetTime()
		delta_time := f32(time - last_time)
		last_time = time

		camera_update(&camera, renderer.window, delta_time)

		view := camera_get_view_matrix(&camera)

		model :=
			// linalg.matrix4_rotate_f32(f32(time) * 0.5, {0, 1, 0}) *
			linalg.matrix4_scale_f32({1, 1, 1})

		aspect := f32(width) / f32(height)

		proj := gfx.matrix4_perspective_f32(camera.fov * (math.PI / 180.0), aspect, camera.near, camera.far)

		gfx.mvp = proj * view * model
		gfx.inv_view = linalg.inverse(view)
		gfx.inv_proj = linalg.inverse(proj * camera_get_view_matrix(&camera, false))
		gfx.inv_model = linalg.inverse(model)
		gfx.camera_origin = camera.pos

		if draw_err := gfx.draw_frame(&renderer); draw_err != nil {
			log.errorf("Failed to draw frame: %v", draw_err)
			break
		}
	}}
