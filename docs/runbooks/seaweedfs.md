# SeaweedFS runbook

This runbook covers routine operations for the SeaweedFS cluster on `gaia-01`,
`gaia-02`, and `gaia-03`.

## Preconditions

Before changing SeaweedFS state, verify that:

- `seaweedfs-master`, `seaweedfs-filer`, and `seaweedfs-volume` are active on
  the intended nodes
- OpenBao is healthy so filer credentials and JWT material can render
- the anycast endpoints respond
- the data disk mounted at `/srv/storage` is present on each dataplane node

Useful checks:

```bash
for h in gaia-01 gaia-02 gaia-03; do
  echo "== $h =="
  ssh matt@$h.node.jort.haus \
    'systemctl is-active seaweedfs-master seaweedfs-filer seaweedfs-volume vault-agent-seaweedfs vault-agent-seaweedfs-pki'
  echo
 done

curl -kI https://seaweed-master.service.jort.haus:9333
curl -kI https://seaweed-filer.service.jort.haus:8888
curl -kI https://s3.service.jort.haus:8443
```

## CSI FUSE mount maintenance and recovery

The `seaweedfs-csi-driver-mount` DaemonSet owns node-local FUSE processes for
SeaweedFS CSI volumes. Restarting its pod disconnects active FUSE mounts on
that node. Treat this as storage maintenance rather than a routine pod restart.

Before restarting a mount pod, identify every PVC consumer scheduled on the
node and quiesce its writers. For Minecraft, flush the world through RCON and
stop the Deployment before changing the mount service:

```bash
kubectl -n minecraft exec deploy/minecraft-server -c minecraft-server -- \
  rcon-cli save-all flush
kubectl -n minecraft scale deploy/minecraft-server --replicas=0
kubectl -n minecraft wait --for=delete pod -l app=minecraft-server --timeout=180s
```

A FUSE error such as `transport endpoint is not connected` cannot be repaired
for an application that still has open files. Stop the application before
recovering the mount. Inspect the affected PVC's consumers and attachment:

```bash
kubectl get volumeattachment
kubectl get pods -A -o wide
```

After all publish paths and writers are gone, allow CSI to unpublish and
unstage the volume. If unstage remains blocked by a disconnected staging mount,
inspect the node-local mount before unmounting only that confirmed stale FUSE
mount. Do not delete the staging directory. Delete a `VolumeAttachment` only
when no pod or process still uses the volume and normal CSI detach has failed.

Restart the workload through Kubernetes after CSI reattaches the volume. Verify
filesystem access, application health, and an application-level durable write
before accepting new traffic.

## Filer entries that reference missing chunks

A FUSE read can repeatedly re-resolve the same healthy volume-server locations
and still receive `404 Not Found` from every replica. This indicates that filer
metadata references a needle that no replica can serve; replication repair
cannot reconstruct that payload.

1. Freeze every workload writing the affected PVC and confirm its pod is gone.
2. Preserve byte-for-byte copies of the affected volume files on every replica
   before attempting recovery.
3. Run the read-only disk comparison under the SeaweedFS administrative lock:

   ```bash
   sudo bash -lc 'printf "lock\nvolume.check.disk -volumeId=<id> -slow -v\nunlock\n" \
     | weed shell -master=127.0.0.1:9333 -filer=127.0.0.1:8888'
   ```

4. If every replica agrees, do not run `volume.fix.replication`, `volume.fsck`
   with repair flags, purge, or deletion commands. Recover the affected
   application file from an application-level backup instead.

SeaweedFS filer updates and later vacuum can produce this state when stale
metadata references a chunk already queued for deletion. This is a plausible
failure mechanism for the 2026-09 Minecraft incident, but its exact triggering
update was not captured locally.

### Automatic vacuum safeguard

The masters run with `-garbageThreshold=1.1`. A garbage ratio cannot exceed
one, so this prevents automatic vacuum from physically reclaiming queued
chunks while the filer-update risk is under investigation. The safeguard
retains deleted data and therefore increases storage consumption.

Do not lower this threshold or run manual vacuum until a maintenance plan
includes capacity review, validated application backups, and confirmation that
the deployed SeaweedFS FUSE write paths have the required stale-update
protection.

## Inspect filer path configuration

The filer stores path-specific write policy in `/etc/seaweedfs/filer.conf`
inside SeaweedFS itself.

Inspect the current configuration from any controlplane node:

```bash
ssh matt@gaia-01.node.jort.haus
sudo bash -lc 'printf "fs.configure\n" | weed shell -master=127.0.0.1:9333 -filer=127.0.0.1:8888'
```

Expected defaults:

- `/buckets/` uses replication `020` with `volumeGrowthCount=3`
- `/buckets/media/` uses replication `000` with `volumeGrowthCount=1`

These rules affect new writes only.

## Bucket and S3 identity changes

The S3 gateway reads static identities from the OpenBao secret rendered to:

- `/run/seaweedfs-agent-filer/s3.json`

When that file changes, the path unit
`jorthaus-seaweedfs-s3-config-refresh.service` restarts `seaweedfs-filer` so
all filer and S3 nodes converge on the new identity set.

A bucket is created through the S3 API and maps to `/buckets/<bucket>` in the
filer.

## Replace a node

1. Keep the remaining cluster healthy before touching the lost node.
2. Prepare the replacement host with the same SeaweedFS sliver settings and a
   mounted data disk at `/srv/storage`.
3. If the old node still exists, stop SeaweedFS on it before reusing the node
   identity.
4. If the replacement should reuse the same hostname, clear stale SeaweedFS
   state before starting services:

   ```bash
   sudo systemctl stop seaweedfs-master seaweedfs-filer seaweedfs-volume
   sudo find /srv/seaweedfs/master -mindepth 1 -delete
   sudo find /srv/seaweedfs/filer -mindepth 1 -delete
   sudo find /srv/storage/seaweedfs/volume -mindepth 1 -delete
   ```

5. Deploy the host and verify the three SeaweedFS services start.
6. Confirm the replacement appears in the master topology and filer cluster.
7. Repair or rebalance volumes explicitly if the replacement starts empty.

## Repair replication after topology changes

SeaweedFS does not auto-repair missing replicas.

Inspect before applying changes:

```bash
ssh matt@gaia-01.node.jort.haus
sudo bash -lc 'printf "volume.fix.replication -n\n" | weed shell -master=127.0.0.1:9333'
```

Repair under-replicated volumes:

```bash
ssh matt@gaia-01.node.jort.haus
sudo bash -lc 'printf "lock\nvolume.fix.replication\nunlock\n" | weed shell -master=127.0.0.1:9333'
```

When the cluster is in the middle of a node replacement, a non-deleting pass is
safer:

```bash
ssh matt@gaia-01.node.jort.haus
sudo bash -lc 'printf "lock\nvolume.fix.replication -doDelete=false\nunlock\n" | weed shell -master=127.0.0.1:9333'
```

`volume.balance` remains an explicit operator action.

## Credential and certificate rotation

SeaweedFS runtime material is rendered on each node at:

- `/run/seaweedfs-agent-filer/postgres.env`
- `/run/seaweedfs-agent-filer/s3.json`
- `/run/seaweedfs-pki/jwt.env`
- `/run/seaweedfs-pki/{cert.pem,key.pem,ca.pem}`

Behavior:

- OpenBao agent refresh updates filer database credentials and S3 identities
- `jorthaus-seaweedfs-credential-refresh.service` restarts `seaweedfs-filer`
  after filer credential changes
- `jorthaus-seaweedfs-security-refresh.service` restarts SeaweedFS services
  after JWT changes
- `jorthaus-seaweedfs-pki-renew.timer` renews internal TLS materials

Useful checks:

```bash
systemctl status vault-agent-seaweedfs vault-agent-seaweedfs-pki
systemctl status jorthaus-seaweedfs-credential-refresh jorthaus-seaweedfs-security-refresh
systemctl status jorthaus-seaweedfs-pki-renew.timer
ls -l /run/seaweedfs-agent-filer /run/seaweedfs-pki
```

## Notes

- The anycast endpoints already front the live cluster directly.
- `weed shell` operations can run from any healthy controlplane node.
- Periodic repair and balancing are future day-2 automation work.
