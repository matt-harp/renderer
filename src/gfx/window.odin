package gfx

import "base:runtime"
import "core:log"
import glfw "vendor:glfw"

glfw_error :: proc "c" (error: i32, description: cstring) {
	context = runtime.default_context()
	log.error(description, error)
}

create_glfw_window :: proc(
	title: cstring,
	resizable := true,
) -> (
	window: glfw.WindowHandle,
	ok: bool,
) {
	glfw.SetErrorCallback(glfw_error)
	if !glfw.Init() {
		return
	}
	defer if !ok {
		glfw.Terminate()
	}

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)

	if !resizable {
		glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	} else {
		glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	}

	window = glfw.CreateWindow(1600, 900, title, nil, nil)
	if window == nil {
		log.errorf("Failed to create a GLFW window")
		return
	}

	return window, true
}

destroy_glfw_window :: proc(window: glfw.WindowHandle) {
	glfw.DestroyWindow(window)
	glfw.Terminate()
}
