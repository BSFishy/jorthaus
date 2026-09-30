{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  prometheusHosts = lib.filter (peer: peer.slivers.prometheus.enable) (
    builtins.attrValues hostInventory
  );
  alertmanagerHosts = lib.filter (peer: peer.slivers.alertmanager.enable) (
    builtins.attrValues hostInventory
  );
  nodeExporterHosts = lib.filter (peer: peer.slivers.nodeExporter.enable) (
    builtins.attrValues hostInventory
  );
  victorialogsHosts = lib.filter (peer: peer.slivers.victorialogs.enable) (
    builtins.attrValues hostInventory
  );
  isPrometheus = host.slivers.prometheus.enable;
  isAlertmanager = host.slivers.alertmanager.enable;
  projectDisks = lib.filter (disk: disk.projects ? prometheus) host.install.dataDisks;
  projectDefined = projectDisks != [ ];
  projectDisk = if projectDefined then lib.head projectDisks else null;
  quotaEnabled = projectDefined && projectDisk.projects.prometheus.enforce;
  dataPath = "${projectDisk.mountpoint}/prometheus";
  statePath = "/var/lib/prometheus";
  otherAlertmanagerHosts = lib.filter (peer: peer.hostname != host.hostname) alertmanagerHosts;
  hostTarget = peer: "${peer.ipam.ipv4.address}:9100";
  alertmanagerTarget = peer: "${peer.ipam.ipv4.address}:9093";
  prometheusTarget = peer: "${peer.ipam.ipv4.address}:9090";
  victorialogsTarget = peer: "${peer.ipam.ipv4.address}:9428";
  thanosRuntimeDir = "/run/thanos-sidecar";
  seaweedfsProvisionerHost =
    if config.jorthaus.seaweedfs.controlplaneHosts == [ ] then
      null
    else
      (builtins.head config.jorthaus.seaweedfs.controlplaneHosts).hostname;
  isSeaweedfsProvisionerHost = host.hostname == seaweedfsProvisionerHost;
  seaweedfsRoleIdFile = config.age.secrets."seaweedfs-approle-role-id".path;
  seaweedfsSecretIdFile = config.age.secrets."seaweedfs-approle-secret-id".path;
in
{
  imports = [ ./s3.nix ];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.length prometheusHosts == 2;
          message = "Exactly two Prometheus hosts must be enabled for the HA pair.";
        }
        {
          assertion = lib.length alertmanagerHosts == 3;
          message = "Exactly three Alertmanager hosts must be enabled for the HA cluster.";
        }
        {
          assertion = nodeExporterHosts != [ ];
          message = "At least one node exporter must be enabled.";
        }
      ];
    }

    (lib.mkIf host.slivers.nodeExporter.enable {
      services.prometheus.exporters.node = {
        enable = true;
        listenAddress = host.ipam.ipv4.address;
        openFirewall = true;
      };
    })

    (lib.mkIf isPrometheus {
      assertions = [
        {
          assertion = lib.length projectDisks == 1;
          message = "Prometheus requires exactly one data-disk project on ${host.hostname}.";
        }
        {
          assertion = quotaEnabled;
          message = "Prometheus requires an enforced XFS project quota on ${host.hostname}.";
        }
      ];

      jorthaus.xfsQuota.projects.prometheus = {
        id = 102;
        fileSystem = projectDisk.mountpoint;
        path = dataPath;
        quota = projectDisk.projects.prometheus.quota;
      };

      systemd.tmpfiles.rules = [
        "d ${dataPath} 0750 prometheus prometheus -"
      ];

      systemd.mounts = [
        {
          what = dataPath;
          where = statePath;
          type = "none";
          options = "bind";
          before = [ "prometheus.service" ];
        }
      ];

      networking.firewall.allowedTCPPorts = [
        9090
        10901
      ];

      environment.systemPackages = [ pkgs.prometheus ];

      services.prometheus = {
        enable = true;
        listenAddress = host.ipam.ipv4.address;
        stateDir = "prometheus";
        retentionTime = "30d";
        extraFlags = [
          "--storage.tsdb.min-block-duration=2h"
          "--storage.tsdb.max-block-duration=2h"
          "--storage.tsdb.retention.size=15GB"
        ];
        globalConfig = {
          scrape_interval = "30s";
          evaluation_interval = "30s";
          external_labels = {
            cluster = "jorthaus";
            replica = host.hostname;
          };
        };
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = map (peer: {
              targets = [ (hostTarget peer) ];
              labels.host = peer.hostname;
            }) nodeExporterHosts;
          }
          {
            job_name = "prometheus";
            static_configs = map (peer: {
              targets = [ (prometheusTarget peer) ];
              labels.host = peer.hostname;
            }) prometheusHosts;
          }
          {
            job_name = "thanos-sidecar";
            static_configs = [
              {
                targets = [ "127.0.0.1:10902" ];
                labels.host = host.hostname;
              }
            ];
          }
          {
            job_name = "alertmanager";
            static_configs = map (peer: {
              targets = [ (alertmanagerTarget peer) ];
              labels.host = peer.hostname;
            }) alertmanagerHosts;
          }
          {
            job_name = "victorialogs";
            static_configs = map (peer: {
              targets = [ (victorialogsTarget peer) ];
              labels.host = peer.hostname;
            }) victorialogsHosts;
          }
        ];
        alertmanagers = [
          {
            static_configs = [
              {
                targets = map alertmanagerTarget alertmanagerHosts;
              }
            ];
            alert_relabel_configs = [
              {
                action = "labeldrop";
                regex = "replica";
              }
            ];
          }
        ];
        rules = [ (builtins.readFile ./rules.yml) ];
      };

      users.groups."thanos-sidecar".members = [ "prometheus" ];

      services.vault-agent.instances.thanos-sidecar = {
        package = pkgs.openbao;
        user = "root";
        group = "thanos-sidecar";
        settings = {
          pid_file = "${thanosRuntimeDir}/vault-agent.pid";
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
                    role_id_file_path = seaweedfsRoleIdFile;
                    secret_id_file_path = seaweedfsSecretIdFile;
                    remove_secret_id_file_after_reading = false;
                  };
                }
              ];
              sink = [
                {
                  type = "file";
                  config = {
                    path = "${thanosRuntimeDir}/openbao.token";
                    mode = 256;
                  };
                }
              ];
            }
          ];
          template_config.static_secret_render_interval = "5m";
          template = [
            {
              destination = "${thanosRuntimeDir}/credentials.env";
              perms = 288;
              contents = ''
                {{- with secret "seaweedfs/data/s3/bindings/thanos" }}
                AWS_ACCESS_KEY_ID={{ .Data.data.access_key_id }}
                AWS_SECRET_ACCESS_KEY={{ .Data.data.secret_access_key }}
                {{- end }}
              '';
            }
          ];
        };
      };

      systemd.services."vault-agent-thanos-sidecar" = {
        after = [
          "network-online.target"
          "agenix.service"
        ]
        ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ]
        ++ lib.optionals isSeaweedfsProvisionerHost [ "jorthaus-seaweedfs-s3-provisioner.service" ];
        wants = [
          "network-online.target"
          "agenix.service"
        ]
        ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ]
        ++ lib.optionals isSeaweedfsProvisionerHost [ "jorthaus-seaweedfs-s3-provisioner.service" ];
        postStart = ''
          for _ in $(seq 1 60); do
            if test -s ${lib.escapeShellArg "${thanosRuntimeDir}/credentials.env"}; then
              exit 0
            fi
            sleep 1
          done
          echo "timed out waiting for Thanos Sidecar credentials from OpenBao" >&2
          exit 1
        '';
        serviceConfig = {
          RuntimeDirectory = lib.mkForce "thanos-sidecar";
          RuntimeDirectoryMode = lib.mkForce "0750";
        };
      };

      services.thanos.sidecar = {
        enable = true;
        grpc-address = "${host.ipam.ipv4.address}:10901";
        http-address = "127.0.0.1:10902";
        prometheus.url = "http://${host.ipam.ipv4.address}:9090";
        tsdb.path = "${statePath}/data";
        objstore.config = {
          type = "S3";
          config = {
            bucket = "thanos";
            endpoint = "s3.service.jort.haus:8443";
            region = "us-east-1";
            aws_sdk_auth = true;
            bucket_lookup_type = "path";
          };
        };
      };

      systemd.services.thanos-sidecar = {
        after = [
          "prometheus.service"
          "vault-agent-thanos-sidecar.service"
        ];
        requires = [
          "prometheus.service"
          "vault-agent-thanos-sidecar.service"
        ];
        preStart = ''
          for _ in $(seq 1 60); do
            if test -s ${lib.escapeShellArg "${thanosRuntimeDir}/credentials.env"}; then
              exit 0
            fi
            sleep 1
          done
          echo "timed out waiting for Thanos Sidecar object-store credentials" >&2
          exit 1
        '';
        serviceConfig = {
          EnvironmentFile = "${thanosRuntimeDir}/credentials.env";
          Group = "prometheus";
          MemoryHigh = "1G";
          MemoryMax = "2G";
          TasksMax = 256;
          LimitNOFILE = 65536;
        };
      };

      systemd.services.prometheus = {
        after = [
          "xfs_quota-prometheus.service"
          "var-lib-prometheus.mount"
        ];
        requires = [
          "xfs_quota-prometheus.service"
          "var-lib-prometheus.mount"
        ];
        unitConfig.RequiresMountsFor = [ dataPath ];
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = "prometheus";
          Group = "prometheus";
          PrivateUsers = lib.mkForce false;
          StateDirectory = lib.mkForce null;
          MemoryHigh = "3G";
          MemoryMax = "4G";
          TasksMax = 256;
          LimitNOFILE = 65536;
        };
      };
    })

    (lib.mkIf isAlertmanager {
      users.groups.alertmanager = { };
      users.users.alertmanager = {
        isSystemUser = true;
        group = "alertmanager";
      };

      jorthaus.persistence.directories = [ "/var/lib/alertmanager" ];

      networking.firewall.allowedTCPPorts = [
        9093
        9094
      ];
      networking.firewall.allowedUDPPorts = [ 9094 ];

      services.prometheus.alertmanager = {
        enable = true;
        listenAddress = host.ipam.ipv4.address;
        openFirewall = true;
        clusterPeers = map (peer: peer.ipam.ipv4.address) otherAlertmanagerHosts;
        configuration = {
          global.resolve_timeout = "5m";
          route = {
            receiver = "blackhole";
            group_by = [
              "alertname"
              "cluster"
              "job"
              "instance"
            ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "12h";
          };
          receivers = [ { name = "blackhole"; } ];
        };
      };

      systemd.services.alertmanager.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "alertmanager";
        Group = "alertmanager";
      };
    })
  ];
}
