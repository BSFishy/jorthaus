_:

{
  imports = [
    ./options.nix
    ./registry.nix
    ./pki.nix
    ./controlplane.nix
    ./provisioner.nix
    ./dataplane.nix
  ];
}
