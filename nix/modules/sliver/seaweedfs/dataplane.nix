{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.seaweedfs;
  projectDisks = lib.filter (disk: disk.projects ? seaweedfs) host.install.dataDisks;
  projectDefined = projectDisks != [ ];
  projectDisk = if projectDefined then lib.head projectDisks else null;
  quotaEnabled = projectDefined && projectDisk.projects.seaweedfs.enforce;
in
{
  config = lib.mkIf (cfg.enable && cfg.dataplaneEnabled) {
    assertions = [
      {
        assertion = !projectDefined || lib.length projectDisks == 1;
        message = "SeaweedFS requires exactly one data-disk project on ${host.hostname}.";
      }
    ];

    jorthaus.xfsQuota.projects.seaweedfs = lib.mkIf quotaEnabled {
      id = 100;
      fileSystem = projectDisk.mountpoint;
      path = "${projectDisk.mountpoint}/seaweedfs/volume";
      quota = projectDisk.projects.seaweedfs.quota;
    };

    users = {
      groups.seaweedfs = { };

      users.seaweedfs-volume = {
        isSystemUser = true;
        group = "seaweedfs";
      };
    };

    systemd.tmpfiles.rules = map (dir: "d ${dir} 0750 seaweedfs-volume seaweedfs -") cfg.volume.dirs;

    networking.firewall.allowedTCPPorts = [
      cfg.volume.port
      cfg.volume.grpcPort
    ];

    environment.systemPackages = [
      pkgs.seaweedfs
      pkgs.openbao
    ];

    systemd.services.seaweedfs-volume = {
      description = "SeaweedFS volume";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "jorthaus-seaweedfs-pki-renew.service"
      ]
      ++ lib.optionals quotaEnabled [ "xfs_quota-seaweedfs.service" ];
      requires = lib.optionals quotaEnabled [ "xfs_quota-seaweedfs.service" ];
      wants = [
        "network-online.target"
        "jorthaus-seaweedfs-pki-renew.service"
      ];
      unitConfig = {
        RequiresMountsFor = cfg.volume.dirs;
        ConditionPathExists = [
          cfg.tls.certFile
          "${cfg.tls.dir}/jwt.env"
        ];
      };
      serviceConfig = {
        User = "seaweedfs-volume";
        Group = "seaweedfs";
        EnvironmentFile = "${cfg.tls.dir}/jwt.env";
        ExecStart = lib.escapeShellArgs [
          (lib.getExe' pkgs.seaweedfs "weed")
          "volume"
          "-ip=${host.hostname}.node.jort.haus"
          "-ip.bind=${host.ipam.ipv4.address}"
          "-port=${toString cfg.volume.port}"
          "-port.grpc=${toString cfg.volume.grpcPort}"
          "-dir=${lib.concatStringsSep "," cfg.volume.dirs}"
          "-max=${cfg.volume.max}"
          "-master=${cfg.volume.masters}"
          "-dataCenter=${cfg.topology.dataCenter}"
          "-rack=${cfg.topology.rack}"
          "-metricsIp=${host.ipam.ipv4.address}"
        ];
        Restart = "on-failure";
        RuntimeDirectory = "seaweedfs-volume";
        RuntimeDirectoryMode = "0750";
      };
    };
  };
}
