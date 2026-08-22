{ inputs, ... }:

{
  imports = [ inputs.agenix.nixosModules.default ];

  # Use the persisted SSH host keys so agenix can decrypt secrets during
  # activation before /etc/ssh is populated with the runtime key files.
  age.identityPaths = [
    "/persistent/etc/ssh/ssh_host_ed25519_key"
    "/persistent/etc/ssh/ssh_host_rsa_key"
  ];
}
