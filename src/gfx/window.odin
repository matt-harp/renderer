package gfx

import "base:runtime"
import "core:log"
import glfw "vendor:glfw"

Window_Error :: enum {
	Initialization_Failed,
	Creation_Failed,
}

glfw_error :: proc "c" (error: i32, description: cstring) {
	context = runtime.default_context()
	log.error(description, error)
}

create_glfw_window :: proc(
	title: cstring,
	resizable := true,
) -> (
	window: glfw.WindowHandle,
	err: Error,
) {
	glfw.SetErrorCallback(glfw_error)
	if !glfw.Init() {
		err = Window_Error.Initialization_Failed
		return
	}
	defer if err != nil {
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
		err = Window_Error.Creation_Failed
		return
	}

	return
}

destroy_glfw_window :: proc(window: glfw.WindowHandle) {
	glfw.DestroyWindow(window)
	glfw.Terminate()
}
