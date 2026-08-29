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
  backupSecretName = "pgbackrest-b2-env";
  backupStanza = patroniScope;
  backupRepoName = "b2";
  backupRepoPath = "/jorthaus-postgres";
  backupSpoolDir = "/srv/pgbackrest/spool";
  backupHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.postgres.enable) (builtins.attrValues hostInventory)
  );
  backupHost = lib.head backupHosts;
  backupEnvFile = config.age.secrets.${backupSecretName}.path;
  pgbackrestWrapper = pkgs.writeShellScriptBin "jorthaus-pgbackrest" ''
    set -eu
    set -a
    . ${backupEnvFile}
    set +a
    export PGPASSWORD="$(tr -d '\n' < ${config.age.secrets.patroni-postgres-superuser-password.path})"
    exec ${lib.getExe pkgs.pgbackrest} "$@"
  '';
  postgresHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.postgres.enable) (builtins.attrValues hostInventory)
  );
  etcdHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.etcd.enable) (builtins.attrValues hostInventory)
  );
  etcdHostsConfig = lib.concatStringsSep "," (
    map (peer: "${peer.hostname}.node.jort.haus:2379") etcdHosts
  );
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

    age.secrets.${backupSecretName} = {
      file = ../../../secrets/pgbackrest-b2-env.age;
      owner = "patroni";
      group = "pgbackrest";
      mode = "0440";
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
      {
        directory = "/srv/pgbackrest";
        user = "patroni";
        group = "patroni";
        mode = "0700";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${tlsDir} 0700 patroni patroni -"
      "d /run/pgbackrest 0700 patroni patroni -"
      "d ${backupSpoolDir} 0700 patroni patroni -"
    ];

    # TODO: Tighten Postgres and Patroni firewall exposure to the minimum set
    # of source networks once the long-term client and operator paths are
    # finalized.
    networking.firewall.allowedTCPPorts = [
      postgresPort
      restApiPort
    ];

    systemd.services.patroni = {
      after = [
        "network-online.target"
        "var-lib-acme.mount"
      ];
      wants = [
        "network-online.target"
        "var-lib-acme.mount"
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

    # TODO: Run pgBackRest from Kubernetes once the cluster exists. The backup
    # schedule and ad hoc check job fit better as CronJobs than as node-local
    # systemd timers and oneshot services.
    services.pgbackrest = {
      enable = true;
      settings = {
        lock-path = "/run/pgbackrest";
        spool-path = backupSpoolDir;
        start-fast = true;
        compress-type = "zst";
        process-max = 2;
      };
      repos.${backupRepoName} = {
        type = "s3";
        path = backupRepoPath;
        s3-uri-style = "path";
        retention-full = 2;
        retention-diff = 6;
        retention-archive = 2;
        retention-archive-type = "full";
      };
      stanzas.${backupStanza} = {
        instances.localhost = {
          path = postgresDataDir;
          port = postgresPort;
          socket-path = "/run/postgresql";
          user = "postgres";
        };
        settings = {
          archive-check = true;
        };
      };
    };

    environment.systemPackages = [ pgbackrestWrapper ];

    users.users.patroni.extraGroups = [ "pgbackrest" ];

    # TODO: Keep database bootstrap and other cluster-scoped setup work out of
    # long-lived systemd units once a cleaner activation-time pattern exists.
    systemd.services.jorthaus-pgbackrest-check = {
      description = "Check pgBackRest stanza ${backupStanza}";
      after = [ "network-online.target" "patroni.service" ];
      wants = [ "network-online.target" "patroni.service" ];
      unitConfig.RequiresMountsFor = [ postgresDataDir "/srv/pgbackrest" ];
      serviceConfig = {
        Type = "oneshot";
        User = "patroni";
        Group = "patroni";
      };
      script = ''
        ${lib.getExe pgbackrestWrapper} --stanza=${backupStanza} stanza-create
        ${lib.getExe pgbackrestWrapper} --stanza=${backupStanza} check
      '';
    };

    systemd.services.jorthaus-pgbackrest-backup-full = lib.mkIf (host.hostname == backupHost.hostname) {
      description = "Run full pgBackRest backup for ${backupStanza}";
      after = [ "network-online.target" "patroni.service" ];
      wants = [ "network-online.target" "patroni.service" ];
      unitConfig.RequiresMountsFor = [ postgresDataDir "/srv/pgbackrest" ];
      serviceConfig = {
        Type = "oneshot";
        User = "patroni";
        Group = "patroni";
      };
      script = ''
        ${lib.getExe pgbackrestWrapper} --stanza=${backupStanza} stanza-create
        ${lib.getExe pgbackrestWrapper} --stanza=${backupStanza} backup --type=full
      '';
    };

    systemd.services.jorthaus-pgbackrest-backup-diff = lib.mkIf (host.hostname == backupHost.hostname) {
      description = "Run differential pgBackRest backup for ${backupStanza}";
      after = [ "network-online.target" "patroni.service" ];
      wants = [ "network-online.target" "patroni.service" ];
      unitConfig.RequiresMountsFor = [ postgresDataDir "/srv/pgbackrest" ];
      serviceConfig = {
        Type = "oneshot";
        User = "patroni";
        Group = "patroni";
      };
      script = ''
        ${lib.getExe pgbackrestWrapper} --stanza=${backupStanza} stanza-create
        ${lib.getExe pgbackrestWrapper} --stanza=${backupStanza} backup --type=diff
      '';
    };

    systemd.timers.jorthaus-pgbackrest-backup-full = lib.mkIf (host.hostname == backupHost.hostname) {
      description = "Weekly full pgBackRest backup for ${backupStanza}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 03:15:00 UTC";
        Persistent = true;
        Unit = "jorthaus-pgbackrest-backup-full.service";
      };
    };

    systemd.timers.jorthaus-pgbackrest-backup-diff = lib.mkIf (host.hostname == backupHost.hostname) {
      description = "Daily differential pgBackRest backup for ${backupStanza}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Mon..Sat *-*-* 03:15:00 UTC";
        Persistent = true;
        Unit = "jorthaus-pgbackrest-backup-diff.service";
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
                archive_command = "${lib.getExe pgbackrestWrapper} --stanza=${backupStanza} archive-push %p";
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
            archive_command = "${lib.getExe pgbackrestWrapper} --stanza=${backupStanza} archive-push %p";
          };

          pg_hba = [
            "local all all scram-sha-256"
            "local replication replicator scram-sha-256"
            "hostssl replication replicator ${postgresNetwork} scram-sha-256"
            "hostssl all all ${postgresNetwork} scram-sha-256"
          ];
        };
      };
    };
  };
}
