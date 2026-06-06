{
  description = "jort.haus homelab system configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    inputs@{ nixpkgs, flake-utils, ... }:
      let
        lib = nixpkgs.lib;
        image-system = "x86_64-linux";
        inventory-options = {
          inherit inputs;
        };
        inventory-entries = builtins.attrNames (builtins.readDir ./inventory);
        inventory-configurations = builtins.listToAttrs
          (builtins.map (node:
            let
              base-module = import ./inventory/${node};
              module = {
                # NOTE: unconditionally set x86 linux here. i dont imagine
                # wanting arm linux here, but the assumption is set here.
                system = image-system;
                modules = [
                  {
                    _module.args = inventory-options;
                  }

                  ./modules/guest
                  ./modules/homelab
                  ./modules/system

                  base-module
                ];
              };
            in
            {
              name = lib.removeSuffix ".nix" node;
              value = lib.nixosSystem module;
            }) inventory-entries);
        image-pkgs = import nixpkgs { system = image-system; };
        vm-image-packages = lib.mapAttrs'
          (name: config:
            lib.nameValuePair name (image-pkgs.runCommand "${name}-vm-image" { } ''
              set -euo pipefail
              mkdir -p "$out"

              image_file="$(find ${config.config.system.build.images.qemu-efi} -maxdepth 1 -type f -name '*.qcow2' | head -n 1)"
              if [ -z "$image_file" ]; then
                echo "could not find qemu-efi image for ${name}" >&2
                exit 1
              fi

              ln -s "$image_file" "$out/${name}.qcow2"
            '')
          ) inventory-configurations;
      in
      {
        nixosConfigurations = inventory-configurations;
        packages.${image-system} = vm-image-packages // {
          vm-images = image-pkgs.linkFarm "vm-images"
            (lib.mapAttrsToList (name: package: {
              name = "${name}.qcow2";
              path = "${package}/${name}.qcow2";
            }) vm-image-packages);
        };
      } // flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          devShells.default = pkgs.mkShell {
            buildInputs = [
              pkgs.opentofu
              pkgs.just
            ];
          };
        });
}
