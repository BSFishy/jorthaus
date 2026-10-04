# K3s node maintenance

Use this procedure for a planned K3s service restart on one Gaia node. The
project runner cordons and drains the node before restarting K3s, then waits for
the service, Kubernetes node, and running pods on that node to recover before
restoring schedulability.

## Preconditions

- Confirm the Kubernetes API is healthy and all nodes are Ready:

  ```bash
  kubectl get nodes -o wide
  ```

- Confirm PostgreSQL and the other K3s control planes are healthy before
  restarting a control-plane node.
- Check for active backups, maintenance, or workloads that cannot tolerate an
  eviction. `kubectl drain` respects PodDisruptionBudgets and normal pod
  termination grace periods. Cordon and drain are the normal maintenance
  procedure; do not scale down all PVC-backed writers or manually move pods as
  a blanket precondition. Let controllers reschedule evicted pods, and apply
  workload-specific preparation only when its runbook requires it or a
  concrete drain blocker needs targeted handling.
- Use the declared project runner from the repository root. Do not directly
  restart `k3s` with SSH or `systemctl`.

## Restart one node

```bash
just restart-k8s gaia-01
```

Replace `gaia-01` with exactly one of `gaia-01` through `gaia-05`; repeat only
after the previous node has recovered. The script verifies the Kubernetes API
endpoint, node readiness and schedulability, and remote K3s service before it
makes changes. It then:

1. Cordons the node.
2. Drains evictable workloads, waiting up to the configured drain timeout.
   DaemonSet pods remain, and the command does not force deletion or discard
   `emptyDir` data. A blocked drain aborts before K3s is restarted.
3. Restarts the K3s systemd service over SSH.
4. Waits for the remote service to become active, the Kubernetes node to become
   Ready, and running pods on the node to become Ready.
5. Uncordons the node and verifies it is schedulable again.

If a drain fails before the restart, the script attempts to uncordon the node
it cordoned. If the restart begins but the health checks do not complete, it
deliberately leaves the node cordoned. Investigate the K3s service, node
conditions, CSI pods, and cluster logs before manually uncordoning it.

Timeouts can be adjusted for a single invocation with `K3S_DRAIN_TIMEOUT`,
`K3S_NODE_TIMEOUT`, `K3S_POD_TIMEOUT`, and `K3S_RESTART_TIMEOUT` (duration
strings such as `10m`).
A timeout does not force-delete workloads or uncordon a node whose post-restart
health checks failed.

## NixOS switches that restart K3s

`just switch <host>` does not currently cordon or drain the node. For a switch
that will restart K3s, perform the maintenance sequence around the switch
manually: cordon and drain first, run `just switch <host>`, wait for the K3s
service, node, and running pods to recover, then uncordon. Do not run
`just restart-k8s` before such a switch: that recipe uncordons after its
restart, before the switch occurs.

## Workload and storage verification

Normal pod termination gives applications their configured grace period to
flush and close data before kubelet removes them. Minecraft has previously
saved correctly through graceful termination; after maintenance, verify the
server is Ready and inspect the affected world area before considering the
operation complete. Do not force-delete stateful pods to make a drain succeed.
A SeaweedFS CSI pod on the node does not by itself require quiescing all
CSI-backed writers; use cordon and drain, and follow an application-specific
runbook only when the workload or maintenance task calls for extra preparation.

A successful node restart does not prove every application recovered. Review
workload readiness and relevant application logs, especially for StatefulSets
and SeaweedFS-backed volumes. If a workload reports a disconnected FUSE mount,
follow [the SeaweedFS FUSE recovery runbook](seaweedfs.md) rather than
restarting mount services while writers remain active.
