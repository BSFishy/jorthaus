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
        inventory = import ./inventory.nix;
        commonModule = host: {
          _module.args = {
            inherit inputs inventory host;
          };
          networking.hostName = lib.mkDefault host.hostName;
        };
        shared-modules = [
          ./modules/homelab
          ./modules/system
        ];
        mkConfiguration = host:
          lib.nixosSystem {
            system = image-system;
            modules = [
              (commonModule host)
            ] ++ shared-modules ++ host.modules;
          };
        inventory-configurations = lib.mapAttrs (_: mkConfiguration) inventory;
        bootstrap-configuration = lib.nixosSystem {
          system = image-system;
          modules = [
            {
              _module.args = {
                inherit inputs inventory;
                host = {
                  hostName = "bootstrap";
                };
              };
            }
            ./modules/homelab
            ./modules/system
            ./modules/hosts/bootstrap.nix
          ];
        };
        imageTargetKey = host: "${host.proxmox.nodeName}/${host.proxmox.imageDatastore}";
        terraform-hosts = lib.mapAttrs
          (_: host: {
            hostName = host.hostName;
            ipv4 = host.ipv4;
            imageTargetKey = imageTargetKey host;
            proxmox = host.proxmox;
          })
          inventory;
        terraform-image-targets = lib.listToAttrs (
          lib.map
            (host:
              lib.nameValuePair (imageTargetKey host) {
                nodeName = host.proxmox.nodeName;
                imageDatastore = host.proxmox.imageDatastore;
              }
            )
            (builtins.attrValues inventory)
        );
        image-pkgs = import nixpkgs { system = image-system; };
        bootstrap-image = image-pkgs.runCommand "bootstrap-image" { } ''
          set -euo pipefail
          mkdir -p "$out"

          image_file="$(find ${bootstrap-configuration.config.system.build.images.qemu-efi} -maxdepth 1 -type f -name '*.qcow2' | head -n 1)"
          if [ -z "$image_file" ]; then
            echo "could not find qemu-efi image for bootstrap" >&2
            exit 1
          fi

          ln -s "$image_file" "$out/bootstrap.qcow2"
        '';
      in
      {
        inherit inventory;
        nixosConfigurations = inventory-configurations;
        packages.${image-system}.bootstrap-image = bootstrap-image;
        terraform = {
          hosts = terraform-hosts;
          imageTargets = terraform-image-targets;
          vars = {
            hosts = terraform-hosts;
            imageTargets = terraform-image-targets;
          };
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
