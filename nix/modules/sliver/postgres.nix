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
  patroniDataDir = "/srv/patroni";
  postgresDataDir = "/srv/postgres/${pkgs.postgresql.psqlSchema}";
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
            "host replication replicator ${postgresNetwork} scram-sha-256"
            "host all all ${postgresNetwork} scram-sha-256"
          ];
        };
      };
    };
  };
}
