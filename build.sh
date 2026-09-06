#!/usr/bin/env bash
set -euo pipefail

export MESA_VK_IGNORE_CONFORMANCE_WARNING=true

slangc shaders/mesh.slang \
	-g3 \
	-target spirv \
	-fvk-use-entrypoint-name \
	-fvk-use-c-layout \
	-entry taskMain \
	-o shaders/shader.task.spv
slangc shaders/mesh.slang \
	-g3 \
	-target spirv \
	-fvk-use-entrypoint-name \
	-fvk-use-c-layout \
	-entry meshMain \
	-o shaders/shader.mesh.spv
slangc shaders/frag.slang \
	-g3 \
	-target spirv \
	-fvk-use-entrypoint-name \
	-fvk-use-c-layout \
	-entry fragmentMain \
	-o shaders/shader.frag.spv

odin build src -debug -out:build/engine -collection:thirdparty=./thirdparty
