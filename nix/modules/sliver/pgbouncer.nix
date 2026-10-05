{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  enabled = host.slivers.pgbouncer.enable;
  systemdServices = [
    {
      unit = "pgbouncer.service";
      sliver = "pgbouncer";
      severity = "critical";
    }
  ];
  pgbouncerPort = 6432;
  serviceAddress = "10.1.11.17";
  serviceDnsName = "pgbouncer.service.jort.haus";
  nodeDnsName = "${host.hostname}.node.jort.haus";
  certName = "pgbouncer-${host.hostname}";
  certDir = config.security.acme.certs.${certName}.directory;
  caFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  passwordSecretName = "pgbouncer-seaweedfs-postgres-password";
  passwordFile = config.age.secrets.${passwordSecretName}.path;
in
{
  config = lib.mkMerge [
    { jorthaus.prometheus.systemdServices = systemdServices; }
    (lib.mkIf enabled {
    jorthaus.prometheus.localSystemdServices = [ "pgbouncer.service" ];
    jorthaus.routing.loopbackAddresses = [ "${serviceAddress}/32" ];

    assertions = [
      {
        assertion = host.slivers.postgres.enable;
        message = "The pgbouncer sliver requires the postgres sliver on the same host.";
      }
    ];

    age.secrets.${passwordSecretName} = {
      file = ../../../secrets/seaweedfs-postgres-password.age;
      owner = "pgbouncer";
      group = "pgbouncer";
      mode = "0400";
    };

    security.acme.certs.${certName} = {
      domain = nodeDnsName;
      extraDomainNames = [ serviceDnsName ];
      group = "pgbouncer";
      reloadServices = [ "pgbouncer.service" ];
    };

    services.pgbouncer = {
      enable = true;
      openFirewall = true;
      settings = {
        pgbouncer = {
          listen_addr = serviceAddress;
          listen_port = pgbouncerPort;
          auth_type = "scram-sha-256";
          auth_file = "/run/pgbouncer/userlist.txt";
          pool_mode = "transaction";
          max_client_conn = 200;
          default_pool_size = 10;
          reserve_pool_size = 2;
          reserve_pool_timeout = 5;
          max_db_connections = 12;
          max_user_connections = 12;
          ignore_startup_parameters = "extra_float_digits";
          stats_period = 60;
          client_tls_sslmode = "require";
          client_tls_ca_file = caFile;
          client_tls_cert_file = "${certDir}/fullchain.pem";
          client_tls_key_file = "${certDir}/key.pem";
          server_tls_sslmode = "verify-full";
          server_tls_ca_file = caFile;
        };
        databases.seaweedfs = "host=postgres.service.jort.haus port=5432 dbname=seaweedfs user=seaweedfs_static";
      };
    };

    systemd.services.pgbouncer = {
      after = [
        "var-lib-acme.mount"
        "acme-order-renew-${certName}.service"
        "haproxy.service"
      ];
      wants = [
        "acme-order-renew-${certName}.service"
      ];
      unitConfig = {
        RequiresMountsFor = [ "/var/lib/acme" ];
        ConditionPathExists = [
          "${certDir}/fullchain.pem"
          passwordFile
        ];
      };
      preStart = ''
        set -euo pipefail
        password="$(<${passwordFile})"
        if [[ ! "$password" =~ ^[[:xdigit:]]{64}$ ]]; then
          echo "Invalid SeaweedFS PostgreSQL password format" >&2
          exit 1
        fi
        printf '"seaweedfs_static" "%s"\n' "$password" > /run/pgbouncer/userlist.txt
        chmod 0400 /run/pgbouncer/userlist.txt
        unset password
      '';
      serviceConfig.RuntimeDirectoryMode = "0700";
    };

    })
  ];
}
