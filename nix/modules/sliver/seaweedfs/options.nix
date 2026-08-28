{
  config,
  host,
  hostInventory,
  lib,
  ...
}:
let
  seaweedfsHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.seaweedfs.enable) (builtins.attrValues hostInventory)
  );
  controlplaneHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.seaweedfs.enable && peer.slivers.seaweedfs.role == "controlplane") (
      builtins.attrValues hostInventory
    )
  );
  postgresHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.postgres.enable) (builtins.attrValues hostInventory)
  );
  role = host.slivers.seaweedfs.role;
  hasDataDisks = host.install.dataDisks != [ ];
  controlplaneEnabled = role == "controlplane";
  dataplaneEnabled = host.slivers.seaweedfs.enable && hasDataDisks;
in
{
  options.jorthaus.seaweedfs = {
    enable = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = host.slivers.seaweedfs.enable;
      description = "Whether the SeaweedFS sliver is enabled on this node.";
    };

    role = lib.mkOption {
      type = lib.types.enum [
        "controlplane"
        "dataplane"
      ];
      readOnly = true;
      default = role;
      description = "The SeaweedFS role for this node.";
    };

    controlplaneEnabled = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = controlplaneEnabled;
      description = "Whether this node runs SeaweedFS controlplane services.";
    };

    dataplaneEnabled = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = dataplaneEnabled;
      description = "Whether this node runs SeaweedFS dataplane services.";
    };

    hasDataDisks = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = hasDataDisks;
      description = "Whether this node has install-time data disks available for SeaweedFS data.";
    };

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = seaweedfsHosts;
      description = "All enabled SeaweedFS hosts.";
    };

    controlplaneHosts = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = controlplaneHosts;
      description = "All enabled SeaweedFS controlplane hosts.";
    };

    postgresHosts = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = postgresHosts;
      description = "All enabled Postgres hosts relevant to SeaweedFS metadata.";
    };

    postgresBootstrapHost = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      readOnly = true;
      default = if postgresHosts == [ ] then null else lib.head postgresHosts;
      description = "The host that performs one-time SeaweedFS Postgres bootstrap work.";
    };

    master = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 9333;
        description = "SeaweedFS master HTTP port.";
      };

      grpcPort = lib.mkOption {
        type = lib.types.port;
        default = 19333;
        description = "SeaweedFS master gRPC port.";
      };

      dir = lib.mkOption {
        type = lib.types.str;
        default = "/srv/seaweedfs/master";
        description = "SeaweedFS master state directory.";
      };

      peers = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = lib.concatStringsSep "," (
          map (peer: "${peer.hostname}.node.jort.haus:${toString config.jorthaus.seaweedfs.master.port}") controlplaneHosts
        );
        description = "Comma-separated SeaweedFS controlplane peer list.";
      };

      volumeSizeLimitMB = lib.mkOption {
        type = lib.types.int;
        default = 1024;
        description = "SeaweedFS master volume size limit in MiB.";
      };
    };

    volume = {
      masters = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = lib.concatStringsSep "," (
          map (peer: "${peer.hostname}.node.jort.haus:${toString config.jorthaus.seaweedfs.master.port}") controlplaneHosts
        );
        description = "Comma-separated SeaweedFS controlplane master list for volume servers.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "SeaweedFS volume HTTP port.";
      };

      grpcPort = lib.mkOption {
        type = lib.types.port;
        default = 18080;
        description = "SeaweedFS volume gRPC port.";
      };

      dirs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = map (disk: "${disk.mountpoint}/seaweedfs/volume") host.install.dataDisks;
        description = "SeaweedFS volume data directories derived from host data disk mountpoints.";
      };

      max = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = lib.concatStringsSep "," (map (_: "0") config.jorthaus.seaweedfs.volume.dirs);
        description = "Comma-separated per-directory volume limits for SeaweedFS volume servers.";
      };
    };
  };

  config = lib.mkIf host.slivers.seaweedfs.enable {
    assertions = [
      {
        assertion = controlplaneEnabled || dataplaneEnabled;
        message = "The seaweedfs sliver requires either role=\"controlplane\" or at least one install.dataDisks entry.";
      }
      {
        assertion = controlplaneHosts != [ ];
        message = "The seaweedfs sliver requires at least one enabled seaweedfs controlplane node.";
      }
      {
        assertion = (!controlplaneEnabled) || postgresHosts != [ ];
        message = "The seaweedfs controlplane requires at least one enabled postgres node.";
      }
      {
        assertion = (!dataplaneEnabled) || config.jorthaus.seaweedfs.volume.dirs != [ ];
        message = "The seaweedfs dataplane requires at least one derived volume directory.";
      }
    ];
  };
}

