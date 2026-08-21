{
  description = "jorthaus v2 homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs = {
        nixpkgs.follows = "";
        home-manager.follows = "";
      };
    };
  };

  outputs =
    inputs@{ flake-parts, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      hostInventory = import ./nix/hosts;
      hostNames = builtins.attrNames hostInventory;
      mkHost =
        name:
        let
          host = hostInventory.${name} // { inherit name; };
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
          formatter = pkgs.nixfmt-rfc-style;

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
              nixfmt-rfc-style
              opentofu
            ];
          };
        };

      flake = {
        nixosConfigurations = lib.genAttrs hostNames mkHost;
      };
    };
}
