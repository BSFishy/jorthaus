_:

{
  imports = [
    ./etcd.nix
    ./openbao.nix
    ./openbao-backup.nix
    ./postgres
    ./pgbouncer.nix
    ./valkey.nix
    ./nats.nix
    ./k3s.nix
    ./seaweedfs
    ./victorialogs.nix
    ./victorialogs-backup.nix
    ./fluent-bit.nix
    ./forgejo-runner.nix
    ./prometheus
    ./xfs-quotas.nix
  ];
}
