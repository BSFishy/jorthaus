# Thanos runbook

This runbook covers the host-native Prometheus Sidecars and the Kubernetes
Thanos Query, Store Gateway, and Compactor.

## Data path and retention

- Gaia-01 and Gaia-02 keep independent Prometheus TSDBs with their existing
  `30d` time and `15GB` size retention limits.
- Prometheus emits fixed two-hour blocks (`min-block-duration=max-block-duration=2h`)
  so the Sidecar can ship blocks without Prometheus merging them first. The
  Sidecar uploads each closed block to the `thanos` SeaweedFS bucket; the WAL
  and currently open block are not yet in object storage.
- The Compactor is a single replica with persistent working storage. It
  compacts/downsamples blocks and retains raw, 5-minute, and 1-hour data for
  90 days. The two Store Gateway replicas serve the bucket to Query.
- Thanos Query is a ClusterIP service. Its availability depends on Kubernetes;
  this does not affect Prometheus scraping, local TSDB writes, or local alert
  evaluation.

The Thanos grant is bucket-scoped and includes delete permission for Compactor
retention. Its credentials are provisioned through the SeaweedFS S3 registry
and stored in OpenBao at `seaweedfs/data/s3/bindings/thanos`. Host Sidecars
read the binding through OpenBao Agent. Kubernetes Store Gateway and Compactor
read it through the `thanos-objstore` SecretProviderClass and the
`thanos-objstore` Kubernetes auth role. Do not copy these credentials into
manifests or command output.

## Health and upload checks

Check host services and Sidecar readiness without displaying credentials:

```bash
for h in gaia-01 gaia-02; do
  ssh matt@$h.node.jort.haus \
    'systemctl is-active prometheus thanos-sidecar vault-agent-thanos-sidecar; curl -fsS http://127.0.0.1:10902/-/ready'
done

ssh matt@gaia-01.node.jort.haus \
  'curl -fsS http://127.0.0.1:10902/metrics | grep -E "thanos_shipper_(uploads|upload_failures)_total"'
```

`thanos_shipper_uploads_total` counts completed Sidecar block uploads, and
`thanos_shipper_upload_failures_total` should remain zero. Check each replica
independently. A closed block uploads asynchronously after it becomes
available; a scrape interval does not determine S3 upload frequency.

Check the Kubernetes components, synced credential object metadata, and
Compactor/Store Gateway readiness:

```bash
kubectl -n thanos get pods -o wide
kubectl -n thanos get secret thanos-objstore-credentials
kubectl -n thanos logs statefulset/thanos-compactor --tail=50
```

The Secret command prints only metadata. Never use `kubectl get secret -o yaml`
for the credential Secret. Store Gateway's `thanos_bucket_store_blocks_loaded`
metric reports loaded object-store blocks. Thanos Query's
`/api/v1/stores` endpoint reports Sidecar and Store Gateway health and time
ranges; query it through the internal ClusterIP or a temporary local
port-forward.

Use the project runner to inspect planned chart changes and apply the Thanos
releases:

```bash
just k8s-diff thanos
just k8s-apply thanos
```

## Provisioning and recovery safeguards

The bucket and grant are declared unconditionally in
`nix/modules/sliver/prometheus/s3.nix`, alongside the Prometheus sliver. The
leader-only SeaweedFS provisioner creates the bucket, scoped IAM
policy/identity, and OpenBao binding.
Its reconciliation is additive: removing a registry declaration does not
remove a bucket, IAM identity, policy, or OpenBao binding. Do not delete the
bucket as a routine cleanup or rotate its access key by reapplying Nix.

The Compactor must remain a singleton writer for this bucket. Preserve its
working PVC during ordinary upgrades. The SeaweedFS bucket is the durable
long-horizon copy; a Sidecar outage or object-store outage can delay uploads,
while destructive loss of a Prometheus host can lose its WAL, open block, and
other blocks not yet uploaded. Keep local Prometheus retention unchanged until
upload/recovery behavior and the required recovery point have been tested.
