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
  postgresHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.postgres.enable) (builtins.attrValues hostInventory)
  );
  victorialogsHosts = lib.filter (peer: peer.slivers.victorialogs.enable) (
    builtins.attrValues hostInventory
  );
  kubeletHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.k3s.enable) (builtins.attrValues hostInventory)
  );
  controlPlaneHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (
      peer: peer.slivers.k3s.enable && peer.slivers.k3s.role == "controlplane"
    ) (builtins.attrValues hostInventory)
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
  prometheusSystemdServices =
    lib.optional (nodeExporterHosts != [ ]) {
      unit = "prometheus-node-exporter.service";
      sliver = "nodeExporter";
      severity = "warning";
    }
    ++ lib.optional (prometheusHosts != [ ]) {
      unit = "prometheus.service";
      sliver = "prometheus";
      severity = "critical";
    }
    ++ lib.optional (prometheusHosts != [ ]) {
      unit = "thanos-sidecar.service";
      sliver = "prometheus";
      severity = "warning";
    }
    ++ lib.optional (alertmanagerHosts != [ ]) {
      unit = "alertmanager.service";
      sliver = "alertmanager";
      severity = "warning";
    };
  localPrometheusSystemdServices =
    lib.optionals host.slivers.nodeExporter.enable [ "prometheus-node-exporter.service" ]
    ++ lib.optionals isPrometheus [ "prometheus.service" "thanos-sidecar.service" ]
    ++ lib.optionals isAlertmanager [ "alertmanager.service" ];
  hostTarget = peer: "${peer.ipam.ipv4.address}:9100";
  postgresTarget = peer: "${peer.ipam.ipv4.address}:9187";
  postgresBootstrapHost = if postgresHosts == [ ] then null else lib.head postgresHosts;
  alertmanagerTarget = peer: "${peer.ipam.ipv4.address}:9093";
  prometheusTarget = peer: "${peer.ipam.ipv4.address}:9090";
  victorialogsTarget = peer: "${peer.ipam.ipv4.address}:9428";
  kubeStateMetricsTarget = "10.43.200.50:8080";
  kubeletTarget = peer: "${peer.ipam.ipv4.address}:10250";
  appMetricsTokenFile = config.age.secrets."prometheus-app-metrics-token".path;
  appMetricsKubeconfigFile = pkgs.writeText "prometheus-app-metrics.kubeconfig" ''
    apiVersion: v1
    kind: Config
    clusters:
      - cluster:
          certificate-authority: ${kubeletCaFile}
          server: https://k8s.service.jort.haus:6443
        name: jorthaus
    contexts:
      - context:
          cluster: jorthaus
          user: prometheus-app-metrics
        name: jorthaus
    current-context: jorthaus
    users:
      - name: prometheus-app-metrics
        user:
          tokenFile: ${appMetricsTokenFile}
  '';
  appMetricsDiscovery = namespace: {
    role = "endpoints";
    kubeconfig_file = "${appMetricsKubeconfigFile}";
    namespaces.names = [ namespace ];
  };
  appMetricsRelabelConfigs =
    { serviceName, portName, requireOptIn ? true }:
    [
      {
        source_labels = [ "__meta_kubernetes_endpoint_ready" ];
        regex = "true";
        action = "keep";
      }
      {
        source_labels = [ "__meta_kubernetes_service_name" ];
        regex = serviceName;
        action = "keep";
      }
      {
        source_labels = [ "__meta_kubernetes_endpoint_port_name" ];
        regex = portName;
        action = "keep";
      }
      {
        source_labels = [ "__meta_kubernetes_pod_node_name" ];
        target_label = "host";
      }
      {
        source_labels = [ "__meta_kubernetes_namespace" ];
        target_label = "namespace";
      }
    ]
    ++ lib.optionals requireOptIn [
      {
        source_labels = [ "__meta_kubernetes_service_label_prometheus_jort_haus_scrape" ];
        regex = "true";
        action = "keep";
      }
    ];
  applicationMetricRuntimeAllowlist =
    "process_cpu_seconds_total|process_resident_memory_bytes|process_start_time_seconds|go_goroutines|go_gc_duration_seconds(_.*)?|go_memstats_.*";
  traefikMetricAllowlist = "^(traefik_.*|${applicationMetricRuntimeAllowlist})$";
  certManagerMetricAllowlist = "^(certmanager_.*|controller_runtime_.*|workqueue_.*|${applicationMetricRuntimeAllowlist})$";
  authentikServerMetricAllowlist =
    "^(authentik_(admin_workers|outposts_connected|outposts_last_update|tasks_queued|tasks_workers|flows_cached|flows_plan_time_(bucket|count|sum)|flows_stage_time_(bucket|count|sum)|flows_execution_stage_time_(bucket|count|sum)|policies_cached|policies_execution_time_(bucket|count|sum)|policies_engine_time_total_seconds_(bucket|count|sum)|property_mapping_execution_time_(bucket|count|sum)|main_request_duration_seconds(_count|_sum)?)|django_http_(requests_latency_seconds_by_view_method_(bucket|count|sum)|requests_latency_including_middlewares_seconds_(bucket|count|sum)|requests_total_by_view_transport_method_total|responses_total_by_status_view_method_total|responses_total_by_status_total)|django_db_(query_duration_seconds_(bucket|count|sum)|execute_total|new_connections_total|new_connection_errors_total)|${applicationMetricRuntimeAllowlist})$";
  authentikWorkerMetricAllowlist =
    "^(authentik_(admin_workers|tasks_(queued|in_progress|total|errors_total|retries_total|workers|duration_milliseconds_(bucket|count|sum))|policies_cached|policies_execution_time_(bucket|count|sum)|policies_engine_time_total_seconds_(bucket|count|sum))|django_db_(query_duration_seconds_(bucket|count|sum)|execute_total|execute_many_total|new_connections_total|new_connection_errors_total)|${applicationMetricRuntimeAllowlist})$";
  seaweedCsiMetricAllowlist =
    "^(csi_sidecar_operations_seconds_(bucket|count|sum)|workqueue_.*|process_start_time_seconds|${applicationMetricRuntimeAllowlist})$";
  ciliumEnvoyMetricAllowlist = "^(envoy_.*|${applicationMetricRuntimeAllowlist})$";
  ciliumOperatorMetricAllowlist = "^(cilium_.*|workqueue_.*|${applicationMetricRuntimeAllowlist})$";
  ciliumAgentMetricAllowlist = "^(cilium_.*|workqueue_.*|${applicationMetricRuntimeAllowlist})$";
  corednsMetricAllowlist = "^(coredns_.*|${applicationMetricRuntimeAllowlist})$";
  kuredMetricAllowlist = "^(kured_.*|promhttp_.*|${applicationMetricRuntimeAllowlist})$";
  secretsStoreMetricAllowlist =
    "^(certwatcher_.*|controller_runtime_.*|node_(publish|unpublish)_.*|rotation_reconcile_.*|rest_client_requests_total|target_info|workqueue_.*|${applicationMetricRuntimeAllowlist})$";
  thanosMetricAllowlist = "^(thanos_.*|prometheus_.*|grpc_.*|http_.*|promhttp_.*|${applicationMetricRuntimeAllowlist})$";
  controlPlaneMetricAllowlist =
    "^("
    + lib.concatStringsSep "|" [
      "apiserver_request_total"
      "apiserver_request_duration_seconds_(count|sum)"
      "apiserver_request_sli_duration_seconds_(count|sum)"
      "apiserver_current_inflight_requests"
      "apiserver_current_inqueue_requests"
      "apiserver_longrunning_requests"
      "apiserver_storage_objects"
      "apiserver_storage_size_bytes"
      "apiserver_storage_data_key_generation_failures_total"
      "apiserver_tls_handshake_errors_total"
      "apiserver_audit_requests_rejected_total"
      "apiserver_flowcontrol_request_dispatch_no_accommodation_total"
      "scheduler_pending_pods"
      "scheduler_unschedulable_pods"
      "scheduler_schedule_attempts_total"
      "scheduler_queue_incoming_pods_total"
      "scheduler_scheduling_attempt_duration_seconds_(count|sum)"
      "scheduler_scheduling_algorithm_duration_seconds_(count|sum)"
      "scheduler_framework_extension_point_duration_seconds_(count|sum)"
      "workqueue_depth"
      "workqueue_retries_total"
      "workqueue_unfinished_work_seconds"
      "node_collector_update_all_nodes_health_duration_seconds_(count|sum)"
      "node_collector_update_node_health_duration_seconds_(count|sum)"
      "node_controller_cloud_provider_taint_removal_delay_seconds_(count|sum)"
      "node_controller_initial_node_sync_delay_seconds_(count|sum)"
      "kine_sql_time_seconds_(count|sum)"
      "kine_sql_total"
      "kine_insert_errors_total"
      "k3s_certificate_expiration_seconds"
      "process_cpu_seconds_total"
      "process_resident_memory_bytes"
    ]
    + ")$";
  kubeletMetricAllowlist =
    "^("
    + lib.concatStringsSep "|" [
      "kubelet_active_pods"
      "kubelet_running_containers"
      "kubelet_running_pods"
      "kubelet_working_pods"
      "kubelet_runtime_operations_total"
      "kubelet_runtime_operations_errors_total"
      "kubelet_runtime_operations_duration_seconds_(bucket|count|sum)"
      "kubelet_pleg_relist_duration_seconds_(bucket|count|sum)"
      "kubelet_pod_start_sli_duration_seconds_(bucket|count|sum)"
      "kubelet_container_log_filesystem_used_bytes"
      "volume_manager_total_volumes"
      "k3s_certificate_expiration_seconds"
      "kubernetes_build_info"
      "process_cpu_seconds_total"
      "process_resident_memory_bytes"
    ]
    + ")$";
  cadvisorMetricAllowlist =
    "^("
    + lib.concatStringsSep "|" [
      "container_cpu_usage_seconds_total"
      "container_cpu_cfs_throttled_periods_total"
      "container_cpu_cfs_throttled_seconds_total"
      "container_memory_working_set_bytes"
      "container_memory_rss"
      "container_memory_cache"
      "container_oom_events_total"
      "container_fs_usage_bytes"
      "container_fs_reads_bytes_total"
      "container_fs_writes_bytes_total"
      "container_network_receive_bytes_total"
      "container_network_transmit_bytes_total"
      "container_network_receive_errors_total"
      "container_network_transmit_errors_total"
      "container_spec_memory_limit_bytes"
      "container_spec_cpu_quota"
      "container_spec_cpu_period"
      "machine_cpu_cores"
      "machine_memory_bytes"
    ]
    + ")$";
  kubeletTokenFile = config.age.secrets."prometheus-kubelet-token".path;
  controlPlaneTokenFile = config.age.secrets."prometheus-control-plane-token".path;
  kubeletCaFile = config.age.secrets."prometheus-kubelet-ca".path;
  thanosRuntimeDir = "/run/thanos-sidecar";
  seaweedfsProvisionerHost =
    if config.jorthaus.seaweedfs.controlplaneHosts == [ ] then
      null
    else
      (builtins.head config.jorthaus.seaweedfs.controlplaneHosts).hostname;
  isSeaweedfsProvisionerHost = host.hostname == seaweedfsProvisionerHost;
  seaweedfsRoleIdFile = config.age.secrets."seaweedfs-approle-role-id".path;
  seaweedfsSecretIdFile = config.age.secrets."seaweedfs-approle-secret-id".path;
  systemdServices = config.jorthaus.prometheus.systemdServices;
  localSystemdServices = config.jorthaus.prometheus.localSystemdServices;
  systemdUnitInclude = "^(${
    lib.concatStringsSep "|" (
      map (unit: lib.replaceStrings [ "." ] [ "[.]" ] unit) localSystemdServices
    )
  })$";
  systemdUnitDefinitions = lib.foldl' (
    definitions: service:
    if lib.any (definition: definition.unit == service.unit) definitions then
      definitions
    else
      definitions ++ [ service ]
  ) [ ] systemdServices;
  systemdUnitDefinitionsConsistent = lib.all (
    unit:
    let
      definitions = lib.filter (service: service.unit == unit) systemdServices;
      first = lib.head definitions;
    in
    lib.all (
      service: service.severity == first.severity && service.sliver == first.sliver
    ) definitions
  ) (map (service: service.unit) systemdUnitDefinitions);
  systemdAlertRules = lib.concatMap (service: [
    {
      alert = "SystemdServiceFailed";
      expr = ''
        node_systemd_unit_state{
          job="node",name="${service.unit}",state="failed"
        } == 1
      '';
      for = "5m";
      labels = {
        inherit (service) severity sliver;
        unit = service.unit;
      };
      annotations = {
        summary = "Systemd unit {{ $labels.name }} failed on {{ $labels.host }}";
        description = "Systemd unit {{ $labels.name }} has remained failed on {{ $labels.host }}.";
      };
    }
    {
      alert = "SystemdServiceNotActive";
      expr = ''
        node_systemd_unit_state{
          job="node",name="${service.unit}",state=~"inactive|activating|deactivating"
        } == 1
      '';
      for = "5m";
      labels = {
        inherit (service) severity sliver;
        unit = service.unit;
      };
      annotations = {
        summary = "Systemd unit {{ $labels.name }} is not active on {{ $labels.host }}";
        description = "Systemd unit {{ $labels.name }} has remained inactive or transitional on {{ $labels.host }}.";
      };
    }
  ]) systemdUnitDefinitions;
  systemdServiceRuleFile = pkgs.writeText "jorthaus-systemd-service-alerts.yml" (
    builtins.toJSON {
      groups = [
        {
          name = "systemd-service-health";
          rules = systemdAlertRules;
        }
      ];
    }
  );
in
{
  imports = [ ./s3.nix ];

  options.jorthaus.prometheus.systemdServices = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          unit = lib.mkOption {
            type = lib.types.str;
            description = "Expected-running systemd unit.";
          };
          sliver = lib.mkOption {
            type = lib.types.str;
            description = "Sliver or shared module that owns the unit.";
          };
          severity = lib.mkOption {
            type = lib.types.enum [ "warning" "critical" ];
            default = "critical";
            description = "Severity for failed or inactive unit alerts.";
          };
        };
      }
    );
    default = [ ];
    description = "Cluster-wide expected systemd units contributed by enabled slivers and shared node modules.";
  };

  options.jorthaus.prometheus.localSystemdServices = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Expected systemd units contributed by enabled slivers on this host.";
  };

  config = lib.mkMerge [
    {
      jorthaus.prometheus.systemdServices = prometheusSystemdServices;
      jorthaus.prometheus.localSystemdServices = localPrometheusSystemdServices;
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
        {
          assertion = lib.all (
            service: builtins.match "^[A-Za-z0-9_.@-]+\\.service$" service.unit != null
          ) systemdServices;
          message = "Monitored systemd units must be simple .service names.";
        }
        {
          assertion = lib.all (
            unit: lib.any (service: service.unit == unit) systemdServices
          ) localSystemdServices;
          message = "Every locally monitored systemd unit must have a cluster-wide alert definition.";
        }
        {
          assertion =
            builtins.length localSystemdServices == builtins.length (lib.unique localSystemdServices);
          message = "A systemd unit may only be declared once per host for Prometheus scraping.";
        }
        {
          assertion = systemdUnitDefinitionsConsistent;
          message = "A systemd unit must have the same severity and owner across declarations.";
        }
      ];
    }

    (lib.mkIf host.slivers.nodeExporter.enable {
      services.prometheus.exporters.node = {
        enable = true;
        listenAddress = host.ipam.ipv4.address;
        openFirewall = true;
        enabledCollectors = [ "systemd" ];
        extraFlags = [ "--collector.systemd.unit-include=${systemdUnitInclude}" ];
      };
    })

    (lib.mkIf host.slivers.postgres.enable {
      age.secrets.prometheus-postgres-exporter-password = {
        file = ../../../../secrets/postgres-exporter-password.age;
        owner = "postgres-exporter";
        group = "postgres-exporter";
        mode = "0400";
      };

      services.prometheus.exporters.postgres = {
        enable = true;
        listenAddress = host.ipam.ipv4.address;
        openFirewall = true;
        dataSourceName = "";
      };

      systemd.services."prometheus-postgres-exporter" = {
        environment = {
          DATA_SOURCE_URI = "${host.hostname}.node.jort.haus:5432/postgres?sslmode=verify-full&sslrootcert=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          DATA_SOURCE_USER = "prometheus_exporter";
          DATA_SOURCE_PASS_FILE = config.age.secrets.prometheus-postgres-exporter-password.path;
        };
      }
      //
        lib.optionalAttrs (postgresBootstrapHost != null && host.hostname == postgresBootstrapHost.hostname)
          {
            after = [ "jorthaus-postgres-ensure.service" ];
            requires = [ "jorthaus-postgres-ensure.service" ];
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

      age.secrets.prometheus-kubelet-token = {
        file = ../../../../secrets/prometheus-kubelet-token.age;
        owner = "root";
        group = "prometheus";
        mode = "0440";
      };

      age.secrets.prometheus-kubelet-ca = {
        file = ../../../../secrets/prometheus-kubelet-ca.age;
        owner = "root";
        group = "prometheus";
        mode = "0440";
      };

      age.secrets.prometheus-control-plane-token = {
        file = ../../../../secrets/prometheus-control-plane-token.age;
        owner = "root";
        group = "prometheus";
        mode = "0440";
      };

      age.secrets.prometheus-app-metrics-token = {
        file = ../../../../secrets/prometheus-app-metrics-token.age;
        owner = "root";
        group = "prometheus";
        mode = "0440";
      };

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
        checkConfig = "syntax-only";
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
            job_name = "postgres";
            static_configs = map (peer: {
              targets = [ (postgresTarget peer) ];
              labels.host = peer.hostname;
            }) postgresHosts;
            sample_limit = 5000;
          }
          {
            job_name = "prometheus";
            static_configs = map (peer: {
              targets = [ (prometheusTarget peer) ];
              labels.host = peer.hostname;
            }) prometheusHosts;
          }
          {
            job_name = "kube-state-metrics";
            static_configs = [
              {
                targets = [ kubeStateMetricsTarget ];
              }
            ];
          }
          {
            job_name = "coredns";
            kubernetes_sd_configs = [ (appMetricsDiscovery "kube-system") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "kube-dns";
              portName = "metrics";
              requireOptIn = false;
            };
            sample_limit = 1000;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = corednsMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "traefik";
            kubernetes_sd_configs = [ (appMetricsDiscovery "traefik") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "traefik-metrics";
              portName = "metrics";
            };
            sample_limit = 1000;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = traefikMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "cert-manager";
            kubernetes_sd_configs = [ (appMetricsDiscovery "cert-manager") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "cert-manager|cert-manager-cainjector|cert-manager-webhook";
              portName = "http-metrics|metrics";
            };
            sample_limit = 1500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = certManagerMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "authentik-server";
            kubernetes_sd_configs = [ (appMetricsDiscovery "authentik") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "authentik-server-metrics";
              portName = "metrics";
            };
            sample_limit = 2000;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = authentikServerMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "authentik-worker";
            kubernetes_sd_configs = [ (appMetricsDiscovery "authentik") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "authentik-worker-metrics";
              portName = "metrics";
            };
            sample_limit = 1000;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = authentikWorkerMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "seaweedfs-csi";
            kubernetes_sd_configs = [ (appMetricsDiscovery "kube-system") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "seaweedfs-csi-metrics";
              portName = "(provisioner|resizer|attacher)-metrics";
            };
            sample_limit = 1000;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = seaweedCsiMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "kured";
            kubernetes_sd_configs = [ (appMetricsDiscovery "kube-system") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "kured-metrics";
              portName = "metrics";
            };
            sample_limit = 1000;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = kuredMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "secrets-store-csi";
            kubernetes_sd_configs = [ (appMetricsDiscovery "kube-system") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "secrets-store-csi-driver-metrics";
              portName = "metrics";
            };
            sample_limit = 1000;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = secretsStoreMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "cilium-agent";
            kubernetes_sd_configs = [ (appMetricsDiscovery "kube-system") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "cilium-agent";
              portName = "metrics";
              requireOptIn = false;
            };
            sample_limit = 2500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = ciliumAgentMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "cilium-operator";
            kubernetes_sd_configs = [ (appMetricsDiscovery "kube-system") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "cilium-operator";
              portName = "metrics";
              requireOptIn = false;
            };
            sample_limit = 2500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = ciliumOperatorMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "cilium-envoy";
            kubernetes_sd_configs = [ (appMetricsDiscovery "kube-system") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "cilium-envoy";
              portName = "envoy-metrics";
              requireOptIn = false;
            };
            sample_limit = 2500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = ciliumEnvoyMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "kubernetes-control-plane";
            scheme = "https";
            bearer_token_file = controlPlaneTokenFile;
            tls_config.ca_file = kubeletCaFile;
            sample_limit = 2500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = controlPlaneMetricAllowlist;
                action = "keep";
              }
            ];
            static_configs = map (peer: {
              targets = [ "${peer.hostname}.node.jort.haus:6443" ];
              labels.host = peer.hostname;
            }) controlPlaneHosts;
          }
          {
            job_name = "kubelet";
            scheme = "https";
            bearer_token_file = kubeletTokenFile;
            tls_config.ca_file = kubeletCaFile;
            sample_limit = 2000;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = kubeletMetricAllowlist;
                action = "keep";
              }
            ];
            static_configs = map (peer: {
              targets = [ (kubeletTarget peer) ];
              labels.host = peer.hostname;
            }) kubeletHosts;
          }
          {
            job_name = "kubelet-cadvisor";
            scheme = "https";
            metrics_path = "/metrics/cadvisor";
            bearer_token_file = kubeletTokenFile;
            tls_config.ca_file = kubeletCaFile;
            sample_limit = 2500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = cadvisorMetricAllowlist;
                action = "keep";
              }
            ];
            static_configs = map (peer: {
              targets = [ (kubeletTarget peer) ];
              labels.host = peer.hostname;
            }) kubeletHosts;
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
            job_name = "thanos-query";
            kubernetes_sd_configs = [ (appMetricsDiscovery "thanos") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "thanos-query";
              portName = "http";
              requireOptIn = false;
            };
            sample_limit = 2500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = thanosMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "thanos-storegateway";
            kubernetes_sd_configs = [ (appMetricsDiscovery "thanos") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "thanos-storegateway";
              portName = "http";
              requireOptIn = false;
            };
            sample_limit = 2500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = thanosMetricAllowlist;
                action = "keep";
              }
            ];
          }
          {
            job_name = "thanos-compactor";
            kubernetes_sd_configs = [ (appMetricsDiscovery "thanos") ];
            relabel_configs = appMetricsRelabelConfigs {
              serviceName = "thanos-compactor";
              portName = "http";
              requireOptIn = false;
            };
            sample_limit = 2500;
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = thanosMetricAllowlist;
                action = "keep";
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
        ruleFiles = [ systemdServiceRuleFile ];
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
        preStart = ''
          test -r ${lib.escapeShellArg kubeletTokenFile}
          test -r ${lib.escapeShellArg controlPlaneTokenFile}
          test -r ${lib.escapeShellArg kubeletCaFile}
        '';
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
