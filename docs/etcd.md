# etcd

This repository uses etcd as a standalone coordination sliver.

The etcd sliver provides a persistent quorum-backed key-value store for
clustered services that need a distributed control plane.

## Inventory

Nodes participate in the etcd cluster when their host inventory enables the
sliver:

```nix
slivers.etcd.enable = true;
```

The inventory flag means the node is configured to run etcd. Live cluster
membership remains an explicit operator action after the first bootstrap.

## Bootstrap semantics

The sliver keeps a stable bootstrap configuration in Nix:

- `services.etcd.initialCluster`
- `services.etcd.initialClusterState = "new"`
- `services.etcd.initialClusterToken = "jorthaus-etcd"`

These settings define the shape of the first cluster bootstrap.

Persisted etcd state in `/srv/etcd` becomes authoritative after bootstrap.
Once the cluster exists, member add and remove operations use `etcdctl` against
that live state. Inventory changes alone do not mutate live etcd membership.
The first cluster bootstrap runs on the lexically first enabled etcd node. A
later member join writes `etcdctl member add` output to `/srv/etcd/bootstrap.env`
on the new node, and the first successful start consumes that file before
persisted member state takes over on later restarts.

This keeps the repository configuration stable while making membership changes
an explicit operational workflow.

## Persistence

Cluster recovery depends on that directory surviving reboots and rebuilds.
A node with an intact data directory resumes its existing member state.
A node with an empty data directory follows the explicit membership runbook in
`docs/runbooks/etcd-membership.md`.
