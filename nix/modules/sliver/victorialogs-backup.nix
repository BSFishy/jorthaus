{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  victorialogsHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.victorialogs.enable) (builtins.attrValues hostInventory)
  );
  backupHost = if victorialogsHosts == [ ] then null else builtins.head victorialogsHosts;
  roleIdAgeFile = "${toString ../../..}/secrets/victorialogs-backup-approle-role-id.age";
  secretIdAgeFile = "${toString ../../..}/secrets/victorialogs-backup-approle-secret-id.age";
  approleCredentialsPresent =
    builtins.pathExists roleIdAgeFile && builtins.pathExists secretIdAgeFile;
  enabled = backupHost != null && host.hostname == backupHost.hostname && approleCredentialsPresent;
  apiDataPath = "/var/lib/victorialogs";

  endpoint = "http://${host.ipam.ipv4.address}:9428";
  runtimeDirectory = "/run/victorialogs-backup-agent";
  credentialsFile = "${runtimeDirectory}/credentials.env";
  roleIdFile = config.age.secrets.victorialogs-backup-approle-role-id.path;
  secretIdFile = config.age.secrets.victorialogs-backup-approle-secret-id.path;
  repository = "s3:https://s3.us-east-005.backblazeb2.com/jorthaus-victorialogs-backups/restic/victorialogs";
  stateDirectory = "/var/lib/victorialogs-backup";
  stateFile = "${stateDirectory}/last-success-epoch";
  metricsFile = "/run/prometheus-node-exporter/victorialogs-backup.prom";

  backupMetricsCollector = pkgs.writeShellApplication {
    name = "jorthaus-victorialogs-backup-metrics";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      state_file="$1"
      output_file="$2"
      timestamp=0
      if [[ -r "$state_file" ]]; then
        timestamp="$(< "$state_file")"
      fi
      [[ "$timestamp" =~ ^[0-9]+$ ]] || {
        echo "VictoriaLogs backup timestamp state is invalid." >&2
        exit 1
      }
      temporary_file="$(mktemp "''${output_file}.XXXXXX")"
      trap 'rm -f -- "$temporary_file"' EXIT
      {
        printf '%s\n' '# HELP victorialogs_backup_last_success_timestamp_seconds Unix timestamp of the latest successful VictoriaLogs backup.'
        printf '%s\n' '# TYPE victorialogs_backup_last_success_timestamp_seconds gauge'
        printf 'victorialogs_backup_last_success_timestamp_seconds %s\n' "$timestamp"
      } > "$temporary_file"
      chmod 0644 "$temporary_file"
      mv -f -- "$temporary_file" "$output_file"
    '';
  };

  backupRunner = pkgs.writeShellApplication {
    name = "jorthaus-victorialogs-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.util-linux
      pkgs.jq
      pkgs.restic
    ];
    text = ''
      set -euo pipefail
      umask 077

      operation="''${1:-backup}"
      if [[ "$operation" != backup && "$operation" != init && "$operation" != verify ]]; then
        echo "usage: jorthaus-victorialogs-backup [backup|init|verify]" >&2
        exit 2
      fi

      credentials_file=${lib.escapeShellArg credentialsFile}
      [[ -r "$credentials_file" ]] || {
        echo "VictoriaLogs backup credentials are unavailable." >&2
        exit 1
      }
      AWS_ACCESS_KEY_ID="$(jq -er '.b2_application_key_id | select(type == "string" and length > 0)' "$credentials_file")"
      AWS_SECRET_ACCESS_KEY="$(jq -er '.b2_application_key | select(type == "string" and length > 0)' "$credentials_file")"
      RESTIC_PASSWORD="$(jq -er '.restic_password | select(type == "string" and test("^[A-Za-z0-9]{64}$"))' "$credentials_file")"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
      export AWS_DEFAULT_REGION=us-east-005
      export AWS_REGION=us-east-005
      export RESTIC_REPOSITORY=${lib.escapeShellArg repository}
      state_directory=${lib.escapeShellArg stateDirectory}
      state_file=${lib.escapeShellArg stateFile}
      exec 9>"$state_directory/restic.lock"
      flock --exclusive 9
      write_last_success() {
        local timestamp="$1"
        local temporary_file
        [[ "$timestamp" =~ ^[0-9]+$ ]] || {
          echo "VictoriaLogs backup timestamp is invalid." >&2
          exit 1
        }
        temporary_file="$(mktemp "$state_directory/last-success.XXXXXX")"
        printf '%s\n' "$timestamp" > "$temporary_file"
        mv -f -- "$temporary_file" "$state_file"
      }
      retention_args=(
        --group-by
        "host,tags"
        --tag
        victorialogs
        --keep-last 1
        --keep-within-daily 7d
      )

      if [[ "$operation" == init ]]; then
        restic --no-cache init
        exit 0
      fi
      if [[ "$operation" == verify ]]; then
        restic --no-cache check --read-data
        restic --no-cache forget --dry-run "''${retention_args[@]}"
        exit 0
      fi

      endpoint=${lib.escapeShellArg endpoint}
      partition_json="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
        "$endpoint/internal/partition/list")"
      partition_names_raw="$(jq -er 'if type == "array" then .[] | strings | select(test("^[0-9]{8}$")) else error("expected a partition array") end' <<< "$partition_json")" || {
        echo "VictoriaLogs returned no valid partitions." >&2
        exit 1
      }
      mapfile -t partition_names <<< "$partition_names_raw"
      ((''${#partition_names[@]} > 0)) || {
        echo "VictoriaLogs returned no active partitions." >&2
        exit 1
      }

      snapshot_paths=()
      cleanup_snapshots() {
        local failed=0
        local snapshot_path
        local -a remaining=()
        for snapshot_path in "''${snapshot_paths[@]}"; do
          if curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
            --get --data-urlencode "path=$snapshot_path" \
            "$endpoint/internal/partition/snapshot/delete" >/dev/null; then
            continue
          fi
          echo "Failed to remove a temporary VictoriaLogs partition snapshot." >&2
          remaining+=("$snapshot_path")
          failed=1
        done
        snapshot_paths=("''${remaining[@]}")
        return "$failed"
      }
      cleanup_on_exit() {
        local status=$?
        local cleanup_status=0
        trap - EXIT INT TERM
        set +e
        cleanup_snapshots || cleanup_status=$?
        if (( status == 0 && cleanup_status != 0 )); then
          status=1
        fi
        exit "$status"
      }
      trap cleanup_on_exit EXIT

      for partition in "''${partition_names[@]}"; do
        snapshot_json="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 600 \
          --get --data-urlencode "name=$partition" \
          "$endpoint/internal/partition/snapshot/create")"
        partition_snapshot_paths_raw="$(jq -er 'if type == "array" then .[] | strings | select(length > 0) else error("expected a snapshot path array") end' <<< "$snapshot_json")" || {
          echo "VictoriaLogs returned no valid snapshot paths for partition $partition." >&2
          exit 1
        }
        mapfile -t partition_snapshot_paths <<< "$partition_snapshot_paths_raw"
        for snapshot_path in "''${partition_snapshot_paths[@]}"; do
          case "$snapshot_path" in
            ${lib.escapeShellArg apiDataPath}/partitions/"$partition"/snapshots/*) ;;
            *)
              echo "VictoriaLogs returned a snapshot path outside the expected partition." >&2
              exit 1
              ;;
          esac
          if [[ ! "''${snapshot_path##*/}" =~ ^[0-9]{14}-[0-9A-Fa-f]+$ ]]; then
            echo "VictoriaLogs returned a snapshot path with an invalid name." >&2
            exit 1
          fi
          snapshot_paths+=("$snapshot_path")
        done
      done

      restic --no-cache backup --host=jorthaus-victorialogs --tag=victorialogs \
        "''${snapshot_paths[@]}"

      cleanup_snapshots || {
        echo "VictoriaLogs backup completed but snapshot cleanup failed." >&2
        exit 1
      }
      trap - EXIT INT TERM
      write_last_success "$(date -u +%s)"
      if [[ "$(date -u +%u)" == 7 ]]; then
        restic --no-cache forget "''${retention_args[@]}" --prune
      fi
    '';
  };

  serviceConfig = {
    Type = "oneshot";
    User = "victorialogs-backup";
    Group = "victorialogs-backup";
    UMask = "0077";
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    NoNewPrivileges = true;
    TimeoutStartSec = "2h";
    StateDirectory = "victorialogs-backup";
    StateDirectoryMode = "0750";
  };
in
{
  config = lib.mkIf enabled {
    users.groups.victorialogs-backup = { };
    users.users.victorialogs-backup = {
      isSystemUser = true;
      group = "victorialogs-backup";
      extraGroups = [ "victorialogs" ];
      home = "/var/empty";
      createHome = false;
    };

    age.secrets.victorialogs-backup-approle-role-id = {
      file = ../../../secrets/victorialogs-backup-approle-role-id.age;
      owner = "victorialogs-backup";
      group = "victorialogs-backup";
      mode = "0400";
    };
    age.secrets.victorialogs-backup-approle-secret-id = {
      file = ../../../secrets/victorialogs-backup-approle-secret-id.age;
      owner = "victorialogs-backup";
      group = "victorialogs-backup";
      mode = "0400";
    };

    services.vault-agent.instances.victorialogs-backup = {
      package = pkgs.openbao;
      user = "victorialogs-backup";
      group = "victorialogs-backup";
      settings = {
        pid_file = "${runtimeDirectory}/vault-agent.pid";
        vault = {
          address = "https://openbao.service.jort.haus:8200";
          tls_server_name = "openbao.service.jort.haus";
          ca_cert = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
        auto_auth = [
          {
            method = [
              {
                type = "approle";
                mount_path = "auth/approle";
                config = {
                  role_id_file_path = roleIdFile;
                  secret_id_file_path = secretIdFile;
                  remove_secret_id_file_after_reading = false;
                };
              }
            ];
            sink = [
              {
                type = "file";
                config = {
                  path = "${runtimeDirectory}/openbao.token";
                  mode = 256;
                };
              }
            ];
          }
        ];
        template_config.static_secret_render_interval = "5m";
        template = [
          {
            destination = credentialsFile;
            perms = 256;
            contents = ''
              {{- with secret "backup/data/victorialogs" }}
              {
                "b2_application_key_id": "{{ .Data.data.b2_application_key_id }}",
                "b2_application_key": "{{ .Data.data.b2_application_key }}",
                "restic_password": "{{ .Data.data.restic_password }}"
              }
              {{- end }}
            '';
          }
        ];
      };
    };

    systemd.services.vault-agent-victorialogs-backup = {
      after = [
        "network-online.target"
        "agenix.service"
      ]
      ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      wants = [
        "network-online.target"
        "agenix.service"
      ]
      ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      postStart = ''
        for _ in $(seq 1 60); do
          test -s ${lib.escapeShellArg credentialsFile} && exit 0
          sleep 1
        done
        echo "VictoriaLogs backup credentials were not rendered." >&2
        exit 1
      '';
      serviceConfig = {
        RuntimeDirectory = lib.mkForce "victorialogs-backup-agent";
        RuntimeDirectoryMode = lib.mkForce "0750";
      };
    };

    systemd.services.victorialogs-backup-init = {
      description = "Initialize the VictoriaLogs Restic repository in Backblaze B2";
      after = [
        "network-online.target"
        "vault-agent-victorialogs-backup.service"
      ];
      wants = [
        "network-online.target"
        "vault-agent-victorialogs-backup.service"
      ];
      serviceConfig = serviceConfig // {
        ExecStart = "${backupRunner}/bin/jorthaus-victorialogs-backup init";
      };
    };

    systemd.services.victorialogs-backup-verify = {
      description = "Check the VictoriaLogs Restic repository and preview retention";
      after = [
        "network-online.target"
        "vault-agent-victorialogs-backup.service"
      ];
      wants = [
        "network-online.target"
        "vault-agent-victorialogs-backup.service"
      ];
      serviceConfig = serviceConfig // {
        ExecStart = "${backupRunner}/bin/jorthaus-victorialogs-backup verify";
      };
    };

    systemd.services.victorialogs-backup = {
      description = "Back up VictoriaLogs partition snapshots to Backblaze B2";
      after = [
        "network-online.target"
        "victorialogs.service"
        "vault-agent-victorialogs-backup.service"
      ];
      wants = [
        "network-online.target"
        "victorialogs.service"
        "vault-agent-victorialogs-backup.service"
      ];
      serviceConfig = serviceConfig // {
        ExecStart = "${backupRunner}/bin/jorthaus-victorialogs-backup backup";
      };
    };

    systemd.timers.victorialogs-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 12:30:00 UTC";
        Persistent = false;
        Unit = "victorialogs-backup.service";
      };
    };

    systemd.services.victorialogs-backup-metrics = {
      description = "Export the latest VictoriaLogs backup time to node-exporter";
      requires = [ "prometheus-node-exporter.service" ];
      after = [ "prometheus-node-exporter.service" ];
      serviceConfig.ExecStart = lib.escapeShellArgs [
        "${backupMetricsCollector}/bin/jorthaus-victorialogs-backup-metrics"
        stateFile
        metricsFile
      ];
    };

    systemd.timers.victorialogs-backup-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "5m";
        Persistent = false;
        Unit = "victorialogs-backup-metrics.service";
      };
    };

    jorthaus.prometheus.systemdServices = [
      {
        unit = "vault-agent-victorialogs-backup.service";
        sliver = "victorialogs";
        severity = "warning";
      }
      {
        unit = "victorialogs-backup.service";
        sliver = "victorialogs";
        severity = "warning";
        alertWhenInactive = false;
      }
      {
        unit = "victorialogs-backup.timer";
        sliver = "victorialogs";
        severity = "warning";
      }
      {
        unit = "victorialogs-backup-metrics.service";
        sliver = "victorialogs";
        severity = "warning";
        alertWhenInactive = false;
      }
      {
        unit = "victorialogs-backup-metrics.timer";
        sliver = "victorialogs";
        severity = "warning";
      }
    ];
    jorthaus.prometheus.localSystemdServices = [
      "vault-agent-victorialogs-backup.service"
      "victorialogs-backup.service"
      "victorialogs-backup.timer"
      "victorialogs-backup-metrics.service"
      "victorialogs-backup-metrics.timer"
    ];
  };
}
