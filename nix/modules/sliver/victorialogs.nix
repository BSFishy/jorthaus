{
  host,
  lib,
  pkgs,
  ...
}:
let
  enabled = host.slivers.victorialogs.enable;
  projectDisks = lib.filter (disk: disk.projects ? victorialogs) host.install.dataDisks;
  projectDefined = projectDisks != [ ];
  projectDisk = if projectDefined then lib.head projectDisks else null;
  quotaEnabled = projectDefined && projectDisk.projects.victorialogs.enforce;
  dataPath = "${projectDisk.mountpoint}/victorialogs";
  statePath = "/var/lib/victorialogs";
  listenAddress = "${host.ipam.ipv4.address}:9428";
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = lib.length projectDisks == 1;
        message = "VictoriaLogs requires exactly one data-disk project on ${host.hostname}.";
      }
      {
        assertion = quotaEnabled;
        message = "VictoriaLogs requires an enforced XFS project quota on ${host.hostname}.";
      }
    ];

    jorthaus.xfsQuota.projects.victorialogs = {
      id = 101;
      fileSystem = projectDisk.mountpoint;
      path = dataPath;
      quota = projectDisk.projects.victorialogs.quota;
    };

    users = {
      groups.victorialogs = { };
      users.victorialogs = {
        isSystemUser = true;
        group = "victorialogs";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${dataPath} 0750 victorialogs victorialogs -"
    ];

    systemd.mounts = [
      {
        what = dataPath;
        where = statePath;
        type = "none";
        options = "bind";
        requires = [ "xfs_quota-victorialogs.service" ];
        after = [ "xfs_quota-victorialogs.service" ];
        before = [ "victorialogs.service" ];
      }
    ];

    networking.firewall.allowedTCPPorts = [ 9428 ];

    environment.systemPackages = [ pkgs.victorialogs ];

    services.victorialogs = {
      enable = true;
      listenAddress = listenAddress;
      stateDir = "victorialogs";
      extraOptions = [
        "-retentionPeriod=31d"
        "-retention.maxDiskSpaceUsageBytes=90GiB"
      ];
    };

    systemd.services.victorialogs = {
      after = [
        "xfs_quota-victorialogs.service"
        "var-lib-victorialogs.mount"
      ];
      requires = [
        "xfs_quota-victorialogs.service"
        "var-lib-victorialogs.mount"
      ];
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "victorialogs";
        Group = "victorialogs";
        PrivateUsers = lib.mkForce false;
        StateDirectory = lib.mkForce null;
        KillSignal = "SIGINT";
        TimeoutStopSec = "2min";
        LimitNOFILE = 65536;
        MemoryHigh = "3G";
        MemoryMax = "4G";
        TasksMax = 256;
      };
    };
  };
}
