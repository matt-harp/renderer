slangc shaders/test.slang `
	-target spirv `
	-fvk-use-entrypoint-name `
	-fvk-use-scalar-layout `
	-entry taskMain `
	-entry meshMain `
	-entry fragmentMain `
	-o shaders/slang.spv `
	-g3

odin build src -debug -out:build/engine.exe -collection:thirdparty=./thirdparty && ./build/engine.exe
