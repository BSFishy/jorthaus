{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.seaweedfs;
  roleIdSecretName = "seaweedfs-approle-role-id";
  secretIdSecretName = "seaweedfs-approle-secret-id";
  roleIdFile = config.age.secrets.${roleIdSecretName}.path;
  secretIdFile = config.age.secrets.${secretIdSecretName}.path;
  filerRuntimeDir = "/run/seaweedfs-filer";
  credsFile = "${filerRuntimeDir}/postgres.env";
  restartHelper = pkgs.writeShellScript "jorthaus-seaweedfs-credential-refresh" ''
    set -eu

    for unit in seaweedfs-filer.service seaweedfs-s3.service; do
      if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
        systemctl try-restart "$unit"
      fi
    done
  '';
  postgresBootstrap = pkgs.writeShellScript "jorthaus-seaweedfs-postgres-bootstrap" ''
    set -eu

    export PGPASSWORD="$(tr -d '\n' < ${config.age.secrets.patroni-postgres-superuser-password.path})"
    psql_base=(
      ${lib.getExe' pkgs.postgresql "psql"}
      "postgresql://postgres.service.jort.haus:5432/postgres?user=postgres&sslmode=verify-full&sslrootcert=system"
    )

    "''${psql_base[@]}" <<'SQL'
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'seaweedfs') THEN
        CREATE ROLE seaweedfs LOGIN;
      END IF;
    END
    $$;
    SQL

    if ! "''${psql_base[@]}" -tAc "SELECT 1 FROM pg_database WHERE datname = 'seaweedfs'" | grep -q 1; then
      "''${psql_base[@]}" -c 'CREATE DATABASE seaweedfs OWNER seaweedfs'
    fi

    "''${psql_base[@]}" <<'SQL'
    ALTER DATABASE seaweedfs OWNER TO seaweedfs;
    SQL

    ${lib.getExe' pkgs.postgresql "psql"} "postgresql://postgres.service.jort.haus:5432/seaweedfs?user=postgres&sslmode=verify-full&sslrootcert=system" <<'SQL'
    ALTER SCHEMA public OWNER TO seaweedfs;
    GRANT ALL ON SCHEMA public TO seaweedfs;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO seaweedfs;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO seaweedfs;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO seaweedfs;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO seaweedfs;
    SQL
  '';
in
{
  config = lib.mkIf (cfg.enable && cfg.controlplaneEnabled) {
    users = {
      groups.seaweedfs = { };

      users = {
        seaweedfs-master = {
          isSystemUser = true;
          group = "seaweedfs";
        };

        seaweedfs-filer = {
          isSystemUser = true;
          group = "seaweedfs";
        };
      };
    };

    age.secrets.${roleIdSecretName} = {
      file = ../../../../secrets/seaweedfs-approle-role-id.age;
      owner = "seaweedfs-filer";
      group = "seaweedfs";
      mode = "0400";
    };

    age.secrets.${secretIdSecretName} = {
      file = ../../../../secrets/seaweedfs-approle-secret-id.age;
      owner = "seaweedfs-filer";
      group = "seaweedfs";
      mode = "0400";
    };

    jorthaus.persistence.directories = [
      {
        directory = "/srv/seaweedfs";
        user = "root";
        group = "seaweedfs";
        mode = "0750";
      }
      {
        directory = cfg.master.dir;
        user = "seaweedfs-master";
        group = "seaweedfs";
        mode = "0750";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${filerRuntimeDir} 0750 seaweedfs-filer seaweedfs -"
    ];

    networking.firewall.allowedTCPPorts = [
      cfg.master.port
      cfg.master.grpcPort
    ];

    environment.systemPackages = [
      pkgs.seaweedfs
      pkgs.openbao
    ];

    services.vault-agent.instances.seaweedfs = {
      package = pkgs.openbao;
      user = "seaweedfs-filer";
      group = "seaweedfs";
      settings = {
        pid_file = "${filerRuntimeDir}/vault-agent.pid";

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
                };
              }
            ];

            sink = [
              {
                type = "file";
                config = {
                  path = "${filerRuntimeDir}/openbao.token";
                  mode = 256;
                };
              }
            ];
          }
        ];

        template_config.static_secret_render_interval = "5m";

        template = [
          {
            destination = credsFile;
            perms = 256;
            contents = ''
              PGHOST=postgres.service.jort.haus
              PGPORT=5432
              PGDATABASE=seaweedfs
              PGSSLMODE=verify-full
              PGSSLROOTCERT=system
              {{- with secret "postgres/static-creds/seaweedfs" }}
              PGUSER={{ .Data.username }}
              PGPASSWORD={{ .Data.password }}
              {{- end }}
            '';
          }
        ];
      };
    };

    systemd.services.seaweedfs-master = {
      description = "SeaweedFS master";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ cfg.master.dir ];
      serviceConfig = {
        User = "seaweedfs-master";
        Group = "seaweedfs";
        ExecStart = lib.escapeShellArgs [
          (lib.getExe' pkgs.seaweedfs "weed")
          "master"
          "-ip=${host.hostname}.node.jort.haus"
          "-ip.bind=${host.ipam.ipv4.address}"
          "-port=${toString cfg.master.port}"
          "-port.grpc=${toString cfg.master.grpcPort}"
          "-mdir=${cfg.master.dir}"
          "-peers=${cfg.master.peers}"
          "-volumeSizeLimitMB=${toString cfg.master.volumeSizeLimitMB}"
          "-resumeState=true"
          "-metricsIp=${host.ipam.ipv4.address}"
        ];
        Restart = "on-failure";
        RuntimeDirectory = "seaweedfs-master";
        RuntimeDirectoryMode = "0750";
      };
    };

    systemd.services.vault-agent-seaweedfs = {
      after = [
        "network-online.target"
        "agenix.service"
      ];
      wants = [
        "network-online.target"
        "agenix.service"
      ];
      serviceConfig = {
        RuntimeDirectory = lib.mkForce "seaweedfs-filer";
        RuntimeDirectoryMode = lib.mkForce "0750";
      };
    };

    systemd.services.jorthaus-seaweedfs-postgres-bootstrap = lib.mkIf (cfg.postgresBootstrapHost != null && host.hostname == cfg.postgresBootstrapHost.hostname) {
      description = "Ensure the SeaweedFS PostgreSQL role and database exist";
      after = [
        "network-online.target"
        "patroni.service"
      ];
      wants = [
        "network-online.target"
        "patroni.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = postgresBootstrap;
      };
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.jorthaus-seaweedfs-credential-refresh = {
      description = "Gracefully restart SeaweedFS services after credential changes";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = restartHelper;
      };
    };

    systemd.paths.jorthaus-seaweedfs-credential-refresh = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = credsFile;
        Unit = "jorthaus-seaweedfs-credential-refresh.service";
      };
    };
  };
}
