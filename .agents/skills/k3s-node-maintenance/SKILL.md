---
name: k3s-node-maintenance
description: >
  Safely cordon, drain, restart, and recover a Jorthaus K3s node. Use before
  planned K3s service restarts or switches that may restart K3s.
---

# K3s node maintenance

Before any planned K3s service restart, read and follow
`../../../docs/runbooks/k3s-node-maintenance.md` relative to this skill. The runbook
is the source of truth for preconditions, timeouts, failure handling, and
post-restart checks; do not duplicate its operational sequence here.

For a service-only restart, use `just restart-k8s <gaia-node>` and never bypass
the cordon/drain sequence with a direct `systemctl restart k3s`. Restart only
one node at a time and confirm it recovered before proceeding.

Cordon and drain are the normal maintenance procedure. Do not require a
cluster-wide writer quiesce or manually move PVC-backed pods as a blanket
precondition. Let Kubernetes gracefully evict pods and their controllers
reschedule replacements. Apply workload-specific preparation only when that
workload's runbook requires it or a concrete drain blocker needs targeted
handling; a SeaweedFS CSI pod on the node does not by itself require stopping
all CSI-backed writers.

`just switch <host>` does not yet perform maintenance orchestration. When a
switch is expected to restart K3s, cordon and drain before the switch and
uncordon only after the service, node, and running pods have recovered. Do not
use `just restart-k8s` as a wrapper for a switch; it uncordons after its own
restart.

Do not force-delete stateful workloads to clear a blocked drain. If the
maintenance script leaves a node cordoned after a restart health-check failure,
inspect the node and CSI/storage health before manually restoring
schedulability.
