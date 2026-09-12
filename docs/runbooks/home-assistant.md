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
