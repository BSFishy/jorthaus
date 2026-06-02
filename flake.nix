{
  description = "jort.haus homelab system configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    inputs@{ self, nixpkgs, flake-utils }:
      let
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
                system = "x86_64-linux";
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
              name = nixpkgs.lib.removeSuffix ".nix" node;
              value = nixpkgs.lib.nixosSystem module;
            }) inventory-entries);
      in
      {
        nixosConfigurations = inventory-configurations;
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
