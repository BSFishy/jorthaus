{ inputs, ... }:

{
  imports = [ inputs.agenix.nixosModules.default ];

  # TODO: Keep agenix limited to bootstrap-time secrets over time. OpenBao
  # should become the steady-state source of truth for service credentials once
  # the cluster is up.

  # Use the persisted SSH host keys so agenix can decrypt secrets during
  # activation before /etc/ssh is populated with the runtime key files.
  age.identityPaths = [
    "/persistent/etc/ssh/ssh_host_ed25519_key"
    "/persistent/etc/ssh/ssh_host_rsa_key"
  ];
}
