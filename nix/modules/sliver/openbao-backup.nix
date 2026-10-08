{
  config,
  host,
  lib,
  pkgs,
  ...
}:

let
  enabled = host.slivers.openbao.enable;
  nodeDnsName = "${host.hostname}.node.jort.haus";
  credentialFile = config.age.secrets.openbao-backup-credentials.path;
  roleIdFile = config.age.secrets.openbao-backup-approle-role-id.path;
  secretIdFile = config.age.secrets.openbao-backup-approle-secret-id.path;
  agentDirectory = "/run/openbao-backup-agent";
  agentTokenFile = "${agentDirectory}/openbao.token";
  backupRuntimeDirectory = "/run/openbao-raft-backup";
  backupStateDirectory = "/var/lib/openbao-raft-backup";
  backupMetricsOutput = "/run/prometheus-node-exporter/openbao-raft-backup.prom";
  backupMetricsCollector = pkgs.writeShellApplication {
    name = "jorthaus-openbao-backup-metrics";
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
        echo "OpenBao backup timestamp state is invalid." >&2
        exit 1
      }
      temporary_file="$(mktemp "''${output_file}.XXXXXX")"
      trap 'rm -f -- "$temporary_file"' EXIT
      {
        printf '%s\n' '# HELP openbao_raft_backup_last_success_timestamp_seconds Unix timestamp of the latest validated OpenBao Raft snapshot.'
        printf '%s\n' '# TYPE openbao_raft_backup_last_success_timestamp_seconds gauge'
        printf 'openbao_raft_backup_last_success_timestamp_seconds %s\n' "$timestamp"
      } > "$temporary_file"
      chmod 0644 "$temporary_file"
      mv -f -- "$temporary_file" "$output_file"
    '';
  };
  backupRunner = pkgs.writeShellApplication {
    name = "jorthaus-openbao-raft-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.openbao
      pkgs.restic
    ];
    text = ''
      set -euo pipefail
      umask 077

      operation="''${1:-backup}"
      if [[ "$operation" != backup && "$operation" != init && "$operation" != verify ]]; then
        echo "usage: jorthaus-openbao-raft-backup [backup|init|verify]" >&2
        exit 2
      fi

      credentials_file=${lib.escapeShellArg credentialFile}
      [[ -r "$credentials_file" ]] || {
        echo "OpenBao backup credentials are unavailable." >&2
        exit 1
      }

      AWS_ACCESS_KEY_ID="$(jq -er '.b2_application_key_id | select(type == "string" and length > 0)' "$credentials_file")"
      AWS_SECRET_ACCESS_KEY="$(jq -er '.b2_application_key | select(type == "string" and length > 0)' "$credentials_file")"
      RESTIC_PASSWORD="$(jq -er '.restic_password | select(type == "string" and test("^[0-9a-f]{64}$"))' "$credentials_file")"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
      export AWS_DEFAULT_REGION=us-east-005
      export AWS_REGION=us-east-005
      export RESTIC_REPOSITORY=s3:https://s3.us-east-005.backblazeb2.com/jorthaus-openbao-backups/restic/openbao
      export TZ=UTC
      state_directory=${lib.escapeShellArg backupStateDirectory}
      state_file="$state_directory/last-success-epoch"
      write_last_success() {
        local timestamp="$1"
        local temporary_file
        [[ "$timestamp" =~ ^[0-9]+$ ]] || {
          echo "OpenBao backup timestamp is invalid." >&2
          exit 1
        }
        temporary_file="$(mktemp "$state_directory/last-success.XXXXXX")"
        printf '%s\n' "$timestamp" > "$temporary_file"
        mv -f -- "$temporary_file" "$state_file"
      }
      retention_args=(
        --group-by
        "host,paths,tags"
        --tag
        openbao-raft
        --keep-last 1
        --keep-within-daily 7d
        --keep-within-weekly 14d
        --keep-within-monthly 3m
        --keep-within-yearly 1y
      )

      if [[ "$operation" == init ]]; then
        restic --no-cache init
        exit 0
      fi
      if [[ "$operation" == verify ]]; then
        restic --no-cache check --read-data
        restic --no-cache forget --dry-run "''${retention_args[@]}"
        latest_snapshot_time="$(restic --no-cache snapshots --json --tag openbao-raft | jq -er 'map(.time) | max')"
        write_last_success "$(date -u --date="$latest_snapshot_time" +%s)"
        exit 0
      fi

      runtime_directory=${lib.escapeShellArg backupRuntimeDirectory}
      snapshot_file="$runtime_directory/openbao-raft.snap"
      leader_file="$runtime_directory/leader.json"
      token_file=${lib.escapeShellArg agentTokenFile}
      ca_file=${lib.escapeShellArg "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"}
      bao_address=${lib.escapeShellArg "https://${nodeDnsName}:8200"}

      cleanup() {
        rm -f -- "$snapshot_file" "$leader_file"
        unset BAO_TOKEN AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
      }
      trap cleanup EXIT

      local_hour="$(TZ=America/Chicago date +%H)"
      if (( 10#$local_hour >= 1 && 10#$local_hour < 5 )); then
        echo "OpenBao backup is blocked during the Kured reboot window." >&2
        exit 1
      fi

      if ! curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
        --cacert "$ca_file" "$bao_address/v1/sys/leader" > "$leader_file"; then
        echo "Unable to determine local OpenBao Raft leadership." >&2
        exit 1
      fi

      if ! jq -e '.ha_enabled == true' "$leader_file" > /dev/null; then
        echo "OpenBao did not report an enabled HA cluster." >&2
        exit 1
      fi
      if jq -e '.is_self == true' "$leader_file" > /dev/null; then
        :
      elif jq -e '(.is_self == false or .is_self == null) and (.leader_address | type == "string" and length > 0)' "$leader_file" > /dev/null; then
        echo "Skipping OpenBao backup on a non-leader node."
        exit 0
      else
        echo "OpenBao returned an invalid local leadership state." >&2
        exit 1
      fi

      for _ in $(seq 1 30); do
        [[ -s "$token_file" ]] && break
        sleep 1
      done
      [[ -s "$token_file" ]] || {
        echo "OpenBao backup AppRole agent did not provide a token." >&2
        exit 1
      }
      export BAO_ADDR="$bao_address"
      export BAO_CACERT="$ca_file"
      BAO_TOKEN="$(tr -d '\r\n' < "$token_file")"
      export BAO_TOKEN

      if ! restic --no-cache cat config > /dev/null 2>&1; then
        echo "Restic repository is not initialized or cannot be read; refusing to create it automatically." >&2
        exit 1
      fi

      rm -f -- "$snapshot_file"
      bao operator raft snapshot save "$snapshot_file"
      [[ -s "$snapshot_file" ]] || {
        echo "OpenBao produced an empty Raft snapshot." >&2
        exit 1
      }

      restic --no-cache backup --host=jorthaus-openbao --tag=openbao-raft "$snapshot_file"
      write_last_success "$(date -u +%s)"

      if [[ "$(date -u +%u)" == 7 ]]; then
        restic --no-cache forget "''${retention_args[@]}" --prune
      fi
    '';
  };
  appRoleAgentConfig = {
    package = pkgs.openbao;
    user = "openbao-backup";
    group = "openbao-backup";
    settings = {
      pid_file = "${agentDirectory}/vault-agent.pid";
      vault = {
        address = "https://${nodeDnsName}:8200";
        tls_server_name = nodeDnsName;
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
                path = agentTokenFile;
                mode = 256;
              };
            }
          ];
        }
      ];
    };
  };
  backupServiceConfig = {
    Type = "oneshot";
    User = "openbao-backup";
    Group = "openbao-backup";
    UMask = "0077";
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    NoNewPrivileges = true;
    TimeoutStartSec = "2h";
    StateDirectory = "openbao-raft-backup";
    StateDirectoryMode = "0750";
  };
in
{
  config = lib.mkIf enabled {
    users.groups.openbao-backup = { };
    users.users.openbao-backup = {
      isSystemUser = true;
      group = "openbao-backup";
      home = "/var/empty";
      createHome = false;
    };

    age.secrets.openbao-backup-credentials = {
      file = ../../../secrets/openbao-backup-credentials.age;
      owner = "openbao-backup";
      group = "openbao-backup";
      mode = "0400";
    };
    age.secrets.openbao-backup-approle-role-id = {
      file = ../../../secrets/openbao-backup-approle-role-id.age;
      owner = "openbao-backup";
      group = "openbao-backup";
      mode = "0400";
    };
    age.secrets.openbao-backup-approle-secret-id = {
      file = ../../../secrets/openbao-backup-approle-secret-id.age;
      owner = "openbao-backup";
      group = "openbao-backup";
      mode = "0400";
    };

    services.vault-agent.instances.openbao-backup = appRoleAgentConfig;

    systemd.services.vault-agent-openbao-backup = {
      after = [
        "network-online.target"
        "agenix.service"
        "openbao.service"
      ];
      wants = [
        "network-online.target"
        "agenix.service"
        "openbao.service"
      ];
      serviceConfig = {
        RuntimeDirectory = lib.mkForce "openbao-backup-agent";
        RuntimeDirectoryMode = lib.mkForce "0750";
      };
    };

    systemd.services.openbao-raft-backup-init = {
      description = "Initialize the OpenBao Restic repository in Backblaze B2";
      after = [
        "network-online.target"
        "agenix.service"
      ];
      wants = [
        "network-online.target"
        "agenix.service"
      ];
      serviceConfig = backupServiceConfig // {
        ExecStart = "${backupRunner}/bin/jorthaus-openbao-raft-backup init";
      };
    };

    systemd.services.openbao-raft-backup-verify = {
      description = "Check the OpenBao Restic repository and preview retention";
      after = [
        "network-online.target"
        "agenix.service"
      ];
      wants = [
        "network-online.target"
        "agenix.service"
      ];
      serviceConfig = backupServiceConfig // {
        ExecStart = "${backupRunner}/bin/jorthaus-openbao-raft-backup verify";
      };
    };

    systemd.services.openbao-raft-backup = {
      description = "Back up the OpenBao Raft snapshot to Backblaze B2";
      after = [
        "network-online.target"
        "agenix.service"
        "openbao.service"
        "vault-agent-openbao-backup.service"
      ];
      wants = [
        "network-online.target"
        "agenix.service"
        "openbao.service"
        "vault-agent-openbao-backup.service"
      ];
      serviceConfig = backupServiceConfig // {
        RuntimeDirectory = "openbao-raft-backup";
        RuntimeDirectoryMode = "0700";
        ExecStart = "${backupRunner}/bin/jorthaus-openbao-raft-backup backup";
      };
    };

    systemd.services.openbao-raft-backup-metrics = {
      description = "Export the latest OpenBao backup time to node-exporter";
      requires = [ "prometheus-node-exporter.service" ];
      after = [ "prometheus-node-exporter.service" ];
      serviceConfig.ExecStart = lib.escapeShellArgs [
        "${backupMetricsCollector}/bin/jorthaus-openbao-backup-metrics"
        "${backupStateDirectory}/last-success-epoch"
        backupMetricsOutput
      ];
    };

    systemd.timers.openbao-raft-backup-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "5m";
        Persistent = false;
        Unit = "openbao-raft-backup-metrics.service";
      };
    };

    systemd.timers.openbao-raft-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 11:30:00 UTC";
        Persistent = false;
        Unit = "openbao-raft-backup.service";
      };
    };

    jorthaus.prometheus.systemdServices = [
      {
        unit = "openbao-raft-backup.service";
        sliver = "openbao";
        severity = "warning";
        alertWhenInactive = false;
      }
      {
        unit = "openbao-raft-backup.timer";
        sliver = "openbao";
        severity = "warning";
      }
      {
        unit = "openbao-raft-backup-metrics.service";
        sliver = "openbao";
        severity = "warning";
        alertWhenInactive = false;
      }
      {
        unit = "openbao-raft-backup-metrics.timer";
        sliver = "openbao";
        severity = "warning";
      }
    ];
    jorthaus.prometheus.localSystemdServices = [
      "openbao-raft-backup.service"
      "openbao-raft-backup.timer"
      "openbao-raft-backup-metrics.service"
      "openbao-raft-backup-metrics.timer"
    ];
  };
}
