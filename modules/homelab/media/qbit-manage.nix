{ config, lib, pkgs, ... }:

let
  cfg = config.homelab;
  qbm = cfg.qbitManage;

  renderedConfig = pkgs.writeText "qbit-manage-config.yml" ''
    commands:
      dry_run: ${if qbm.dryRun then "True" else "False"}
      recheck: False
      cat_update: False
      tag_update: False
      rem_unregistered: ${if qbm.removeUnregistered then "True" else "False"}
      tag_tracker_error: False
      rem_orphaned: ${if qbm.removeOrphaned then "True" else "False"}
      tag_nohardlinks: False
      share_limits: False
      skip_qb_version_check: False
      skip_cleanup: True

    qbt:
      host: "127.0.0.1:${toString cfg.qbittorrent.webuiPort}"

    settings:
      force_auto_tmm: False
      cat_filter_completed: True
      share_limits_filter_completed: True
      tag_nohardlinks_filter_completed: True
      rem_unregistered_filter_completed: False
      cat_update_all: True
      disable_qbt_default_share_limits: True
      tag_stalled_torrents: False
      rem_unregistered_grace_minutes: 10
      rem_unregistered_max_torrents: 10

    directory:
      root_dir: "${qbm.rootDir}"
      recycle_bin: "${qbm.recycleBinDir}"
      orphaned_dir: "${qbm.orphanedDir}"
      torrents_dir: "${config.services.qbittorrent.profileDir}/qBittorrent/data/BT_backup"

    cat:
      sonarr: "${cfg.qbittorrent.downloadDir}/complete"
      radarr: "${cfg.qbittorrent.downloadDir}/complete"

    tracker:
      other:
        tag:
          - other
  '';
in
{
  options.homelab.qbitManage = {
    enable = lib.mkEnableOption "qbit_manage on the media host";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd calendar expression for qbit_manage runs.";
    };

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether qbit_manage should run in dry-run mode.";
    };

    removeOrphaned = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether qbit_manage should run orphaned-data cleanup logic.";
    };

    removeUnregistered = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether qbit_manage should run unregistered-torrent cleanup logic.";
    };

    rootDir = lib.mkOption {
      type = lib.types.str;
      default = cfg.qbittorrent.downloadDir;
      description = "Root download directory qbit_manage should inspect.";
    };

    recycleBinDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.qbittorrent.downloadDir}/.RecycleBin";
      description = "Recycle bin path qbit_manage should use when not in dry-run mode.";
    };

    orphanedDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.qbittorrent.downloadDir}/orphaned_data";
      description = "Directory qbit_manage should use for orphaned file moves when not in dry-run mode.";
    };
  };

  config = lib.mkIf qbm.enable {
    assertions = [
      {
        assertion = cfg.qbittorrent.enable;
        message = "homelab.qbitManage.enable requires homelab.qbittorrent.enable = true.";
      }
    ];

    systemd.services.qbit-manage = {
      description = "qbit_manage cleanup helper";
      after = [ "qbittorrent.service" "srv-media.mount" ];
      requires = [ "qbittorrent.service" "srv-media.mount" ];
      serviceConfig = {
        Type = "oneshot";
        User = "qbittorrent";
        Group = "media";
        StateDirectory = "qbit-manage";
        WorkingDirectory = "/var/lib/qbit-manage";
        Environment = [ "HOME=/var/lib/qbit-manage" ];
        ExecStartPre = pkgs.writeShellScript "qbit-manage-prestart" ''
          install -d -m 0750 -o qbittorrent -g media /var/lib/qbit-manage
          cp ${renderedConfig} /var/lib/qbit-manage/config.yml
          chown qbittorrent:media /var/lib/qbit-manage/config.yml
          chmod 0640 /var/lib/qbit-manage/config.yml
        '';
        ExecStart = "${lib.getExe pkgs.qbit-manage} --run --web-server=False --config-file /var/lib/qbit-manage/config.yml --log-file /var/lib/qbit-manage/qbit_manage.log";
      };
    };

    systemd.timers.qbit-manage = {
      description = "Run qbit_manage on a schedule";
      wantedBy = [ "timers.target" ];
      partOf = [ "qbit-manage.service" ];
      timerConfig = {
        OnCalendar = qbm.schedule;
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };
  };
}
