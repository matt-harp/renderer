#!/usr/bin/env bash
export MESA_VK_IGNORE_CONFORMANCE_WARNING=true
slangc shaders/test.slang -target spirv -profile spirv_1_4 -emit-spirv-directly -fvk-use-entrypoint-name -entry taskMain -entry meshMain -entry fragmentMain -o shaders/slang.spv
odin build src -debug -vet -out:build/engine -collection:thirdparty=./thirdparty && ./build/engine
