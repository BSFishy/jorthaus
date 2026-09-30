_:

{
  imports = [
    ./etcd.nix
    ./openbao.nix
    ./postgres
    ./valkey.nix
    ./k3s.nix
    ./seaweedfs
    ./victorialogs.nix
    ./fluent-bit.nix
    ./prometheus
    ./xfs-quotas.nix
  ];
}
