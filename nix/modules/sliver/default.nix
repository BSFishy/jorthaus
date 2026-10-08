_:

{
  imports = [
    ./etcd.nix
    ./openbao.nix
    ./openbao-backup.nix
    ./postgres
    ./pgbouncer.nix
    ./valkey.nix
    ./k3s.nix
    ./seaweedfs
    ./victorialogs.nix
    ./victorialogs-backup.nix
    ./fluent-bit.nix
    ./prometheus
    ./xfs-quotas.nix
  ];
}
