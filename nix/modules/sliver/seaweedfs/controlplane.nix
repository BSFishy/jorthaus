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
  filerSigningKeySecretName = "seaweedfs-jwt-filer-signing-key";
  roleIdFile = config.age.secrets.${roleIdSecretName}.path;
  secretIdFile = config.age.secrets.${secretIdSecretName}.path;
  filerAgentDir = "/run/seaweedfs-agent-filer";
  filerRuntimeDir = "/run/seaweedfs-filer";
  filerConfigDir = "${filerRuntimeDir}/.seaweedfs";
  filerTomlPath = "${filerConfigDir}/filer.toml";
  credsFile = "${filerAgentDir}/postgres.env";
  s3ConfigFile = "${filerAgentDir}/s3.json";
  certName = "seaweedfs-${host.hostname}";
  nodeDnsName = "${host.hostname}.node.jort.haus";
  certDir = config.security.acme.certs.${certName}.directory;
  restartHelper = pkgs.writeShellScript "jorthaus-seaweedfs-credential-refresh" ''
    set -eu

    for unit in seaweedfs-filer.service; do
      if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
        systemctl try-restart "$unit"
      fi
    done
  '';
  renderFilerToml = pkgs.writeShellScript "jorthaus-seaweedfs-render-filer-toml" ''
    set -eu

    for _ in $(seq 1 30); do
      if [ -f ${credsFile} ]; then
        break
      fi
      sleep 1
    done

    [ -f ${credsFile} ]
    . ${credsFile}

    install -d -o seaweedfs-filer -g seaweedfs -m 0750 ${cfg.filer.dir}
    install -d -o seaweedfs-filer -g seaweedfs -m 0750 ${filerRuntimeDir}
    install -d -o seaweedfs-filer -g seaweedfs -m 0750 ${filerConfigDir}

    cat > ${filerTomlPath} <<EOF
    [filer.options]
    recursive_delete = false

    [postgres2]
    enabled = true
    createTable = """
      CREATE TABLE IF NOT EXISTS "%s" (
        dirhash   BIGINT,
        name      VARCHAR(65535) COLLATE "C",
        directory VARCHAR(65535),
        meta      bytea,
        PRIMARY KEY (dirhash, name)
      );
    """
    hostname = "$PGHOST"
    port = $PGPORT
    username = "$PGUSER"
    password = "$PGPASSWORD"
    database = "$PGDATABASE"
    schema = "public"
    sslmode = "$PGSSLMODE"
    sslrootcert = "$PGSSLROOTCERT"
    enableUpsert = true
    upsertQuery = """
      INSERT INTO "%[1]s" (dirhash, name, directory, meta)
        VALUES(\$1, \$2, \$3, \$4)
        ON CONFLICT (dirhash, name) DO UPDATE SET
          directory=EXCLUDED.directory,
          meta=EXCLUDED.meta
    """
    EOF

    chown seaweedfs-filer:seaweedfs ${filerTomlPath}
    chmod 0400 ${filerTomlPath}
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

    age.secrets.${filerSigningKeySecretName} = {
      file = ../../../../secrets/seaweedfs-jwt-filer-signing-key.age;
      owner = "seaweedfs-filer";
      group = "seaweedfs";
      mode = "0400";
    };

    security.acme.certs.${certName} = {
      domain = nodeDnsName;
      extraDomainNames = [
        cfg.master.dnsName
        cfg.filer.dnsName
        cfg.s3.dnsName
      ];
      group = "seaweedfs";
      reloadServices = [
        "seaweedfs-master.service"
        "seaweedfs-filer.service"
      ];
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
      {
        directory = cfg.filer.dir;
        user = "seaweedfs-filer";
        group = "seaweedfs";
        mode = "0750";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${filerAgentDir} 0750 seaweedfs-filer seaweedfs -"
      "d ${filerConfigDir} 0750 seaweedfs-filer seaweedfs -"
    ];

    jorthaus.routing.loopbackAddresses = [
      "${cfg.master.address}/32"
      "${cfg.filer.address}/32"
      "${cfg.s3.address}/32"
    ];

    networking.firewall.allowedTCPPorts = [
      cfg.master.port
      cfg.master.grpcPort
      cfg.filer.port
      cfg.filer.grpcPort
      cfg.s3.port
      cfg.s3.httpsPort
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
        pid_file = "${filerAgentDir}/vault-agent.pid";

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
                  path = "${filerAgentDir}/openbao.token";
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
          {
            destination = s3ConfigFile;
            perms = 256;
            contents = ''
              {{- with secret "seaweedfs/data/s3" }}
              {{ .Data.data.config_json }}
              {{- end }}
            '';
          }
        ];

        # TODO: Replace the static OpenBao-rendered S3 identity config with an
        # OpenBao plugin that issues dynamic JWT or equivalent short-lived S3
        # credentials for clients.
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
          "-ip.bind=0.0.0.0"
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

    systemd.services.seaweedfs-filer = {
      description = "SeaweedFS filer and S3 gateway";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "vault-agent-seaweedfs.service"
        "acme-order-renew-${certName}.service"
      ];
      wants = [
        "network-online.target"
        "vault-agent-seaweedfs.service"
        "acme-order-renew-${certName}.service"
      ];
      unitConfig = {
        RequiresMountsFor = [ cfg.filer.dir ];
        ConditionPathExists = "${certDir}/fullchain.pem";
      };
      serviceConfig = {
        User = "seaweedfs-filer";
        Group = "seaweedfs";
        Environment = [ "HOME=${filerRuntimeDir}" ];
        ExecStartPre = renderFilerToml;
        ExecStart = lib.escapeShellArgs [
          (lib.getExe' pkgs.seaweedfs "weed")
          "filer"
          "-master=${cfg.filer.masters}"
          "-ip=${host.hostname}.node.jort.haus"
          "-ip.bind=0.0.0.0"
          "-port=${toString cfg.filer.port}"
          "-port.grpc=${toString cfg.filer.grpcPort}"
          "-defaultStoreDir=${cfg.filer.dir}"
          "-s3"
          "-s3.port=${toString cfg.s3.port}"
          "-s3.port.https=${toString cfg.s3.httpsPort}"
          "-s3.ip.bind=0.0.0.0"
          "-s3.cert.file=${certDir}/fullchain.pem"
          "-s3.key.file=${certDir}/key.pem"
          "-s3.config=${s3ConfigFile}"
          "-metricsIp=${host.ipam.ipv4.address}"
        ];
        Restart = "on-failure";
        RuntimeDirectory = "seaweedfs-filer";
        RuntimeDirectoryMode = "0750";
        WorkingDirectory = filerRuntimeDir;
        EnvironmentFile = config.age.secrets.${filerSigningKeySecretName}.path;
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
        RuntimeDirectory = lib.mkForce "seaweedfs-agent-filer";
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

    systemd.paths.jorthaus-seaweedfs-s3-config-refresh = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = s3ConfigFile;
        Unit = "jorthaus-seaweedfs-credential-refresh.service";
      };
    };
  };
}
