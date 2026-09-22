{
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  enabled = host.slivers.fluentBit.enable;
  victoriaLogsHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.victorialogs.enable) (builtins.attrValues hostInventory)
  );
  dataPath = "/var/lib/fluent-bit";
  victoriaLogsUri = "/insert/jsonline?_stream_fields=host,source,kubernetes_namespace,kubernetes_pod,kubernetes_container,stream,journal_unit,journal_identifier,journal_priority,journal_transport&_msg_field=message&_time_field=date";
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = lib.length victoriaLogsHosts == 3;
        message = "Fluent Bit requires exactly three enabled VictoriaLogs replicas.";
      }
    ];

    jorthaus.persistence.directories = [ dataPath ];

    systemd.tmpfiles.rules = [
      "d ${dataPath} 0750 root root -"
      "d ${dataPath}/cursors 0750 root root -"
      "d ${dataPath}/storage 0750 root root -"
    ];

    services.fluent-bit = {
      enable = true;
      graceLimit = 30;
      settings = {
        service = {
          flush = 1;
          grace = 30;
          log_level = "warn";
          parsers_file = "${pkgs.fluent-bit}/etc/fluent-bit/parsers.conf";
          "storage.path" = "${dataPath}/storage";
          "storage.sync" = "full";
          "storage.checksum" = true;
          "storage.backlog.mem_limit" = "128M";
          "storage.max_chunks_up" = 64;
        };
        parsers = [
          {
            name = "kubernetes-log-path";
            format = "regex";
            regex = "^/var/log/pods/(?<kubernetes_namespace>[^_]+)_(?<kubernetes_pod>[^_]+)_[^/]+/(?<kubernetes_container>[^/]+)/(?<kubernetes_restart_count>[0-9]+)\\.log$";
          }
        ];
        pipeline = {
          inputs = [
            {
              name = "systemd";
              tag = "journal.*";
              db = "${dataPath}/cursors/journal.db";
              "db.sync" = "full";
              read_from_tail = true;
              "mem_buf_limit" = "64M";
              "storage.type" = "filesystem";
            }
            {
              name = "tail";
              tag = "kubernetes.*";
              path = "/var/log/pods/*/*/*.log";
              parser = "cri";
              db = "${dataPath}/cursors/kubernetes.db";
              "db.sync" = "full";
              read_from_head = false;
              refresh_interval = 10;
              rotate_wait = 30;
              path_key = "log_file";
              "mem_buf_limit" = "64M";
              "storage.type" = "filesystem";
            }
          ];
          filters = [
            {
              name = "grep";
              match = "journal.*";
              exclude = "_SYSTEMD_UNIT fluent-bit.service";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "MESSAGE message";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "_SYSTEMD_UNIT journal_unit";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "SYSLOG_IDENTIFIER journal_identifier";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "PRIORITY journal_priority";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "_TRANSPORT journal_transport";
            }
            {
              name = "record_modifier";
              match = "journal.*";
              record = "host ${host.hostname}";
            }
            {
              name = "record_modifier";
              match = "journal.*";
              record = "source journald";
            }
            {
              name = "parser";
              match = "kubernetes.*";
              key_name = "log_file";
              parser = "kubernetes-log-path";
              reserve_data = true;
              preserve_key = true;
            }
            {
              name = "modify";
              match = "kubernetes.*";
              copy = "log message";
            }
            {
              name = "record_modifier";
              match = "kubernetes.*";
              record = "host ${host.hostname}";
            }
            {
              name = "record_modifier";
              match = "kubernetes.*";
              record = "source kubernetes";
            }
          ];
          outputs = map (
            peer: {
              name = "http";
              alias = "victorialogs-${peer.hostname}";
              match = "*";
              host = peer.ipam.ipv4.address;
              port = 9428;
              uri = victoriaLogsUri;
              format = "json_lines";
              json_date_key = "date";
              json_date_format = "iso8601";
              compress = "gzip";
              retry_limit = false;
              "storage.total_limit_size" = "10G";
              workers = 1;
            }
          ) victoriaLogsHosts;
        };
      };
    };

    systemd.services.fluent-bit = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ dataPath ];
      preStart = ''
        mkdir -p ${dataPath}/cursors ${dataPath}/storage
        chmod 0750 ${dataPath} ${dataPath}/cursors ${dataPath}/storage
      '';
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "root";
        Group = "root";
        UMask = "0077";
        LimitNOFILE = 65536;
        MemoryHigh = "384M";
        MemoryMax = "512M";
      };
    };
  };
}
