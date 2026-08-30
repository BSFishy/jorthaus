{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.k3s;
  enabled = host.slivers.k3s.enable;
  bootstrapOnly = host.slivers.k3s.bootstrapOnly;
  active = enabled || bootstrapOnly;
  role = host.slivers.k3s.role;
  k3sHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.k3s.enable || peer.slivers.k3s.bootstrapOnly) (builtins.attrValues hostInventory)
  );
  controlplaneHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: (peer.slivers.k3s.enable || peer.slivers.k3s.bootstrapOnly) && peer.slivers.k3s.role == "controlplane") (
      builtins.attrValues hostInventory
    )
  );
  postgresHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.postgres.enable) (builtins.attrValues hostInventory)
  );
  bootstrapHost = if controlplaneHosts == [ ] then null else lib.head controlplaneHosts;
  postgresBootstrapHost = if postgresHosts == [ ] then null else lib.head postgresHosts;
  controlplaneEnabled = enabled && role == "controlplane";
  dataplaneEnabled = enabled && role == "dataplane";
  stableApiHost = "k8s.service.jort.haus";
  stableApiAddress = "10.1.11.16";
  bootstrapApiDnsName = if bootstrapHost == null then null else "${bootstrapHost.hostname}.node.jort.haus";
  apiPort = 6443;
  flannelPort = 8472;
  roleIdSecretName = "k3s-approle-role-id";
  secretIdSecretName = "k3s-approle-secret-id";
  roleIdFile = config.age.secrets.${roleIdSecretName}.path;
  secretIdFile = config.age.secrets.${secretIdSecretName}.path;
  tokenFile = "/run/k3s/token";
  datastoreEnvFile = "/run/k3s/datastore.env";
  agentDir = "/run/k3s-agent";
  disableDefaults = [
    "traefik"
    "servicelb"
    "local-storage"
    "metrics-server"
  ];
  serverAddr =
    if bootstrapHost == null || host.hostname == bootstrapHost.hostname then
      ""
    else
      "https://${stableApiHost}:${toString apiPort}";
  tlsSanHosts = lib.unique (
    lib.filter (name: name != null) [
      host.hostname
      "${host.hostname}.node.jort.haus"
      (if bootstrapHost == null then null else bootstrapHost.hostname)
      bootstrapApiDnsName
      stableApiHost
      "localhost"
    ]
  );
  postgresBootstrap = pkgs.writeShellScriptBin "jorthaus-k3s-postgres-bootstrap" ''
    set -euo pipefail

    export PGPASSWORD="$(tr -d '\n' < ${config.age.secrets.patroni-postgres-superuser-password.path})"
    psql_base=(
      ${lib.getExe' pkgs.postgresql "psql"}
      "postgresql://postgres.service.jort.haus:5432/postgres?user=postgres&sslmode=verify-full&sslrootcert=system"
    )

    "''${psql_base[@]}" <<'SQL'
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'k3s') THEN
        CREATE ROLE k3s LOGIN;
      END IF;
    END
    $$;
    SQL

    if ! "''${psql_base[@]}" -tAc "SELECT 1 FROM pg_database WHERE datname = 'k3s'" | grep -q 1; then
      "''${psql_base[@]}" -c 'CREATE DATABASE k3s OWNER k3s'
    fi

    "''${psql_base[@]}" <<'SQL'
    ALTER DATABASE k3s OWNER TO k3s;
    SQL

    ${lib.getExe' pkgs.postgresql "psql"} "postgresql://postgres.service.jort.haus:5432/k3s?user=postgres&sslmode=verify-full&sslrootcert=system" <<'SQL'
    ALTER SCHEMA public OWNER TO k3s;
    GRANT ALL ON SCHEMA public TO k3s;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO k3s;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO k3s;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO k3s;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO k3s;
    SQL
  '';
in
{
  options.jorthaus.k3s = {
    enable = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = enabled;
      description = "Whether the k3s sliver is enabled on this node.";
    };

    bootstrapOnly = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = bootstrapOnly;
      description = "Whether this node only prepares k3s bootstrap secrets without starting k3s.";
    };

    role = lib.mkOption {
      type = lib.types.enum [
        "controlplane"
        "dataplane"
      ];
      readOnly = true;
      default = role;
      description = "The k3s role for this node.";
    };

    controlplaneEnabled = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = controlplaneEnabled;
      description = "Whether this node runs the k3s server role.";
    };

    dataplaneEnabled = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = dataplaneEnabled;
      description = "Whether this node runs the k3s agent role.";
    };

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = k3sHosts;
      description = "All k3s hosts participating in bootstrap or runtime configuration.";
    };

    controlplaneHosts = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = controlplaneHosts;
      description = "All k3s controlplane hosts participating in bootstrap or runtime configuration.";
    };

    postgresHosts = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = postgresHosts;
      description = "All enabled Postgres hosts relevant to the k3s datastore.";
    };

    bootstrapHost = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      readOnly = true;
      default = bootstrapHost;
      description = "The k3s controlplane host that bootstraps the cluster.";
    };

    postgresBootstrapHost = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      readOnly = true;
      default = postgresBootstrapHost;
      description = "The host that performs one-time k3s PostgreSQL bootstrap work.";
    };

    api = {
      port = lib.mkOption {
        type = lib.types.port;
        default = apiPort;
        description = "k3s Kubernetes API port.";
      };

      stableHost = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = stableApiHost;
        description = "Stable DNS name for the k3s API endpoint.";
      };

      stableAddress = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = stableApiAddress;
        description = "Stable IPv4 address for the k3s API endpoint.";
      };

      tlsSans = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = tlsSanHosts;
        description = "TLS SAN hostnames rendered into the k3s server certificate.";
      };
    };

    token = {
      file = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = tokenFile;
        description = "Rendered k3s join token path.";
      };
    };

    datastore = {
      envFile = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = datastoreEnvFile;
        description = "Rendered k3s datastore environment file path.";
      };
    };

    packageDefaults = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = disableDefaults;
      description = "Packaged k3s components disabled by default in this cluster.";
    };
  };

  config = lib.mkIf active {
    assertions = [
      {
        assertion = controlplaneHosts != [ ];
        message = "The k3s sliver requires at least one enabled controlplane or bootstrap-only controlplane node.";
      }
      {
        assertion = postgresHosts != [ ];
        message = "The k3s sliver requires at least one enabled Postgres node for the external datastore path.";
      }
    ];

    users.users.k3s = {
      isSystemUser = true;
      group = "k3s";
    };

    users.groups.k3s = { };

    age.secrets.${roleIdSecretName} = {
      file = ../../../secrets/k3s-approle-role-id.age;
      owner = "root";
      group = "k3s";
      mode = "0440";
    };

    age.secrets.${secretIdSecretName} = {
      file = ../../../secrets/k3s-approle-secret-id.age;
      owner = "root";
      group = "k3s";
      mode = "0440";
    };

    systemd.tmpfiles.rules = [
      "d ${agentDir} 0750 k3s k3s -"
      "d /run/k3s 0750 k3s k3s -"
    ];

    services.vault-agent.instances.k3s = {
      package = pkgs.openbao;
      user = "k3s";
      group = "k3s";
      settings = {
        pid_file = "${agentDir}/vault-agent.pid";

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
                  path = "${agentDir}/openbao.token";
                  mode = 256;
                };
              }
            ];
          }
        ];

        template_config.static_secret_render_interval = "5m";

        template = [
          {
            destination = tokenFile;
            perms = 288;
            contents = ''
              {{- with secret "k3s/data/bootstrap" }}
              {{ .Data.data.token }}
              {{- end }}
            '';
          }
          {
            destination = datastoreEnvFile;
            perms = 288;
            contents = ''
              {{- with secret "postgres/static-creds/k3s" }}
              K3S_DATASTORE_ENDPOINT=postgres://{{ .Data.username }}:{{ .Data.password }}@postgres.service.jort.haus:5432/k3s?sslmode=verify-full
              {{- end }}
            '';
          }
        ];
      };
    };

    systemd.services.vault-agent-k3s = {
      after = [
        "network-online.target"
        "agenix.service"
      ] ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      wants = [
        "network-online.target"
        "agenix.service"
      ] ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      serviceConfig = {
        RuntimeDirectory = lib.mkForce "k3s-agent";
        RuntimeDirectoryMode = lib.mkForce "0750";
      };
    };

    environment.systemPackages = [ postgresBootstrap ];

    systemd.services.jorthaus-k3s-postgres-bootstrap = lib.mkIf (cfg.postgresBootstrapHost != null && host.hostname == cfg.postgresBootstrapHost.hostname) {
      description = "Ensure the k3s PostgreSQL role and database exist";
      after = [
        "network-online.target"
        "patroni.service"
        "haproxy.service"
      ];
      wants = [
        "network-online.target"
        "patroni.service"
        "haproxy.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = lib.getExe postgresBootstrap;
      };
    };

    jorthaus.routing.loopbackAddresses = lib.mkIf controlplaneEnabled [ "${cfg.api.stableAddress}/32" ];

    jorthaus.persistence.directories = lib.mkIf enabled [
      {
        directory = "/var/lib/rancher/k3s";
        user = "k3s";
        group = "k3s";
        mode = "0700";
      }
      {
        directory = "/etc/rancher/k3s";
        user = "k3s";
        group = "k3s";
        mode = "0700";
      }
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf enabled [ cfg.api.port ];
    networking.firewall.allowedUDPPorts = lib.mkIf enabled [ flannelPort ];
    networking.firewall.checkReversePath = lib.mkIf enabled false;

    # This cluster starts without the built-in flannel dataplane so a
    # dedicated CNI such as Cilium can own pod networking from the outset.
    services.k3s = lib.mkIf enabled {
      enable = true;
      role = if controlplaneEnabled then "server" else "agent";
      inherit serverAddr;
      tokenFile = cfg.token.file;
      environmentFile = cfg.datastore.envFile;
      nodeName = host.hostname;
      nodeIP = host.ipam.ipv4.address;
      disable = disableDefaults;
      gracefulNodeShutdown.enable = true;
      extraFlags = [
        "--write-kubeconfig-mode=0640"
        "--disable-network-policy"
        "--flannel-backend=none"
      ] ++ map (name: "--tls-san=${name}") cfg.api.tlsSans;
    };

    # TODO: Move k3s datastore bootstrap into the long-term activation-time
    # setup path once cluster-scoped initialization is no longer modeled as a
    # manual helper or boot-time oneshot.
    # TODO: Gate advertisement of ${stableApiAddress}/32 on local k3s API
    # health so non-ready controlplanes withdraw the stable API endpoint.
  };
}
