# Kubernetes metrics

This runbook covers Kubernetes object-state and node metrics collected by the
host-native Prometheus pair. Prometheus on Gaia-01 and Gaia-02 keeps independent
TSDBs and continues host scraping and local rule evaluation during a Kubernetes
outage.

## Host systemd unit health

The node exporter on each Gaia host enables its systemd collector with an
include pattern assembled from local contributions by enabled sliver and node
modules. Host definitions select slivers and roles; each module contributes its
unit names only in the configuration where that sliver is enabled. This keeps
the collector limited to the 65 expected host/unit pairs across the cluster.
Cluster-wide alert definitions contain one entry per unit name, independent of
how many hosts run it, and retain severity and owning-sliver labels.

The alert expressions match unit state directly; node-exporter adds `host` to
each sample, and the per-host include pattern ensures only hosts that expect a
unit report it. `SystemdServiceFailed` catches failed units, while
`SystemdServiceNotActive` catches inactive and transitional states. If a unit
produces no systemd metric series at all, Prometheus cannot infer that the unit
should exist and will not alert for it. Alerts include `host`, `unit`,
`severity`, and `sliver` labels. Node-exporter
target availability is monitored separately. Alertmanager remains on the
blackhole receiver until paging is configured.

Verify collector success and the number of active expected units on both
Prometheus replicas:

```bash
for h in gaia-01 gaia-02; do
  curl -fsS --get "http://$h.node.jort.haus:9090/api/v1/query" \
    --data-urlencode 'query=node_scrape_collector_success{collector="systemd"}' |
    jq -r '.data.result[] | [.metric.host, .value[1]] | @tsv'
  curl -fsS --get "http://$h.node.jort.haus:9090/api/v1/query" \
    --data-urlencode 'query=count(node_systemd_unit_state{job="node",state="active"} == 1) by (host)' |
    jq -r '.data.result[] | [.metric.host, .value[1]] | @tsv'
done
```

Check that the generated alert group is loaded and has no pending or firing
systemd alerts. `just prometheus-rules-test` checks both the static alert file
and synthetic healthy, failed, and inactive states against the Nix-generated
systemd rules. The missing-unit case intentionally produces no alert because it
has no metric series:

```bash
just prometheus-rules-test

for h in gaia-01 gaia-02; do
  curl -fsS "http://$h.node.jort.haus:9090/api/v1/rules?type=alert" |
    jq -r '.data.groups[] | select(.name == "systemd-service-health") |
      [.name, (.rules | length)] | @tsv'
  curl -fsS --get "http://$h.node.jort.haus:9090/api/v1/query" \
    --data-urlencode 'query=ALERTS{alertname=~"SystemdService.*",alertstate=~"pending|firing"}' |
    jq -r '.data.result[] | [.metric.alertname, .metric.host, .metric.unit, .metric.alertstate] | @tsv'
done
```

## Kubernetes object state

`kube-state-metrics` runs in the `monitoring` namespace with two replicas. Its
ClusterIP service is pinned at `10.43.200.50:8080`; Gaia-01 and Gaia-02 scrape
that stable service address. The Prometheus hosts need no Kubernetes API
credential for this single service target. The target stays behind the cluster
service network and has no public Ingress or LoadBalancer address.

The chart grants its ServiceAccount cluster-scoped `list` and `watch`
permissions for the enabled resource collectors. The `configmaps` and `secrets`
collectors are disabled, and metric label and annotation allowlists remain
empty. The pod uses its projected ServiceAccount token to watch Kubernetes
objects; the host Prometheus does not receive that token. Prometheus alerts when
the KSM target stays down, a deployment has unavailable replicas, or a PVC
remains pending for 10 minutes. Object-health rules also cover StatefulSet and
DaemonSet availability, sustained unhealthy Pods and containers, failed Jobs,
missed CronJob schedules, and Kubernetes node readiness and pressure.

Partial workload availability is warning-level after 10 minutes. Zero available
replicas for core workloads in `kube-system`, `monitoring`, `thanos`,
`authentik`, or `postgres-backup` is critical after 5 minutes. Failed PostgreSQL
backup Jobs and missed PostgreSQL backup schedules are critical; other failed
Jobs and missed schedules are warnings. CronJobs are considered overdue 30
minutes after their next scheduled time. Job-owned Pods are handled by Job
alerts rather than duplicated Pod failure, waiting, or restart alerts. The
remaining Pod-level alerts use 5- or 10-minute hold times to filter brief
rollout and scheduling transitions.

## Health checks

Check the KSM replicas, service, and endpoints:

```bash
kubectl -n monitoring get pods -o wide
kubectl -n monitoring get svc kube-state-metrics -o wide
kubectl -n monitoring get endpointslice \
  -l kubernetes.io/service-name=kube-state-metrics -o wide
```

Check the ServiceAccount's effective permissions without reading object data:

```bash
kubectl auth can-i list deployments --all-namespaces \
  --as=system:serviceaccount:monitoring:kube-state-metrics
kubectl auth can-i list secrets --all-namespaces \
  --as=system:serviceaccount:monitoring:kube-state-metrics
```

The deployment and pod checks should be allowed; the secrets check should be
denied. Check the metrics endpoint from both Prometheus hosts without printing
the metrics payload:

```bash
for h in gaia-01 gaia-02; do
  ssh matt@$h.node.jort.haus \
    'curl -fsS --max-time 10 -o /dev/null http://10.43.200.50:8080/metrics'
done
```

The NixOS Prometheus configuration defines the `kube-state-metrics` scrape
job. Check both replicas' active targets and query KSM metrics through the
internal Thanos Query or the local Prometheus API. The public Thanos query
endpoint remains protected by Authentik. Verify that both local Prometheus
instances have evaluated the object-health group and have no unexpected active
alerts:

```bash
for h in gaia-01 gaia-02; do
  curl -fsS "http://$h.node.jort.haus:9090/api/v1/rules?type=alert" |
    jq -r '.data.groups[] | select(.name == "kubernetes-object-health") |
      [.name, (.rules | length), ([.rules[] | select(.health != "ok" or .lastError != null)] | length), .lastEvaluation] | @tsv'
  curl -fsS --get "http://$h.node.jort.haus:9090/api/v1/query" \
    --data-urlencode 'query=ALERTS{alertname=~"Kubernetes.*",alertstate=~"pending|firing"}' |
    jq -r '.data.result[] | [.metric.alertname, .metric.alertstate, .metric.namespace, .metric.pod] | @tsv'
done
```

## Kubelet and cAdvisor metrics

Both Prometheus hosts scrape `/metrics` and `/metrics/cadvisor` directly from
all five K3s nodes over HTTPS on TCP 10250, every 30 seconds. Targets use the
node IPs present in the kubelet serving-certificate SANs. TLS verification uses
the public K3s server CA delivered from an agenix-encrypted file; the
one-year TokenRequest token is also agenix-encrypted and readable only by the
Prometheus service account on Gaia-01 and Gaia-02.

The `monitoring/prometheus-kubelet` ServiceAccount can only get the
`nodes/metrics` subresource. Its token is not mounted in a Kubernetes pod.
Verify its permissions without reading Kubernetes objects:

```bash
kubectl auth can-i get nodes --subresource=metrics \
  --as=system:serviceaccount:monitoring:prometheus-kubelet
kubectl auth can-i get nodes --subresource=proxy \
  --as=system:serviceaccount:monitoring:prometheus-kubelet
kubectl auth can-i get secrets --all-namespaces \
  --as=system:serviceaccount:monitoring:prometheus-kubelet
```

Only `nodes/metrics` should be allowed. Each K3s node's firewall accepts TCP
10250 from the Prometheus host addresses; other sources remain blocked. Scrape
jobs use metric-name allowlists and per-target sample limits (2,000 for
`kubelet`, 2,500 for `kubelet-cadvisor`) to bound ingest. The cAdvisor allowlist
covers container CPU, memory, filesystem, network, OOM, resource-limit, and
machine-capacity metrics. The kubelet allowlist covers pod/container counts,
runtime operations, PLEG and pod-start latency, volume counts, certificate
expiry, and process health.

Check that both Prometheus replicas have ten healthy kubelet targets and that
post-relabel sample counts remain below the configured limits:

```bash
for h in gaia-01 gaia-02; do
  curl -fsS "http://${h}.node.jort.haus:9090/api/v1/targets?state=active" |
    jq -r '.data.activeTargets[] | select(.labels.job | startswith("kubelet")) |
      [.labels.job, .labels.host, .health, .lastError] | @tsv'
  for job in kubelet kubelet-cadvisor; do
    curl -fsS --get "http://${h}.node.jort.haus:9090/api/v1/query" \
      --data-urlencode "query=scrape_samples_post_metric_relabeling{job=\"$job\"}" |
      jq -r '.data.result[] | [.metric.host, .value[1]] | @tsv'
  done
done
```

The `scrape_samples_scraped` metric reports raw endpoint samples;
`scrape_samples_post_metric_relabeling` reports the samples retained by the
allowlist. A target should remain `up` and its post-relabel sample count should
stay below its configured limit.

Create or rotate the credentials through the project recipes; do not place the
decrypted token or CA in Git:

```bash
just create-prometheus-kubelet-ca
just create-prometheus-kubelet-token rotate
```

The CA recipe verifies that Gaia-01 and Gaia-02 share the same K3s server CA
before encrypting it. Token rotation issues a fresh one-year token and replaces
the encrypted file; the recipe prints its UTC expiry so the next rotation can
be scheduled before expiration. Deploy to Gaia-01, verify its targets, then
deploy to Gaia-02:

```bash
just nix-check
just switch gaia-01
# Verify all kubelet targets on Gaia-01 before continuing.
just switch gaia-02
```

Firewall changes that add or change scrape sources must be applied to K3s nodes
one at a time with `just switch <host>`. Verify each node returns to `Ready`
before moving to the next; apply the Prometheus target expansion only after the
corresponding node firewall rules are active.

## K3s control-plane metrics

Gaia-01 through Gaia-03 expose the process-wide K3s metrics registry at the
verified-TLS API endpoint `/metrics` on TCP 6443. It includes selected API
server, scheduler, controller-manager, Kine datastore, and process metrics. The
`kubernetes-control-plane` job scrapes each control-plane node directly using
the public K3s CA and an agenix-encrypted one-year TokenRequest token. Its
ServiceAccount is authorized only for the non-resource URL `GET /metrics`.
Metric-name filtering retains a bounded operational set; the per-target sample
limit is 2,500.

Check the ServiceAccount authorization without reading API data:

```bash
kubectl auth can-i get /metrics \
  --as=system:serviceaccount:monitoring:prometheus-control-plane
kubectl auth can-i get nodes \
  --as=system:serviceaccount:monitoring:prometheus-control-plane
```

The `/metrics` check should be allowed and the node-resource check denied. Both
Prometheus replicas should report three healthy control-plane targets. Check
retained sample counts and representative metrics:

```bash
for h in gaia-01 gaia-02; do
  curl -fsS "http://${h}.node.jort.haus:9090/api/v1/targets?state=active" |
    jq -r '.data.activeTargets[] | select(.labels.job == "kubernetes-control-plane") |
      [.labels.host, .health, .lastError] | @tsv'
  curl -fsS --get "http://${h}.node.jort.haus:9090/api/v1/query" \
    --data-urlencode 'query=scrape_samples_post_metric_relabeling{job="kubernetes-control-plane"}' |
    jq -r '.data.result[] | [.metric.host, .value[1]] | @tsv'
done
```

Create or rotate the token with the project recipe. The recipe validates its
ServiceAccount subject and one-year lifetime, encrypts it, and verifies the
ciphertext by decrypting it locally without printing the token:

```bash
just create-prometheus-control-plane-token
just create-prometheus-control-plane-token rotate
```

A Prometheus-only configuration rollout does not restart K3s. For any future
change to K3s runtime flags or listeners, follow
[`k3s-node-maintenance.md`](k3s-node-maintenance.md) and cordon/drain the
control-plane node before switching it.

## Workload and platform-component metrics

The host Prometheus pair uses the agenix-backed `prometheus-app-metrics` token
for namespace-scoped Endpoint discovery. Its ServiceAccount can only get, list,
and watch Endpoints, Pods, and Services in `authentik`, `cert-manager`,
`kube-system`, `thanos`, and `traefik`; it cannot read Secrets or Nodes. Scrape
jobs select explicit Service names and port names. Application Services use the
`prometheus.jort.haus/scrape: "true"` label; platform components without that
label are included only by exact Service and port matches. Prometheus does not
discover arbitrary Pod ports.

The enabled jobs cover Traefik, cert-manager, Authentik server and worker,
SeaweedFS CSI controller sidecars, Cilium agent/operator/Envoy, CoreDNS, Kured,
the Secrets Store CSI driver, and Thanos Query/Store Gateway/Compactor. Each job
has a metric-name allowlist and per-target sample limit (1,000 for CoreDNS,
Kured, Secrets Store CSI, Traefik, and SeaweedFS CSI; 1,500 for cert-manager;
1,000 for Authentik worker; 2,000 for Authentik server; 2,500 for Cilium and
Thanos). The SeaweedFS metrics Service is managed separately from the CSI
workload release; it does not restart CSI pods. Any future CSI workload rollout
still requires quiescing all writers first.

The current expected target counts are: 5 Traefik, 3 cert-manager, 2 Authentik
server, 2 Authentik worker, 3 SeaweedFS CSI sidecars, 5 Cilium agents, 3 Cilium
operators, 5 Cilium Envoy, 1 CoreDNS, 5 Kured, 5 Secrets Store CSI, 2 Thanos
Query, 2 Store Gateway, and 1 Compactor. Both Prometheus replicas reported all
72 active targets healthy after rollout. Check target health and retained sample
counts after configuration changes:

```bash
for h in gaia-01 gaia-02; do
  curl -fsS "http://${h}.node.jort.haus:9090/api/v1/targets?state=active" |
    jq -r '.data.activeTargets[] | select(.labels.job | test("^(traefik|cert-manager|authentik-server|authentik-worker|seaweedfs-csi|cilium-agent|cilium-operator|cilium-envoy|coredns|kured|secrets-store-csi|thanos-query|thanos-storegateway|thanos-compactor)$")) |
      [.labels.job, .labels.host, .health, .lastError] | @tsv'
  curl -fsS --get "http://${h}.node.jort.haus:9090/api/v1/query" \
    --data-urlencode 'query=scrape_samples_post_metric_relabeling' |
    jq -r '.data.result[] | select(.metric.job | test("^(traefik|cert-manager|authentik-server|authentik-worker|seaweedfs-csi|cilium-agent|cilium-operator|cilium-envoy|coredns|kured|secrets-store-csi|thanos-query|thanos-storegateway|thanos-compactor)$")) |
      [.metric.job, .metric.host, .value[1]] | @tsv'
done
```

VolSync exposes an authenticated HTTPS metrics endpoint, but its default
controller-runtime certificate is generated locally and has no stable trusted
CA. Keep it out of the scrape set until VolSync serves a stable certificate
that the host Prometheus can verify and the scraping identity is authorized for
`/metrics`; do not disable TLS verification as a workaround.

## Deployment

Plan and apply the KSM Helmfile release with the project runner, then deploy
host changes one node at a time:

```bash
just k8s-diff kube-state-metrics
just k8s-apply kube-state-metrics
just nix-check
just switch gaia-01
just switch gaia-02
```
