{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  enabled = host.slivers.postgres.enable;
  patroniScope = "jorthaus-postgres";
  patroniNamespace = "/service";
  restApiPort = 8008;
  postgresPort = 5432;
  postgresNetwork = "10.1.0.0/16";
  serviceAddress = "10.1.11.11";
  patroniDataDir = "/srv/patroni";
  postgresDataDir = "/srv/postgres/${pkgs.postgresql.psqlSchema}";
  certName = "postgres-${host.hostname}";
  nodeDnsName = "${host.hostname}.node.jort.haus";
  serviceDnsName = "postgres.service.jort.haus";
  certDir = config.security.acme.certs.${certName}.directory;
  tlsDir = "${patroniDataDir}/tls";
  stagedCertFile = "${tlsDir}/fullchain.pem";
  stagedKeyFile = "${tlsDir}/key.pem";
  caFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  postgresHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.postgres.enable) (builtins.attrValues hostInventory)
  );
  postgresBootstrapHost = if postgresHosts == [ ] then null else lib.head postgresHosts;
  etcdHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.etcd.enable) (builtins.attrValues hostInventory)
  );
  etcdHostsConfig = lib.concatStringsSep "," (
    map (peer: "${peer.hostname}.node.jort.haus:2379") etcdHosts
  );
  walGAppRoleName = "postgres-wal-g";
  walGRoleIdSecretName = "postgres-wal-g-approle-role-id";
  walGSecretIdSecretName = "postgres-wal-g-approle-secret-id";
  walGRoleIdFile = config.age.secrets.${walGRoleIdSecretName}.path;
  walGSecretIdFile = config.age.secrets.${walGSecretIdSecretName}.path;
  walGAgentDir = "/run/postgres-wal-g";
  walGEnvFile = "${walGAgentDir}/wal-g.env";
  walGBackupRole = "postgres_backup";
  walGWrapper = pkgs.writeShellScriptBin "jorthaus-wal-g" ''
    set -euo pipefail

    for _ in $(seq 1 30); do
      if [ -f ${walGEnvFile} ]; then
        break
      fi
      sleep 1
    done

    [ -f ${walGEnvFile} ]

    set -a
    . ${walGEnvFile}
    set +a

    export WALG_S3_CA_CERT_FILE=${caFile}

    exec ${lib.getExe pkgs.wal-g} "$@"
  '';
  walGRestoreWrapper = pkgs.writeShellScriptBin "jorthaus-wal-g-wal-fetch" ''
    set -euo pipefail

    if ${lib.getExe walGWrapper} wal-fetch "$1" "$2"; then
      exit 0
    else
      status=$?
    fi

    if [ "$status" -eq 74 ]; then
      exit 74
    fi

    exit 255
  '';
  postgresBackupBootstrap = pkgs.writeShellScriptBin "jorthaus-postgres-backup-bootstrap" ''
    set -euo pipefail

    export PGPASSWORD="$(tr -d '\n' < ${config.age.secrets.patroni-postgres-superuser-password.path})"
    psql_base=(
      ${lib.getExe' pkgs.postgresql "psql"}
      "postgresql://postgres.service.jort.haus:5432/postgres?user=postgres&sslmode=verify-full&sslrootcert=system"
    )

    "''${psql_base[@]}" <<'SQL'
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${walGBackupRole}') THEN
        CREATE ROLE ${walGBackupRole} LOGIN REPLICATION;
      END IF;
    END
    $$;

    ALTER ROLE ${walGBackupRole} WITH LOGIN REPLICATION CONNECTION LIMIT 5;
    GRANT pg_monitor TO ${walGBackupRole};
    GRANT CONNECT ON DATABASE postgres TO ${walGBackupRole};
    SQL
  '';
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = etcdHosts != [ ];
        message = "The postgres sliver requires at least one enabled etcd node.";
      }
    ];

    security.acme.certs.${certName} = {
      domain = nodeDnsName;
      extraDomainNames = [ serviceDnsName ];
      group = "patroni";
      reloadServices = [ "patroni.service" ];
    };

    # TODO: Move Postgres service credentials out of agenix and into OpenBao
    # delivery once the OpenBao-first bootstrap path is cleaned up. A small
    # bootstrap ring should remain, but steady-state database secrets should not
    # live as encrypted repo files.
    age.secrets.patroni-postgres-superuser-password = {
      file = ../../../secrets/patroni-postgres-superuser-password.age;
      owner = "patroni";
      group = "patroni";
      mode = "0400";
    };

    age.secrets.patroni-postgres-replication-password = {
      file = ../../../secrets/patroni-postgres-replication-password.age;
      owner = "patroni";
      group = "patroni";
      mode = "0400";
    };

    # PostgreSQL nodes authenticate to OpenBao with a small AppRole bootstrap so
    # WAL archival can read B2 credentials without storing them in the repo.
    age.secrets.${walGRoleIdSecretName} = {
      file = ../../../secrets/postgres-wal-g-approle-role-id.age;
      owner = "patroni";
      group = "patroni";
      mode = "0400";
    };

    age.secrets.${walGSecretIdSecretName} = {
      file = ../../../secrets/postgres-wal-g-approle-secret-id.age;
      owner = "patroni";
      group = "patroni";
      mode = "0400";
    };

    jorthaus.persistence.directories = [
      {
        directory = patroniDataDir;
        user = "patroni";
        group = "patroni";
        mode = "0700";
      }
      {
        directory = "/srv/postgres";
        user = "patroni";
        group = "patroni";
        mode = "0700";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${tlsDir} 0700 patroni patroni -"
      "d ${walGAgentDir} 0750 patroni patroni -"
    ];

    # TODO: Tighten Postgres and Patroni firewall exposure to the minimum set
    # of source networks once the long-term client and operator paths are
    # finalized.
    networking.firewall.allowedTCPPorts = [
      postgresPort
      restApiPort
    ];

    services.vault-agent.instances.${walGAppRoleName} = {
      package = pkgs.openbao;
      user = "patroni";
      group = "patroni";
      settings = {
        pid_file = "${walGAgentDir}/vault-agent.pid";

        vault = {
          address = "https://openbao.service.jort.haus:8200";
          tls_server_name = "openbao.service.jort.haus";
          ca_cert = caFile;
        };

        auto_auth = [
          {
            method = [
              {
                type = "approle";
                mount_path = "auth/approle";
                config = {
                  role_id_file_path = walGRoleIdFile;
                  secret_id_file_path = walGSecretIdFile;
                  remove_secret_id_file_after_reading = false;
                };
              }
            ];

            sink = [
              {
                type = "file";
                config = {
                  path = "${walGAgentDir}/openbao.token";
                  mode = 256;
                };
              }
            ];
          }
        ];

        template_config.static_secret_render_interval = "5m";

        template = [
          {
            destination = walGEnvFile;
            perms = 288;
            contents = ''
              {{- with secret "backup/data/postgres" }}
              AWS_ACCESS_KEY_ID={{ printf "%q" .Data.data.aws_access_key_id }}
              AWS_SECRET_ACCESS_KEY={{ printf "%q" .Data.data.aws_secret_access_key }}
              AWS_ENDPOINT={{ printf "%q" .Data.data.aws_endpoint }}
              AWS_REGION={{ printf "%q" .Data.data.aws_region }}
              WALG_S3_PREFIX={{ printf "%q" .Data.data.walg_s3_prefix }}
              AWS_S3_FORCE_PATH_STYLE=true
              WALG_PREVENT_WAL_OVERWRITE=true
              {{- end }}
            '';
          }
        ];
      };
    };

    systemd.services.vault-agent-postgres-wal-g = {
      after = [
        "network-online.target"
        "agenix.service"
      ] ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      wants = [
        "network-online.target"
        "agenix.service"
      ] ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      serviceConfig = {
        RuntimeDirectory = lib.mkForce "postgres-wal-g";
        RuntimeDirectoryMode = lib.mkForce "0750";
      };
    };

    systemd.services.patroni = {
      after = [
        "network-online.target"
        "var-lib-acme.mount"
        "vault-agent-postgres-wal-g.service"
      ];
      wants = [
        "network-online.target"
        "var-lib-acme.mount"
        "vault-agent-postgres-wal-g.service"
      ];
      unitConfig = {
        RequiresMountsFor = [
          patroniDataDir
          postgresDataDir
          "/var/lib/acme"
        ];
        ConditionPathExists = "${certDir}/fullchain.pem";
      };
      preStart = ''
        install -d -m 0700 -o patroni -g patroni ${tlsDir}
        install -m 0644 -o patroni -g patroni ${certDir}/fullchain.pem ${stagedCertFile}
        install -m 0400 -o patroni -g patroni ${certDir}/key.pem ${stagedKeyFile}
      '';
      serviceConfig = {
        RuntimeDirectory = "postgresql";
        RuntimeDirectoryMode = "0755";
      };
    };

    # TODO: Gate anycast advertisement for the Postgres VIP on local health so
    # the service address withdraws when this node cannot serve the intended
    # role.
    jorthaus.haproxy.services.postgres-rw = {
      enable = true;
      address = serviceAddress;
      port = postgresPort;
      mode = "tcp";
      backendConfig = ''
        option httpchk GET /primary
        http-check expect status 200
        default-server on-marked-down shutdown-sessions
      '';
      backends = map (peer: {
        name = peer.hostname;
        address = "${peer.hostname}.node.jort.haus";
        port = postgresPort;
        options = "check port ${toString restApiPort} check-ssl verify required ca-file ${caFile} verifyhost ${peer.hostname}.node.jort.haus sni str(${peer.hostname}.node.jort.haus) inter 2s fall 2 rise 1";
      }) postgresHosts;
      after = [ "patroni.service" ];
      wants = [ "patroni.service" ];
    };

    environment.systemPackages = [
      postgresBackupBootstrap
      walGWrapper
      walGRestoreWrapper
    ];

    # TODO: Keep database bootstrap and other cluster-scoped setup work out of
    # long-lived systemd units once a cleaner activation-time pattern exists.
    systemd.services.jorthaus-postgres-backup-bootstrap = lib.mkIf (postgresBootstrapHost != null && host.hostname == postgresBootstrapHost.hostname) {
      description = "Ensure the PostgreSQL physical backup role exists";
      wantedBy = [ "multi-user.target" ];
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
        ExecStart = lib.getExe postgresBackupBootstrap;
      };
    };

    services.patroni = {
      enable = true;
      postgresqlPackage = pkgs.postgresql;
      scope = patroniScope;
      name = host.hostname;
      namespace = patroniNamespace;
      nodeIp = host.ipam.ipv4.address;
      dataDir = patroniDataDir;
      postgresqlDataDir = postgresDataDir;
      postgresqlPort = postgresPort;
      restApiPort = restApiPort;

      environmentFiles = {
        PATRONI_SUPERUSER_PASSWORD = config.age.secrets.patroni-postgres-superuser-password.path;
        PATRONI_REPLICATION_PASSWORD = config.age.secrets.patroni-postgres-replication-password.path;
      };

      settings = {
        restapi = {
          listen = lib.mkForce "${host.ipam.ipv4.address}:${toString restApiPort}";
          connect_address = lib.mkForce "${nodeDnsName}:${toString restApiPort}";
          certfile = stagedCertFile;
          keyfile = stagedKeyFile;
          cafile = caFile;
        };

        postgresql = {
          listen = lib.mkForce "${host.ipam.ipv4.address}:${toString postgresPort}";
          connect_address = lib.mkForce "${nodeDnsName}:${toString postgresPort}";
        };

        ctl = {
          cacert = caFile;
        };

        etcd3 = {
          protocol = "https";
          hosts = etcdHostsConfig;
        };

        bootstrap = {
          dcs = {
            ttl = 30;
            loop_wait = 10;
            retry_timeout = 10;
            maximum_lag_on_failover = 1048576;
            synchronous_mode = true;
            synchronous_mode_strict = false;
            synchronous_node_count = 1;
            postgresql = {
              use_pg_rewind = true;
              use_slots = true;
              parameters = {
                wal_level = "replica";
                hot_standby = "on";
                max_wal_senders = 10;
                max_replication_slots = 10;
                wal_log_hints = "on";
                password_encryption = "scram-sha-256";
                archive_mode = "on";
                archive_timeout = "60s";
                archive_command = "${lib.getExe walGWrapper} wal-push %p";
              };
            };
          };

          initdb = [
            "encoding=UTF8"
            "data-checksums"
          ];
        };

        postgresql = {
          use_unix_socket = true;
          use_unix_socket_repl = true;

          authentication = {
            superuser.username = "postgres";
            replication = {
              username = "replicator";
              sslmode = "verify-full";
              sslrootcert = caFile;
            };
          };

          parameters = {
            unix_socket_directories = "/run/postgresql";
            ssl = "on";
            ssl_cert_file = stagedCertFile;
            ssl_key_file = stagedKeyFile;
            archive_mode = "on";
            archive_timeout = "60s";
            archive_command = "${lib.getExe walGWrapper} wal-push %p";
          };

          pg_hba = [
            "local all all scram-sha-256"
            "local replication replicator scram-sha-256"
            "hostssl replication replicator ${postgresNetwork} scram-sha-256"
            "hostssl replication ${walGBackupRole} ${postgresNetwork} scram-sha-256"
            "hostssl all all ${postgresNetwork} scram-sha-256"
          ];
        };
      };
    };
  };
}
