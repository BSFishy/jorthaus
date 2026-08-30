{
  description = "jorthaus v2 homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    disko.url = "github:nix-community/disko";
    agenix.url = "github:ryantm/agenix";

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs = {
        nixpkgs.follows = "";
        home-manager.follows = "";
      };
    };
  };

  outputs =
    inputs@{
      agenix,
      flake-parts,
      nixpkgs,
      ...
    }:
    let
      lib = nixpkgs.lib;
      rawHostInventory = import ./nix/hosts;
      evalHost =
        name:
        (lib.evalModules {
          specialArgs = {
            inherit name;
          };
          modules = [
            ./nix/hosts/schema.nix
            rawHostInventory.${name}
          ];
        }).config;
      hostInventory = lib.mapAttrs (name: _: evalHost name) rawHostInventory;
      hostNames = builtins.attrNames hostInventory;
      mkHost =
        name:
        let
          host = hostInventory.${name} // {
            inherit name;
          };
        in
        lib.nixosSystem {
          system = host.system;
          specialArgs = {
            inherit inputs host hostInventory;
          };
          modules = [
            ./nix/modules
          ];
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { pkgs, system, ... }:
        {
          formatter = pkgs.nixfmt-tree;

          packages = {
            cluster-info = import ./nix/packages/cluster-info.nix {
              inherit pkgs system hostNames;
            };
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              git
              just
              nil
              nixd
              nixfmt-tree
              opentofu
              disko
              nixos-anywhere
              openbao
              agenix.packages.${system}.agenix
              kubectl
              k9s
            ];
          };
        };

      flake = {
        nixosConfigurations = lib.genAttrs hostNames mkHost;
      };
    };
}
