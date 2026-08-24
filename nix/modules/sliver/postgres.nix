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
  etcdHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.etcd.enable) (builtins.attrValues hostInventory)
  );
  etcdHostsConfig = lib.concatStringsSep "," (
    map (peer: "${peer.hostname}.node.jort.haus:2379") etcdHosts
  );
in
{
  # TODO: sync replication
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
    ];

    networking.firewall.allowedTCPPorts = [
      postgresPort
      restApiPort
    ];

    systemd.services.patroni = {
      after = [ "network-online.target" "acme-order-renew-${certName}.service" ];
      wants = [ "network-online.target" "acme-order-renew-${certName}.service" ];
      unitConfig = {
        RequiresMountsFor = [
          patroniDataDir
          postgresDataDir
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
