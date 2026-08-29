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
  bootstrapHost = lib.head valkeyHosts;
  sentinelQuorum = lib.min 2 (builtins.length valkeyHosts);
  valkeyPasswordFile = config.age.secrets.${valkeyPasswordSecret}.path;
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
  config = lib.mkIf enabled {
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
        valkey = {
          enable = true;
          port = 0;
          bind = host.ipam.ipv4.address;
          appendOnly = true;
          save = [ ];
          requirePassFile = valkeyPasswordFile;
          masterAuthFile = valkeyPasswordFile;
          settings = {
            protected-mode = false;
            tls-port = valkeyPort;
            tls-replication = true;
            tls-cert-file = "${certDir}/fullchain.pem";
            tls-key-file = "${certDir}/key.pem";
            tls-ca-cert-file = caFile;
            tls-auth-clients = false;
          };
          slaveOf =
            if host.hostname == bootstrapHost.hostname then
              null
            else
              {
                ip = "${bootstrapHost.hostname}.node.jort.haus";
                port = valkeyPort;
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

    systemd.services.redis-valkey = {
      after = [
        "network-online.target"
        "var-lib-acme.mount"
      ];
      wants = [
        "network-online.target"
        "var-lib-acme.mount"
      ];
      unitConfig = {
        RequiresMountsFor = [ "/var/lib/acme" ];
        ConditionPathExists = "${certDir}/fullchain.pem";
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
      after = [ "redis-valkey.service" "redis-valkey-sentinel.service" ];
      wants = [ "redis-valkey.service" "redis-valkey-sentinel.service" ];
    };
  };
}
