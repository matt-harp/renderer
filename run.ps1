slangc shaders/test.slang -target spirv -profile spirv_1_4 -emit-spirv-directly -fvk-use-entrypoint-name -entry vertMain -entry fragMain -o src/slang.spv
odin run src -debug -vet -out:build/engine.exe
