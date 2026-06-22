#!/usr/bin/env bash
export MESA_VK_IGNORE_CONFORMANCE_WARNING=true
slangc shaders/test.slang \
	-target spirv \
	-fvk-use-entrypoint-name \
	-fvk-use-scalar-layout \
	-entry taskMain \
	-entry meshMain \
	-entry fragmentMain \
	-o shaders/slang.spv
odin build src -debug -vet -out:build/engine -collection:thirdparty=./thirdparty && ./build/engine
