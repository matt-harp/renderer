slangc shaders/test.slang -target spirv -profile spirv_1_4 -emit-spirv-directly -fvk-use-entrypoint-name -entry vertMain -entry fragMain -o shaders/slang.spv

odin build src -debug -vet -out:build/engine.exe -collection:thirdparty=./thirdparty && ./build/engine.exe
