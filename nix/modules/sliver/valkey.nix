{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  enabled = host.slivers.valkey.enable;
  valkeyPort = 6379;
  sentinelPort = 26379;
  serviceAddress = "10.1.11.12";
  sentinelMasterName = "valkey";
  valkeyPasswordSecret = "valkey-password";
  certName = "valkey-${host.hostname}";
  nodeDnsName = "${host.hostname}.node.jort.haus";
  serviceDnsName = "valkey.service.jort.haus";
  certDir = config.security.acme.certs.${certName}.directory;
  caFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  valkeyHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.valkey.enable) (builtins.attrValues hostInventory)
  );
  systemdServices = lib.optionals (valkeyHosts != [ ]) [
    {
      unit = "redis-valkey.service";
      sliver = "valkey";
      severity = "critical";
    }
    {
      unit = "redis-valkey-sentinel.service";
      sliver = "valkey";
      severity = "critical";
    }
    {
      unit = "redis-valkey-acl-sync.service";
      sliver = "valkey";
      severity = "critical";
    }
  ];
  bootstrapHost = lib.head valkeyHosts;
  sentinelQuorum = lib.min 2 (builtins.length valkeyHosts);
  valkeyPasswordFile = config.age.secrets.${valkeyPasswordSecret}.path;
  valkeyAclFile = "/var/lib/redis-valkey/users.acl";
  valkeyAclSyncState = "/var/lib/redis-valkey/acl-sync.sha256";
  # ACL files replace the runtime user table, so bootstrap defines the default
  # user explicitly from the protected password file.
  valkeyAclBootstrap = pkgs.writeShellScript "redis-valkey-acl-bootstrap" ''
    set -euo pipefail

    acl_file=${lib.escapeShellArg valkeyAclFile}
    ${pkgs.coreutils}/bin/install \
      -d -o redis-valkey -g redis-valkey -m 0700 /var/lib/redis-valkey

    # CONFIG REWRITE may leave ACL and replication directives in the persistent config.
    # Preserve the original privately, then seed replication from Sentinel's current master.
    redis_config=/var/lib/redis-valkey/redis.conf
    redis_config_backup=/var/lib/redis-valkey/redis.conf.pre-acl
    sentinel_config=/var/lib/redis-valkey-sentinel/redis.conf
    master_host=${lib.escapeShellArg "${bootstrapHost.hostname}.node.jort.haus"}
    master_port=${toString valkeyPort}
    if [ -f "$sentinel_config" ]; then
      monitor_count=$(${pkgs.gnugrep}/bin/grep -cE '^sentinel monitor valkey ' "$sentinel_config" || true)
      if [ "$monitor_count" -ne 1 ]; then
        echo "Sentinel configuration must contain one valkey monitor entry" >&2
        exit 1
      fi
      monitor_target="$(${pkgs.gnused}/bin/sed -nE 's/^sentinel monitor valkey ([^[:space:]]+) ([0-9]+) [0-9]+$/\1 \2/p' "$sentinel_config")"
      read -r master_host master_port <<< "$monitor_target"
    fi

    if [ -s "$redis_config" ] && [ ! -e "$redis_config_backup" ]; then
      backup_temporary=$(${pkgs.coreutils}/bin/mktemp "''${redis_config_backup}.XXXXXX")
      ${pkgs.coreutils}/bin/cp --preserve=mode,ownership,timestamps "$redis_config" "$backup_temporary"
      ${pkgs.coreutils}/bin/chown root:root "$backup_temporary"
      ${pkgs.coreutils}/bin/chmod 0600 "$backup_temporary"
      ${pkgs.coreutils}/bin/mv "$backup_temporary" "$redis_config_backup"
    fi
    if [ ! -s "$redis_config" ]; then
      printf 'include "/run/redis-valkey/nixos.conf"\n' > "$redis_config"
      ${pkgs.coreutils}/bin/chown redis-valkey:redis-valkey "$redis_config"
      ${pkgs.coreutils}/bin/chmod 0600 "$redis_config"
    fi
    temporary_config=$(${pkgs.coreutils}/bin/mktemp "''${redis_config}.XXXXXX")
    ${pkgs.gnused}/bin/sed -E '/^[[:space:]]*(requirepass|user|replicaof|slaveof)[[:space:]]+/d' "$redis_config" > "$temporary_config"
    ${pkgs.coreutils}/bin/chown redis-valkey:redis-valkey "$temporary_config"
    ${pkgs.coreutils}/bin/chmod 0600 "$temporary_config"
    ${pkgs.coreutils}/bin/mv "$temporary_config" "$redis_config"
    if [ "$master_host" != ${lib.escapeShellArg nodeDnsName} ] && [ "$master_host" != ${lib.escapeShellArg host.ipam.ipv4.address} ]; then
      printf 'replicaof %s %s\n' "$master_host" "$master_port" >> "$redis_config"
    fi

    password_hash="$(
      ${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg valkeyPasswordFile} |
        ${pkgs.coreutils}/bin/sha256sum |
        ${pkgs.coreutils}/bin/cut -d ' ' -f 1
    )"
    temporary_file=$(${pkgs.coreutils}/bin/mktemp "''${acl_file}.XXXXXX")
    if [ -s "$acl_file" ]; then
      ${pkgs.gnugrep}/bin/grep -v '^user default ' "$acl_file" > "$temporary_file" || true
    fi
    printf 'user default on #%s ~* &* +@all\n' "$password_hash" >> "$temporary_file"
    ${pkgs.coreutils}/bin/chown redis-valkey:redis-valkey "$temporary_file"
    ${pkgs.coreutils}/bin/chmod 0600 "$temporary_file"
    ${pkgs.coreutils}/bin/mv "$temporary_file" "$acl_file"
  '';
  valkeyPrimaryCheck = pkgs.writeShellScriptBin "jorthaus-valkey-primary-check" ''
    set -eu

    password="$(${pkgs.coreutils}/bin/tr -d '\n' < ${valkeyPasswordFile})"
    role="$(${pkgs.valkey}/bin/valkey-cli \
      --tls \
      --sni "$HAPROXY_SERVER_ADDR" \
      --cacert ${caFile} \
      --no-auth-warning \
      -h "$HAPROXY_SERVER_ADDR" \
      -p "$HAPROXY_SERVER_PORT" \
      -a "$password" \
      ROLE | ${pkgs.coreutils}/bin/head -n1)"

    [ "$role" = "master" ]
  '';
  roleCheck = ''
    option external-check
    external-check command ${lib.getExe valkeyPrimaryCheck}
    default-server inter 2s fall 2 rise 1 on-marked-down shutdown-sessions
  '';
in
{
  config = lib.mkMerge [
    { jorthaus.prometheus.systemdServices = systemdServices; }
    (lib.mkIf enabled {
      jorthaus.prometheus.localSystemdServices = [
        "redis-valkey.service"
        "redis-valkey-sentinel.service"
        "redis-valkey-acl-sync.service"
      ];
      assertions = [
        {
          assertion = valkeyHosts != [ ];
          message = "The valkey sliver requires at least one enabled valkey node.";
        }
      ];

      security.acme.certs.${certName} = {
        domain = nodeDnsName;
        extraDomainNames = [ serviceDnsName ];
        group = "redis-valkey";
        reloadServices = [
          "redis-valkey.service"
          "redis-valkey-sentinel.service"
        ];
      };

      # TODO: Move the Valkey bootstrap password into OpenBao-backed delivery
      # once the OpenBao-first startup path is reduced to a minimal bootstrap
      # secret set.
      age.secrets.${valkeyPasswordSecret} = {
        file = ../../../secrets/valkey-password.age;
        owner = "redis-valkey";
        group = "redis-valkey";
        mode = "0440";
      };

      users.users.haproxy.extraGroups = [ "redis-valkey" ];
      users.users.redis-valkey-sentinel.extraGroups = [ "redis-valkey" ];

      jorthaus.persistence.directories = [
        {
          directory = "/var/lib/redis-valkey";
          user = "redis-valkey";
          group = "redis-valkey";
          mode = "0700";
        }
        {
          directory = "/var/lib/redis-valkey-sentinel";
          user = "redis-valkey-sentinel";
          group = "redis-valkey-sentinel";
          mode = "0700";
        }
      ];

      # TODO: Tighten Valkey and Sentinel firewall exposure once the expected
      # client and operator networks are fixed.
      networking.firewall.allowedTCPPorts = [
        valkeyPort
        sentinelPort
      ];

      jorthaus.haproxy.globalConfig = ''
        external-check
        insecure-fork-wanted
      '';

      services.redis = {
        package = pkgs.valkey;
        servers = {
          # TODO: Tighten the Valkey client trust model once the client set is
          # stable. The current deployment relies on passwords plus TLS without
          # client certificate enforcement.
          valkey = {
            enable = true;
            port = 0;
            bind = host.ipam.ipv4.address;
            appendOnly = true;
            save = [ ];
            masterAuthFile = valkeyPasswordFile;
            settings = {
              protected-mode = false;
              aclfile = valkeyAclFile;
              tls-port = valkeyPort;
              tls-replication = true;
              tls-cert-file = "${certDir}/fullchain.pem";
              tls-key-file = "${certDir}/key.pem";
              tls-ca-cert-file = caFile;
              tls-auth-clients = false;
            };
          };

          valkey-sentinel = {
            enable = true;
            port = 0;
            bind = host.ipam.ipv4.address;
            extraParams = [ "--sentinel" ];
            requirePassFile = valkeyPasswordFile;
            sentinelAuthPassFile = valkeyPasswordFile;
            settings = {
              protected-mode = false;
              tls-port = sentinelPort;
              tls-replication = true;
              tls-cert-file = "${certDir}/fullchain.pem";
              tls-key-file = "${certDir}/key.pem";
              tls-ca-cert-file = caFile;
              tls-auth-clients = false;
            };
            sentinelMasterName = sentinelMasterName;
            sentinelMasterHost = "${bootstrapHost.hostname}.node.jort.haus";
            sentinelMasterPort = valkeyPort;
            sentinelMasterQuorum = sentinelQuorum;
          };
        };
      };

      systemd.services.redis-valkey-acl-bootstrap = {
        description = "Initialize the persistent Valkey ACL file";
        before = [ "redis-valkey.service" ];
        requiredBy = [ "redis-valkey.service" ];
        unitConfig.RequiresMountsFor = [ "/var/lib/redis-valkey" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = valkeyAclBootstrap;
        };
      };

      systemd.services.redis-valkey = {
        after = [
          "network-online.target"
          "var-lib-acme.mount"
          "redis-valkey-acl-bootstrap.service"
        ];
        wants = [
          "network-online.target"
          "var-lib-acme.mount"
        ];
        requires = [ "redis-valkey-acl-bootstrap.service" ];
        unitConfig = {
          RequiresMountsFor = [ "/var/lib/acme" ];
          ConditionPathExists = "${certDir}/fullchain.pem";
        };
        serviceConfig = {
          # ACL SAVE creates files with mode 0644; keep ACL hashes private.
          UMask = "0077";
        };
      };

      systemd.services.redis-valkey-acl-sync = {
        description = "Reconcile Valkey ACLs from the Sentinel primary";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" "redis-valkey.service" ];
        requires = [ "redis-valkey.service" ];
        environment = {
          VALKEY_CLI = "${pkgs.valkey}/bin/valkey-cli";
          VALKEY_PRIMARY_HOST = serviceDnsName;
          VALKEY_LOCAL_HOST = nodeDnsName;
          VALKEY_PORT = toString valkeyPort;
          VALKEY_PASSWORD_FILE = valkeyPasswordFile;
          VALKEY_CA_FILE = caFile;
          VALKEY_ACL_SYNC_STATE = valkeyAclSyncState;
          POLL_SECONDS = "15";
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./valkey-acl-sync.py}";
          User = "redis-valkey";
          Group = "redis-valkey";
          StateDirectory = "redis-valkey";
          StateDirectoryMode = "0700";
          UMask = "0077";
          Restart = "always";
          RestartSec = "15s";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        };
      };
      systemd.services.redis-valkey-sentinel = {
        after = [
          "network-online.target"
          "var-lib-acme.mount"
          "redis-valkey.service"
        ];
        wants = [
          "network-online.target"
          "var-lib-acme.mount"
          "redis-valkey.service"
        ];
        unitConfig = {
          RequiresMountsFor = [ "/var/lib/acme" ];
          ConditionPathExists = "${certDir}/fullchain.pem";
        };
        preStart = lib.mkAfter ''
          sentinel_conf=/var/lib/redis-valkey-sentinel/redis.conf
          sentinel_run_conf=/run/redis-valkey-sentinel/nixos.conf

          if [ ! -f "$sentinel_conf" ]; then
            printf 'include "%s"\n' "$sentinel_run_conf" > "$sentinel_conf"
          fi

          tmp_conf=$(mktemp)
          printf 'include "%s"\n' "$sentinel_run_conf" > "$tmp_conf"
          ${pkgs.gnugrep}/bin/grep -vE '^(include "/run/redis-valkey-sentinel/nixos\.conf"|port |tls-port )' "$sentinel_conf" >> "$tmp_conf" || true
          cat "$tmp_conf" > "$sentinel_conf"
          rm -f "$tmp_conf"

          grep -qE '^sentinel resolve-hostnames\b' "$sentinel_conf" || \
            echo 'sentinel resolve-hostnames yes' >> "$sentinel_conf"
          grep -qE '^sentinel announce-hostnames\b' "$sentinel_conf" || \
            echo 'sentinel announce-hostnames yes' >> "$sentinel_conf"

          sentinel_password="$(${pkgs.coreutils}/bin/tr -d '\n' < ${valkeyPasswordFile})"
          grep -qE '^sentinel sentinel-pass\b' "$sentinel_conf" || \
            echo "sentinel sentinel-pass $sentinel_password" >> "$sentinel_conf"
        '';
      };

      # TODO: Gate anycast advertisement for the Valkey VIP on local health so
      # traffic only lands on nodes whose local proxy view is healthy.
      jorthaus.haproxy.services.valkey-rw = {
        enable = true;
        address = serviceAddress;
        port = valkeyPort;
        mode = "tcp";
        backendConfig = roleCheck;
        backends = map (peer: {
          name = peer.hostname;
          address = "${peer.hostname}.node.jort.haus";
          port = valkeyPort;
          options = "check inter 2s fall 2 rise 1";
        }) valkeyHosts;
        after = [
          "redis-valkey.service"
          "redis-valkey-sentinel.service"
        ];
        wants = [
          "redis-valkey.service"
          "redis-valkey-sentinel.service"
        ];
      };
    })
  ];
}
