let
  matt = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOo7iBDgCXP99GA4NStJudsWkZQVaA9iDqDo6IQF2ve";

  gaia-01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJy+bsFZMk1RWtXiEZ95B07dzzOD25rCGt9SghQimLIL";
  gaia-02 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPUMQ1+OgdPrnsuy7MIYuCUJBgrLSnQfygNz80Wbvne+";
  gaia-03 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPxY9m4C39d0v9E2ne4PBNSmffdjePeEyTkENoQJb2kD";

  openbao-hosts = [ matt gaia-01 gaia-02 gaia-03 ];
  postgres-hosts = [ matt gaia-01 gaia-02 gaia-03 ];

  all-nodes = [
    gaia-01
    gaia-02
    gaia-03
  ];
  all = [ matt ] ++ all-nodes;
in
{
  "secrets/acme-vars.age".publicKeys = all;
  "secrets/openbao-key-2026-08-23.age".publicKeys = openbao-hosts;
  "secrets/patroni-postgres-superuser-password.age".publicKeys = postgres-hosts;
  "secrets/patroni-postgres-replication-password.age".publicKeys = postgres-hosts;
}
