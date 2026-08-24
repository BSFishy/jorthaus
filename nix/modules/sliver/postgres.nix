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
  # TODO: tls
  # TODO: sync replication
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = etcdHosts != [ ];
        message = "The postgres sliver requires at least one enabled etcd node.";
      }
    ];

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

    networking.firewall.allowedTCPPorts = [
      postgresPort
      restApiPort
    ];

    systemd.services.patroni = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [
        patroniDataDir
        postgresDataDir
      ];
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
        address = peer.ipam.ipv4.address;
        port = postgresPort;
        options = "check port ${toString restApiPort} inter 2s fall 2 rise 1";
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
          authentication = {
            superuser.username = "postgres";
            replication.username = "replicator";
          };

          parameters = {
            unix_socket_directories = "/run/postgresql";
          };

          pg_hba = [
            "local all all peer"
            "host all all 127.0.0.1/32 scram-sha-256"
            "host replication replicator 127.0.0.1/32 scram-sha-256"
            "host replication replicator ${postgresNetwork} scram-sha-256"
            "host all all ${postgresNetwork} scram-sha-256"
          ];
        };
      };
    };
  };
}
