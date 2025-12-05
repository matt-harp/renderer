{
  description = "Description for the project";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem =
        { pkgs, system, ... }:
        {
          devShells.default = pkgs.mkShell.override { stdenv = pkgs.clangStdenv; } rec {
            nativeBuildInputs = with pkgs; [
              odin
              vulkan-validation-layers
              shader-slang
              glfw
              nixd
              premake5
              libcxx

              renderdoc

              (ols.overrideAttrs (old: {
                postInstall = (old.postInstall or "") + ''
                  cp -r ./builtin $out/bin/builtin
                '';
              }))
            ];

            runtimeDependencies = with pkgs; [
              vulkan-loader
            ];

            VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeDependencies;
          };

          packages.default = pkgs.stdenv.mkDerivation rec {
            pname = "my-odin-app";
            version = "0.1.0";

            # Point this to your Odin source directory (flake root shown here)
            src = ./.;

            nativeBuildInputs = [ pkgs.odin ];

            buildInputs = with pkgs; [
              sdl3
            ];

            buildPhase = ''
              mkdir -p build
              ls
              odin build src -out:build/${pname}
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp build/${pname} $out/bin/
            '';

            runtimeDependencies = with pkgs; [
              vulkan-loader
            ];

            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeDependencies;
          };
        };

      flake = { };
    };
}
