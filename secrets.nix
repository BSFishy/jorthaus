let
  matt = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOo7iBDgCXP99GA4NStJudsWkZQVaA9iDqDo6IQF2ve";

  gaia-01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJy+bsFZMk1RWtXiEZ95B07dzzOD25rCGt9SghQimLIL";
  gaia-02 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPUMQ1+OgdPrnsuy7MIYuCUJBgrLSnQfygNz80Wbvne+";
  gaia-03 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPxY9m4C39d0v9E2ne4PBNSmffdjePeEyTkENoQJb2kD";
  gaia-04 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICdirh85WNZ8rtaaRjIr4niOoWa6tnjaU9/Sp6HLVJu7";
  gaia-05 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRhs4WcaW1CHbD/e8zyN+GrAM1io/4leLcXm4OUfpjD";

  openbao-hosts = [
    matt
    gaia-01
    gaia-02
    gaia-03
  ];
  postgres-hosts = [
    matt
    gaia-01
    gaia-02
    gaia-03
  ];
  valkey-hosts = [
    matt
    gaia-01
    gaia-02
    gaia-03
  ];
  seaweedfs-hosts = [
    matt
    gaia-01
    gaia-02
    gaia-03
    gaia-04
    gaia-05
  ];
  seaweedfs-s3-provisioner-hosts = [ gaia-01 ];
  victorialogs-backup-hosts = [ gaia-01 ];
  k3s-hosts = [
    matt
    gaia-01
    gaia-02
    gaia-03
    gaia-04
    gaia-05
  ];
  k3s-datastore-hosts = [
    matt
    gaia-01
    gaia-02
    gaia-03
  ];

  all-nodes = [
    gaia-01
    gaia-02
    gaia-03
    gaia-04
    gaia-05
  ];
  all = [ matt ] ++ all-nodes;
in
{
  "secrets/acme-vars.age".publicKeys = all;
  "secrets/openbao-key-2026-08-23.age".publicKeys = openbao-hosts;
  "secrets/openbao-backup-credentials.age".publicKeys = openbao-hosts;
  "secrets/openbao-backup-approle-role-id.age".publicKeys = openbao-hosts;
  "secrets/openbao-backup-approle-secret-id.age".publicKeys = openbao-hosts;
  "secrets/victorialogs-backup-approle-role-id.age".publicKeys = victorialogs-backup-hosts;
  "secrets/victorialogs-backup-approle-secret-id.age".publicKeys = victorialogs-backup-hosts;

  "secrets/patroni-postgres-superuser-password.age".publicKeys = postgres-hosts;
  "secrets/postgres-exporter-password.age".publicKeys = postgres-hosts;
  "secrets/patroni-postgres-replication-password.age".publicKeys = postgres-hosts;
  "secrets/postgres-wal-g-approle-role-id.age".publicKeys = postgres-hosts;
  "secrets/postgres-wal-g-approle-secret-id.age".publicKeys = postgres-hosts;
  "secrets/valkey-password.age".publicKeys = valkey-hosts;
  "secrets/seaweedfs-approle-role-id.age".publicKeys = seaweedfs-hosts;
  "secrets/seaweedfs-approle-secret-id.age".publicKeys = seaweedfs-hosts;
  "secrets/seaweedfs-s3-provisioner-approle-role-id.age".publicKeys = seaweedfs-s3-provisioner-hosts;
  "secrets/seaweedfs-s3-provisioner-approle-secret-id.age".publicKeys =
    seaweedfs-s3-provisioner-hosts;
  "secrets/seaweedfs-jwt-filer-signing-key.age".publicKeys = seaweedfs-hosts;
  "secrets/k3s-approle-role-id.age".publicKeys = k3s-hosts;
  "secrets/k3s-approle-secret-id.age".publicKeys = k3s-hosts;
  "secrets/k3s-datastore-password.age".publicKeys = k3s-datastore-hosts;
  "secrets/seaweedfs-postgres-password.age".publicKeys = postgres-hosts;

  "secrets/prometheus-kubelet-ca.age".publicKeys = [
    matt
    gaia-01
    gaia-02
  ];
  "secrets/prometheus-kubelet-token.age".publicKeys = [
    matt
    gaia-01
    gaia-02
  ];
  "secrets/prometheus-control-plane-token.age".publicKeys = [
    matt
    gaia-01
    gaia-02
  ];
  "secrets/prometheus-app-metrics-token.age".publicKeys = [
    matt
    gaia-01
    gaia-02
  ];
}
