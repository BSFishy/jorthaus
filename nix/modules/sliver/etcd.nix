{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  enabled = host.slivers.etcd.enable;
  nodeDnsName = "${host.hostname}.node.jort.haus";
  nodeCertName = "node-${host.hostname}";
  certDir = config.security.acme.certs.${nodeCertName}.directory;
  clientPort = 2379;
  peerPort = 2380;
  bootstrapEnvPath = "/srv/etcd/bootstrap.env";
  etcdHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.etcd.enable) (builtins.attrValues hostInventory)
  );
  bootstrapHost = lib.head etcdHosts;
  initialCluster = map (
    peer: "${peer.hostname}=https://${peer.hostname}.node.jort.haus:${toString peerPort}"
  ) etcdHosts;
  etcdWrapper = pkgs.writeShellScript "jorthaus-etcd-wrapper" ''
    set -eu

    if [ ! -e /srv/etcd/member ] && [ -f ${bootstrapEnvPath} ]; then
      set -a
      . ${bootstrapEnvPath}
      set +a
    fi

    exec ${lib.getExe' pkgs.etcd "etcd"}
  '';
  etcdStartCondition = pkgs.writeShellScript "jorthaus-etcd-start-condition" ''
    set -eu

    if [ -e /srv/etcd/member ]; then
      exit 0
    fi

    if [ "${host.hostname}" = "${bootstrapHost.hostname}" ]; then
      exit 0
    fi

    if [ -f ${bootstrapEnvPath} ]; then
      exit 0
    fi

    echo "etcd start skipped until ${bootstrapEnvPath} exists or persisted member state is present" >&2
    exit 1
  '';
in
{
  # TODO: etcd config kinda sucks and i dont really like running it with all
  # this extra machinery around it. currently its only used by patroni. i wanna
  # look into replacing it with consul or zookeeper or similar
  config = lib.mkIf enabled {
    jorthaus.persistence.directories = [
      {
        directory = "/srv/etcd";
        user = "etcd";
        group = "etcd";
        mode = "0700";
      }
    ];

    networking.firewall.allowedTCPPorts = [
      clientPort
      peerPort
    ];

    users.users.etcd.extraGroups = [ "cert" ];

    systemd.services.etcd = {
      after = [ "var-lib-acme.mount" ];
      wants = [ "var-lib-acme.mount" ];
      unitConfig = {
        RequiresMountsFor = [ "/srv/etcd" "/var/lib/acme" ];
        ConditionPathExists = "${certDir}/fullchain.pem";
      };
      serviceConfig = {
        ExecCondition = etcdStartCondition;
        ExecStart = lib.mkForce etcdWrapper;
      };
    };

    services.etcd = {
      enable = true;
      name = host.hostname;
      dataDir = "/srv/etcd";

      listenClientUrls = [ "https://0.0.0.0:${toString clientPort}" ];
      advertiseClientUrls = [ "https://${nodeDnsName}:${toString clientPort}" ];

      listenPeerUrls = [ "https://0.0.0.0:${toString peerPort}" ];
      initialAdvertisePeerUrls = [ "https://${nodeDnsName}:${toString peerPort}" ];

      certFile = "${certDir}/fullchain.pem";
      keyFile = "${certDir}/key.pem";
      peerCertFile = "${certDir}/fullchain.pem";
      peerKeyFile = "${certDir}/key.pem";

      # The initial cluster describes the first bootstrap shape. Persisted etcd
      # state becomes authoritative after bootstrap, so later membership changes
      # use explicit etcdctl member operations instead of inventory churn.
      initialCluster = initialCluster;
      initialClusterState = "new";
      initialClusterToken = "jorthaus-etcd";
    };
  };
}
