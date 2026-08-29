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
  nodeDnsName = "${host.hostname}.node.jort.haus";
  pathReplicationRules = [
    {
      locationPrefix = "/buckets/";
      replication = "020";
      volumeGrowthCount = 3;
    }
    {
      locationPrefix = "/buckets/media/";
      replication = "000";
      volumeGrowthCount = 1;
    }
  ];
  tlsAltNames = lib.optionals controlplaneEnabled [
    "seaweed-master.service.jort.haus"
    "seaweed-filer.service.jort.haus"
  ];
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

    topology = {
      dataCenter = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = host.slivers.seaweedfs.topology.dataCenter;
        description = "SeaweedFS data center label for this node.";
      };

      rack = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = host.slivers.seaweedfs.topology.rack;
        description = "SeaweedFS rack label for this node.";
      };
    };

    pathReplication = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            locationPrefix = lib.mkOption {
              type = lib.types.str;
              description = "SeaweedFS filer path prefix to configure.";
            };

            replication = lib.mkOption {
              type = lib.types.str;
              description = "SeaweedFS replication string for writes under this prefix.";
            };

            volumeGrowthCount = lib.mkOption {
              type = lib.types.int;
              description = "Number of physical volumes to grow when this prefix needs capacity.";
            };
          };
        }
      );
      readOnly = true;
      default = pathReplicationRules;
      description = "Path-specific SeaweedFS replication defaults applied through filer configuration.";
    };

    master = {
      address = lib.mkOption {
        type = lib.types.str;
        default = "10.1.11.13";
        description = "SeaweedFS master anycast IPv4 address.";
      };

      dnsName = lib.mkOption {
        type = lib.types.str;
        default = "seaweed-master.service.jort.haus";
        description = "SeaweedFS master anycast DNS name.";
      };

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

    filer = {
      address = lib.mkOption {
        type = lib.types.str;
        default = "10.1.11.14";
        description = "SeaweedFS filer anycast IPv4 address.";
      };

      dnsName = lib.mkOption {
        type = lib.types.str;
        default = "seaweed-filer.service.jort.haus";
        description = "SeaweedFS filer anycast DNS name.";
      };

      masters = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = lib.concatStringsSep "," (
          map (peer: "${peer.hostname}.node.jort.haus:${toString config.jorthaus.seaweedfs.master.port}") controlplaneHosts
        );
        description = "Comma-separated SeaweedFS controlplane master list for filers.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8888;
        description = "SeaweedFS filer HTTP port.";
      };

      grpcPort = lib.mkOption {
        type = lib.types.port;
        default = 18888;
        description = "SeaweedFS filer gRPC port.";
      };

      dir = lib.mkOption {
        type = lib.types.str;
        default = "/srv/seaweedfs/filer";
        description = "SeaweedFS filer local state directory.";
      };

      tomlPath = lib.mkOption {
        type = lib.types.str;
        default = "/run/seaweedfs-filer/filer.toml";
        description = "Rendered SeaweedFS filer configuration path.";
      };
    };

    s3 = {
      httpsPort = lib.mkOption {
        type = lib.types.port;
        default = 8443;
        description = "SeaweedFS S3 HTTPS port.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "10.1.11.15";
        description = "SeaweedFS S3 anycast IPv4 address.";
      };

      dnsName = lib.mkOption {
        type = lib.types.str;
        default = "s3.service.jort.haus";
        description = "SeaweedFS S3 anycast DNS name.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8333;
        description = "SeaweedFS S3 HTTP port.";
      };
    };

    tls = {
      dir = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "/run/seaweedfs-pki";
        description = "Runtime directory containing SeaweedFS internal TLS materials.";
      };

      certFile = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${config.jorthaus.seaweedfs.tls.dir}/cert.pem";
        description = "SeaweedFS internal leaf certificate path.";
      };

      keyFile = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${config.jorthaus.seaweedfs.tls.dir}/key.pem";
        description = "SeaweedFS internal private key path.";
      };

      caFile = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${config.jorthaus.seaweedfs.tls.dir}/ca.pem";
        description = "SeaweedFS internal CA certificate path.";
      };

      commonName = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = nodeDnsName;
        description = "SeaweedFS internal certificate common name for this node.";
      };

      altNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = tlsAltNames;
        description = "Additional DNS SANs requested for the SeaweedFS internal certificate on this node.";
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

