slangc shaders/test.slang -target spirv -profile spirv_1_4 -emit-spirv-directly -fvk-use-entrypoint-name -entry taskMain -entry meshMain -entry fragmentMain -o shaders/slang.spv

odin build src -debug -out:build/engine.exe -collection:thirdparty=./thirdparty && ./build/engine.exe
