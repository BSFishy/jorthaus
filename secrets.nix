let
  matt = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOo7iBDgCXP99GA4NStJudsWkZQVaA9iDqDo6IQF2ve";

  gaia-01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJy+bsFZMk1RWtXiEZ95B07dzzOD25rCGt9SghQimLIL";
  gaia-02 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDvSzQw5Qbmf66yODyfcG2iP81U7OH4dcBAuI8gEzOEg";

  all-nodes = [ gaia-01 gaia-02 ];
  all = [ matt ] ++ all-nodes;
in
{
  "secrets/acme-vars.age".publicKeys = all;
}
