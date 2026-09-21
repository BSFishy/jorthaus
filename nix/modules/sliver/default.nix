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
    ./xfs-quotas.nix
  ];
}
