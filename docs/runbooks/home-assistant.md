---
description: Home Assistant configuration backup and restore runbook
---

# Home Assistant configuration recovery

Home Assistant stores its configuration, HACS content, integrations, and local
credentials in the `home-assistant-config` PVC. Treat this PVC as stateful data.
Use an explicit PVC copy before upgrades, manual configuration migrations, or
other high-risk work.

## Preserve the current configuration

Stop the writer and wait for the pod to exit:

```bash
kubectl -n home-assistant scale deployment/home-assistant --replicas=0
kubectl -n home-assistant wait --for=delete pod -l app.kubernetes.io/name=home-assistant --timeout=180s
```

Create a timestamped `ReadWriteOnce` PVC using `seaweedfs-storage`. Mount the
production claim read-only and the preservation claim read-write in a helper
pod. Copy with `tar`, then compare a manifest of file paths, sizes, and SHA256
checksums from both mounts before deleting the helper pod. Keep the preservation
claim until Home Assistant is healthy after the operation.

## Restore safely

Keep Home Assistant scaled to zero. Preserve the current production PVC first,
then restore into a new scratch PVC and inspect its file manifest. When the
restored data is selected, mount the production and restored claims in a helper
pod, replace the production contents, and repeat the manifest comparison.

Restart and verify the workload:

```bash
kubectl -n home-assistant scale deployment/home-assistant --replicas=1
kubectl -n home-assistant rollout status deployment/home-assistant --timeout=300s
kubectl -n home-assistant get pod -l app.kubernetes.io/name=home-assistant
```

Confirm the Home Assistant UI opens and local recovery authentication works.

## Move the Zigbee coordinator

The generic device plugin advertises the Sonoff Zigbee coordinator as the
extended resource `jort.haus/zigbee-coordinator` on the node where its stable
`/dev/serial/by-id` path exists. Home Assistant requests that resource, so the
scheduler places it on the node currently hosting the coordinator. The device
is available to Home Assistant as `/dev/ttyUSB0`.

After moving the coordinator, wait for the destination node to report one
allocatable device, then recreate Home Assistant so the scheduler can place it
on that node:

```bash
kubectl get node <destination-node> \
  -o jsonpath='{.status.allocatable.jort\.haus/zigbee-coordinator}{"\n"}'
kubectl -n home-assistant delete pod -l app.kubernetes.io/name=home-assistant
kubectl -n home-assistant rollout status deployment/home-assistant --timeout=300s
kubectl -n home-assistant get pod -l app.kubernetes.io/name=home-assistant -o wide
```

Verify that `/dev/ttyUSB0` is a character device in the restarted container and
confirm the coordinator reconnects in the Home Assistant UI.

## AppDaemon

AppDaemon connects to the in-cluster Home Assistant service with a long-lived
token supplied from OpenBao. Create that token in the Home Assistant user
profile, then write it without displaying it in the terminal:

```bash
just appdaemon-token
```

The AppDaemon admin UI is available at `https://appdaemon.jort.haus` and is
restricted to `jorthaus-admins` through Authentik. The repository's
`appdaemon-apps/` directory is the source of truth for `/conf/apps` on the
`appdaemon-apps` PVC. Add Python apps and `apps.yaml` configuration there, then
synchronize the complete directory with:

```bash
just appdaemon-deploy
```

The sync writes Python source first and atomically replaces `apps.yaml`, so
AppDaemon only reads complete app configuration. AppDaemon detects the resulting
changes and reloads the affected apps.
