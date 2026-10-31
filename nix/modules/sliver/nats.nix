{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  enabled = host.slivers.nats.enable;
  startEnabled = host.slivers.nats.start;
  pkiEnabled = host.slivers.nats.pki.enable;
  natsPort = 4222;
  clusterPort = 6222;
  monitorPort = 8222;
  exporterPort = 7777;
  podCidr = "10.42.0.0/16";
  jetStreamMaxFile = "16G";
  jetStreamMaxMemory = "1G";
  resolverDir = "${dataDir}/resolver";
  authConfigFile = config.jorthaus.openbao.secrets.natsServerAuth.filePath;
  nodeDnsName = "${host.hostname}.node.jort.haus";
  certName = "nats-${host.hostname}";
  certDir = config.security.acme.certs.${certName}.directory;
  routeTlsDir = "/run/nats-route-tls";
  routeCertFile = "${routeTlsDir}/tls.crt";
  routeKeyFile = "${routeTlsDir}/tls.key";
  routeCaFile = "${routeTlsDir}/ca.crt";
  natsHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.nats.enable) (builtins.attrValues hostInventory)
  );
  natsPeers = lib.filter (peer: peer.hostname != host.hostname) natsHosts;
  prometheusHosts = lib.filter (peer: peer.slivers.prometheus.enable) (
    builtins.attrValues hostInventory
  );
  projectDisks = lib.filter (disk: disk.projects ? nats) host.install.dataDisks;
  projectDefined = projectDisks != [ ];
  projectDisk = if projectDefined then lib.head projectDisks else null;
  dataDir = if projectDefined then "${projectDisk.mountpoint}/nats" else "/srv/storage/nats";
  systemdServices = lib.optionals (natsHosts != [ ]) [
    {
      unit = "nats.service";
      sliver = "nats";
      severity = "critical";
    }
    {
      unit = "prometheus-nats-exporter.service";
      sliver = "nats";
      severity = "warning";
    }
  ];
  firewallRules = [
    "iptables -w -A nixos-fw -p tcp -s ${podCidr} --dport ${toString natsPort} -j nixos-fw-accept"
  ]
  ++ map (
    peer:
    "iptables -w -A nixos-fw -p tcp -s ${peer.ipam.ipv4.address} --dport ${toString natsPort} -j nixos-fw-accept"
  ) natsHosts
  ++ map (
    peer:
    "iptables -w -A nixos-fw -p tcp -s ${peer.ipam.ipv4.address} --dport ${toString clusterPort} -j nixos-fw-accept"
  ) natsPeers
  ++ map (
    peer:
    "iptables -w -A nixos-fw -p tcp -s ${peer.ipam.ipv4.address} --dport ${toString exporterPort} -j nixos-fw-accept"
  ) prometheusHosts;
  authConfigCheck = pkgs.writeShellScript "nats-auth-config-check" ''
    set -euo pipefail
    ${pkgs.jq}/bin/jq -e '
      (.operator | type == "string" and length > 0) and
      (.system_account | type == "string" and length > 0) and
      (.resolver_preload | type == "object" and length > 0)
    ' ${lib.escapeShellArg authConfigFile} >/dev/null
  '';
  routeTlsCheck = pkgs.writeShellScript "nats-route-tls-check" ''
    set -euo pipefail
    test -s ${lib.escapeShellArg routeCertFile}
    test -s ${lib.escapeShellArg routeKeyFile}
    test -s ${lib.escapeShellArg routeCaFile}
    ${lib.getExe pkgs.openssl} x509 -checkhost ${lib.escapeShellArg nodeDnsName} -noout -in ${lib.escapeShellArg routeCertFile} >/dev/null
    ${lib.getExe pkgs.openssl} verify -purpose sslserver -CAfile ${lib.escapeShellArg routeCaFile} ${lib.escapeShellArg routeCertFile} >/dev/null
    ${lib.getExe pkgs.openssl} verify -purpose sslclient -CAfile ${lib.escapeShellArg routeCaFile} ${lib.escapeShellArg routeCertFile} >/dev/null
  '';
  pkiAgentDir = "/run/nats-pki-agent";
  pkiTokenFile = "${pkiAgentDir}/openbao.token";
  pkiTlsDir = "/run/nats-route-tls";
  pkiRenewalMarker = "${pkiTlsDir}/renewal-completed";
  pkiRoleIdName = "nats-pki-${host.hostname}-role-id";
  pkiSecretIdName = "nats-pki-${host.hostname}-secret-id";
  pkiRoleIdFile = config.age.secrets.${pkiRoleIdName}.path;
  pkiSecretIdFile = config.age.secrets.${pkiSecretIdName}.path;
  pkiRenewalCalendar =
    {
      gaia-01 = "*-*-* 02:00:00";
      gaia-02 = "*-*-* 02:20:00";
      gaia-03 = "*-*-* 02:40:00";
    }
    .${host.hostname};
  pkiIssueCert = pkgs.writeShellScript "jorthaus-nats-pki-renew" ''
    set -euo pipefail
    umask 077

    openssl=${lib.getExe pkgs.openssl}
    bao=${lib.getExe pkgs.openbao}
    runtime_dir=${lib.escapeShellArg pkiTlsDir}
    token_file=${lib.escapeShellArg pkiTokenFile}
    cert_file=${lib.escapeShellArg routeCertFile}
    key_file=${lib.escapeShellArg routeKeyFile}
    ca_file=${lib.escapeShellArg routeCaFile}
    dns_name=${lib.escapeShellArg nodeDnsName}

    key_matches_cert() {
      key_fingerprint=$("$openssl" pkey -in "$key_file" -pubout -outform DER | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)
      cert_fingerprint=$("$openssl" x509 -pubkey -noout -in "$cert_file" | "$openssl" pkey -pubin -outform DER | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)
      [ "$key_fingerprint" = "$cert_fingerprint" ]
    }

    if [ -s "$cert_file" ] && [ -s "$key_file" ] && [ -s "$ca_file" ] \
      && "$openssl" x509 -checkend $((7 * 24 * 60 * 60)) -noout -in "$cert_file" \
      && "$openssl" x509 -checkhost "$dns_name" -noout -in "$cert_file" \
      && "$openssl" verify -purpose sslserver -CAfile "$ca_file" "$cert_file" >/dev/null \
      && "$openssl" verify -purpose sslclient -CAfile "$ca_file" "$cert_file" >/dev/null \
      && key_matches_cert
    then
      exit 0
    fi

    for _ in $(seq 1 60); do
      if [ -s "$token_file" ]; then break; fi
      sleep 1
    done
    [ -s "$token_file" ]

    replace_existing=0
    if [ -s "$cert_file" ]; then replace_existing=1; fi

    work_dir="$(${pkgs.coreutils}/bin/mktemp -d "$runtime_dir/.issue.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -rf -- "$work_dir"; unset BAO_TOKEN' EXIT

    "$openssl" req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$work_dir/tls.key" -out "$work_dir/tls.csr" \
      -subj "/CN=$dns_name" -addext "subjectAltName=DNS:$dns_name" >/dev/null 2>&1

    export BAO_ADDR=https://openbao.service.jort.haus:8200
    export BAO_TOKEN="$(tr -d '\n' < "$token_file")"
    "$bao" write -format=json nats-pki/sign/route-${host.hostname} \
      ttl=720h csr="@$work_dir/tls.csr" > "$work_dir/response.json"

    ${lib.getExe pkgs.python3} - "$work_dir/response.json" "$work_dir/tls.crt" "$work_dir/ca.crt" <<'PY'
    import json
    import sys

    response_path, cert_path, ca_path = sys.argv[1:]
    with open(response_path, "r", encoding="utf-8") as response_file:
        data = json.load(response_file)["data"]

    chain = data.get("ca_chain") or []
    if not chain:
        issuing_ca = data.get("issuing_ca") or ""
        chain = [issuing_ca] if issuing_ca else []
    if not data.get("certificate") or not chain:
        raise SystemExit("OpenBao PKI response is missing certificate chain data")

    with open(cert_path, "w", encoding="utf-8") as cert_file:
        cert_file.write(data["certificate"].strip() + "\n")
    with open(ca_path, "w", encoding="utf-8") as ca_file:
        ca_file.write("\n".join(certificate.strip() for certificate in chain) + "\n")
    PY

    "$openssl" x509 -checkend $((7 * 24 * 60 * 60)) -noout -in "$work_dir/tls.crt" >/dev/null
    "$openssl" x509 -checkhost "$dns_name" -noout -in "$work_dir/tls.crt" >/dev/null
    "$openssl" verify -purpose sslserver -CAfile "$work_dir/ca.crt" "$work_dir/tls.crt" >/dev/null
    "$openssl" verify -purpose sslclient -CAfile "$work_dir/ca.crt" "$work_dir/tls.crt" >/dev/null
    "$openssl" x509 -noout -ext extendedKeyUsage -in "$work_dir/tls.crt" \
      | ${pkgs.gnugrep}/bin/grep -Fq 'TLS Web Server Authentication'
    "$openssl" x509 -noout -ext extendedKeyUsage -in "$work_dir/tls.crt" \
      | ${pkgs.gnugrep}/bin/grep -Fq 'TLS Web Client Authentication'

    key_fingerprint=$("$openssl" pkey -in "$work_dir/tls.key" -pubout -outform DER | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)
    cert_fingerprint=$("$openssl" x509 -pubkey -noout -in "$work_dir/tls.crt" | "$openssl" pkey -pubin -outform DER | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)
    [ "$key_fingerprint" = "$cert_fingerprint" ]

    ${pkgs.coreutils}/bin/chown root:nats "$work_dir/tls.crt" "$work_dir/tls.key" "$work_dir/ca.crt"
    ${pkgs.coreutils}/bin/chmod 0640 "$work_dir/tls.crt" "$work_dir/tls.key" "$work_dir/ca.crt"
    ${pkgs.coreutils}/bin/mv -f "$work_dir/tls.key" "$key_file"
    ${pkgs.coreutils}/bin/mv -f "$work_dir/ca.crt" "$ca_file"
    ${pkgs.coreutils}/bin/mv -f "$work_dir/tls.crt" "$cert_file"
    if [ "$replace_existing" -eq 1 ]; then
      ${pkgs.coreutils}/bin/touch ${lib.escapeShellArg pkiRenewalMarker}
    fi
  '';
  pkiRefresh = pkgs.writeShellScript "jorthaus-nats-pki-refresh" ''
    set -euo pipefail
    if ${
      if startEnabled then "true" else "false"
    } && [ "$(${pkgs.systemd}/bin/systemctl show --property=ActiveState --value nats.service)" = active ]; then
      route_count=$(${pkgs.curl}/bin/curl --silent --show-error --fail --max-time 5 \
        http://127.0.0.1:${toString monitorPort}/routez | ${pkgs.jq}/bin/jq -er '.num_routes | numbers')
      if [ "$route_count" -lt 2 ]; then
        echo "NATS has only $route_count active routes; refusing certificate-triggered restart." >&2
        exit 1
      fi
      ${pkgs.systemd}/bin/systemctl try-restart nats.service
    fi
  '';
  staticConfigFile = pkgs.writeText "nats-static-config.json" (
    builtins.toJSON config.services.nats.settings
  );
  natsConfigLauncher = pkgs.writeShellScriptBin "nats-server-with-openbao-auth" ''
    set -euo pipefail
    umask 077
    runtime_config=/run/nats/server.conf
    temporary_config="$runtime_config.tmp"
    ${pkgs.jq}/bin/jq -s '.[0] * .[1]' ${staticConfigFile} ${lib.escapeShellArg authConfigFile} > "$temporary_config"
    ${pkgs.nats-server}/bin/nats-server --config "$temporary_config" -t >/dev/null
    ${pkgs.coreutils}/bin/mv "$temporary_config" "$runtime_config"
    exec ${pkgs.nats-server}/bin/nats-server --config "$runtime_config"
  '';
in
{
  config = lib.mkMerge [
    { jorthaus.prometheus.systemdServices = systemdServices; }
    (lib.mkIf pkiEnabled {
      age.secrets.${pkiRoleIdName} = {
        file = ../../../secrets/${pkiRoleIdName}.age;
        owner = "root";
        group = "root";
        mode = "0400";
      };
      age.secrets.${pkiSecretIdName} = {
        file = ../../../secrets/${pkiSecretIdName}.age;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      systemd.tmpfiles.rules = [ "d ${pkiTlsDir} 0750 root nats -" ];

      services.vault-agent.instances.nats-pki = {
        package = pkgs.openbao;
        user = "root";
        group = "root";
        settings = {
          pid_file = "${pkiAgentDir}/vault-agent.pid";
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
                    role_id_file_path = pkiRoleIdFile;
                    secret_id_file_path = pkiSecretIdFile;
                    remove_secret_id_file_after_reading = false;
                  };
                }
              ];
              sink = [
                {
                  type = "file";
                  config = {
                    path = pkiTokenFile;
                    mode = 256;
                  };
                }
              ];
            }
          ];
        };
      };

      systemd.services.vault-agent-nats-pki = {
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
        startLimitIntervalSec = lib.mkForce 0;
        serviceConfig = {
          RuntimeDirectory = lib.mkForce "nats-pki-agent";
          RuntimeDirectoryMode = lib.mkForce "0700";
        };
      };

      assertions = [
        {
          assertion = enabled;
          message = "NATS route PKI integration requires the NATS sliver to be enabled.";
        }
      ];

      systemd.services.jorthaus-nats-pki-renew = {
        description = "Issue or renew the NATS route TLS certificate";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "vault-agent-nats-pki.service"
        ];
        requires = [
          "network-online.target"
          "vault-agent-nats-pki.service"
        ];
        path = [ pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "nats";
          TimeoutStartSec = "10m";
          ExecStart = pkiIssueCert;
        };
      };

      systemd.timers.jorthaus-nats-pki-renew = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = pkiRenewalCalendar;
          AccuracySec = "1s";
          Persistent = true;
          Unit = "jorthaus-nats-pki-renew.service";
        };
      };

      systemd.services.jorthaus-nats-pki-refresh = {
        after = [ "jorthaus-nats-pki-renew.service" ];
        requires = [ "jorthaus-nats-pki-renew.service" ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = "10m";
          ExecStart = pkiRefresh;
        };
      };

      systemd.paths.jorthaus-nats-pki-refresh = {
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = pkiRenewalMarker;
          Unit = "jorthaus-nats-pki-refresh.service";
        };
      };
    })
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = config.networking.firewall.backend == "iptables";
          message = "NATS source-restricted firewall rules require the iptables backend.";
        }
        {
          assertion = builtins.length natsHosts == 3;
          message = "The NATS cluster requires exactly three enabled hosts.";
        }
        {
          assertion = !startEnabled || pkiEnabled;
          message = "NATS cannot be started unless its OpenBao route PKI integration is enabled.";
        }
        {
          assertion = builtins.length projectDisks == 1;
          message = "NATS requires exactly one data-disk project on ${host.hostname}.";
        }
        {
          assertion = projectDefined && projectDisk.projects.nats.enforce;
          message = "NATS requires an enforced XFS project quota on ${host.hostname}.";
        }
      ];

      security.acme.certs.${certName} = {
        domain = nodeDnsName;
        group = "nats";
        reloadServices = [ "nats.service" ];
      };

      jorthaus.xfsQuota.projects.nats = {
        id = 103;
        fileSystem = projectDisk.mountpoint;
        path = dataDir;
        quota = projectDisk.projects.nats.quota;
      };

      jorthaus.openbao.secrets.natsServerAuth = {
        path = "metal/nats/server-auth";
        owner = "nats";
        group = "nats";
        mode = "0400";
        requiredForStartup = false;
        consumers = [
          {
            unit = "nats.service";
            onChange = if startEnabled then "restart-or-start" else "none";
          }
        ];
      };

      systemd.tmpfiles.rules = [
        "d ${dataDir} 0750 nats nats -"
        "d ${resolverDir} 0750 nats nats -"
      ]
      ++ lib.optionals startEnabled [
        "d /run/nats-start-approved 0700 root root -"
      ]
      ++ lib.optionals (!startEnabled) [
        "R /run/nats-start-approved - - - -"
      ];

      networking.firewall.extraCommands = lib.concatStringsSep "\n" firewallRules;

      services.nats = {
        enable = true;
        serverName = host.hostname;
        port = natsPort;
        jetstream = true;
        dataDir = dataDir;
        validateConfig = false;
        settings = {
          host = host.ipam.ipv4.address;
          client_advertise = "${nodeDnsName}:${toString natsPort}";
          http = "127.0.0.1:${toString monitorPort}";
          resolver = {
            type = "full";
            dir = resolverDir;
            allow_delete = true;
            interval = "2m";
            timeout = "1.9s";
          };
          jetstream = {
            max_file = jetStreamMaxFile;
            max_mem = jetStreamMaxMemory;
          };
          cluster = {
            name = "jorthaus";
            listen = "${host.ipam.ipv4.address}:${toString clusterPort}";
            advertise = "${nodeDnsName}:${toString clusterPort}";
            routes = map (peer: "nats://${peer.hostname}.node.jort.haus:${toString clusterPort}") natsPeers;
            tls = {
              cert_file = routeCertFile;
              key_file = routeKeyFile;
              ca_file = routeCaFile;
              verify = true;
              timeout = 2;
            };
          };
          tls = {
            cert_file = "${certDir}/fullchain.pem";
            key_file = "${certDir}/key.pem";
            timeout = 2;
          };
        };
      };

      services.prometheus.exporters.nats = {
        enable = true;
        extraFlags = [
          "-varz"
          "-connz"
          "-routez"
          "-subz"
          "-jsz=all"
        ];
        listenAddress = host.ipam.ipv4.address;
        port = exporterPort;
        openFirewall = false;
        url = "http://127.0.0.1:${toString monitorPort}";
      };

      systemd.services.nats = {
        after = [
          "network-online.target"
          "var-lib-acme.mount"
          "xfs_quota-nats.service"
        ]
        ++ lib.optionals pkiEnabled [ "jorthaus-nats-pki-renew.service" ];
        requires = [
          "network-online.target"
          "var-lib-acme.mount"
          "xfs_quota-nats.service"
        ]
        ++ lib.optionals pkiEnabled [ "jorthaus-nats-pki-renew.service" ];
        unitConfig = {
          ConditionPathExists = authConfigFile;
          ConditionPathIsDirectory = "/run/nats-start-approved";
          RequiresMountsFor = [
            dataDir
            "/var/lib/acme"
          ];
        };
        serviceConfig = {
          ExecStart = lib.mkForce "${natsConfigLauncher}/bin/nats-server-with-openbao-auth";
          ExecStartPre = [
            authConfigCheck
            routeTlsCheck
          ];
          RuntimeDirectory = "nats";
          RuntimeDirectoryMode = "0750";
          ReadWritePaths = [ "/run/nats" ];
          MemoryHigh = "2G";
          MemoryMax = "3G";
          TasksMax = 4096;
        };
      };

      jorthaus.prometheus.localSystemdServices = [
        "nats.service"
        "prometheus-nats-exporter.service"
      ];
    })
  ];
}
