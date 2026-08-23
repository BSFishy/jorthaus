# etcd membership runbook

This runbook covers the operational steps for changing etcd cluster membership.

The repository keeps a stable bootstrap configuration for etcd, while live
membership changes use `etcdctl` against the running cluster.

## Preconditions

Before changing membership, verify that:

- the existing etcd cluster is healthy
- the target node has the intended inventory configuration
- DNS and node-to-node reachability work for all participating hosts
- `/srv/etcd` persists on every existing member
- the node certificate for each member exists and covers the node hostname

A healthy member can inspect cluster state with commands like:

```bash
export ETCDCTL_ENDPOINTS="https://$(hostname).node.jort.haus:2379"
etcdctl endpoint status --cluster -w table
etcdctl member list -w table
```

The node certificate is issued by a public CA, so `etcdctl` can use the system
trust store for verification when it connects through the node hostname.

## Add a member

1. Enable `slivers.etcd.enable = true;` in the new host inventory.
2. Deploy the node so the etcd service, node certificate, firewall, and
   persistent directory exist on the machine.
3. Stop `etcd` on the new node and clear any stale member state before joining
   it to the live cluster:

   ```bash
   sudo systemctl stop etcd
   sudo find /srv/etcd -mindepth 1 -delete
   ```

4. From an existing healthy member, add the new member to the live cluster and
   save the returned bootstrap variables on the new node:

   ```bash
   export ETCDCTL_ENDPOINTS="https://$(hostname).node.jort.haus:2379"
   etcdctl member add <name> --peer-urls=https://<node>.node.jort.haus:2380 \
     | awk '/^ETCD_/ { print }' \
     | ssh matt@<node>.node.jort.haus 'sudo tee /srv/etcd/bootstrap.env >/dev/null'
   ```

5. Start or restart `etcd` on the new node.
6. Verify the member appears and starts replicating:

   ```bash
   etcdctl member list -w table
   etcdctl endpoint status --cluster -w table
   ```

Non-bootstrap nodes stay prepared but do not start a fresh cluster from an
empty `/srv/etcd`. The first successful join reads `/srv/etcd/bootstrap.env`,
then persisted member state takes over on later restarts.

## Remove a member

1. Choose a healthy remaining member.
2. Find the member ID to remove:

   ```bash
   export ETCDCTL_ENDPOINTS="https://$(hostname).node.jort.haus:2379"
   etcdctl member list -w table
   ```

3. Remove the member from the live cluster:

   ```bash
   etcdctl member remove <member-id>
   ```

4. Disable `slivers.etcd.enable` in that host inventory if the node should no
   longer run etcd.
5. Redeploy the host or decommission it.

## Replace a lost member

A node whose `/srv/etcd` data is gone does not resume safely from inventory
alone. Replace it explicitly.

1. Confirm the old member is truly lost.
2. Remove the old member from the cluster with `etcdctl member remove`.
3. Prepare the replacement node with `slivers.etcd.enable = true;` and deploy
   it.
4. Ensure the replacement starts with an empty `/srv/etcd`.
5. Add the replacement with `etcdctl member add` using its intended peer URL.
6. Start or restart `etcd` on the replacement node.
7. Verify the replacement reaches the healthy cluster state.

## Notes

- Inventory expresses which nodes are prepared to run etcd.
- Live etcd state expresses which members currently belong to the quorum.
- Membership changes remain explicit so cluster behavior stays predictable.
