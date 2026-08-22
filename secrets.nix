let
  matt = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOo7iBDgCXP99GA4NStJudsWkZQVaA9iDqDo6IQF2ve";

  gaia-02 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDvSzQw5Qbmf66yODyfcG2iP81U7OH4dcBAuI8gEzOEg";
in
{
  "secrets/acme-vars.age".publicKeys = [ matt gaia-02 ];
}
