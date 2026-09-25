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

## S3 registry provisioning

When at least one bucket or grant is declared, the deterministic leader
(Gaia-01) runs `jorthaus-seaweedfs-s3-provisioner` as `seaweedfs-filer`. The
oneshot uses SeaweedFS's cluster-wide administrative lock and authenticates to
OpenBao with the `seaweedfs-s3-provisioner` AppRole. Its policy can create,
read, and update only the registry binding paths. It does not delete SeaweedFS
or OpenBao resources.

Each grant's KVv2 data contains exactly these fields: `access_key_id`, `bucket`,
`endpoint`, `region`, and `secret_access_key`. Grant identity and permissions
are defined by the Nix registry and SeaweedFS IAM policy, not duplicated in the
KV record. No S3 grants are currently declared. The former pilot IAM identity,
policy, and KVv2 binding have been removed; its pre-existing bucket
`jorthaus-s3-provisioner-pilot` remains untouched.

Provisioning progress and failures are available in the systemd journal:

```bash
systemctl status vault-agent-seaweedfs-s3-provisioner jorthaus-seaweedfs-s3-provisioner
journalctl -u jorthaus-seaweedfs-s3-provisioner -u vault-agent-seaweedfs-s3-provisioner
```

### Retry and inspect

After correcting a failure, start the oneshot on the current provisioner leader:

```bash
sudo systemctl start jorthaus-seaweedfs-s3-provisioner.service
sudo systemctl show jorthaus-seaweedfs-s3-provisioner.service -p ActiveState -p SubState -p Result -p ExecMainStatus
sudo journalctl -u jorthaus-seaweedfs-s3-provisioner.service -n 50 --no-pager
```

A successful oneshot normally returns to `inactive/dead`; `Result=success` and
`ExecMainStatus=0` indicate completion. Inspect the journal for
`reconciliation succeeded`. Do not retry while an invocation is running or the
cluster administrative lock is held by another operation.

Inspect only the current KV field names and non-secret metadata. A bare
`bao kv get` prints both credentials:

```bash
GRANT_ID=your-grant-id
bao kv get -format=json -mount=seaweedfs "s3/bindings/$GRANT_ID" | jq '{version:.data.metadata.version, keys:(.data.data|keys), bucket:.data.data.bucket, endpoint:.data.data.endpoint, region:.data.data.region}'
```

The current contract yields exactly
`["access_key_id","bucket","endpoint","region","secret_access_key"]`.
KVv2 updates preserve prior versions; destroy an obsolete version only after
verifying that its credentials are present in the current version and that no
consumer depends on it.

If reconciliation fails after writing a new binding but before creating its
IAM identity, fix the reported cause and retry the oneshot; it reuses the
canonical stored key. If an identity exists without a binding, the service
fails closed. Do not delete the identity or generate a replacement key to force
progress; investigate the mismatch and reconcile it with an approved recovery
plan. A policy mismatch can be retried after correcting the declaration or
SeaweedFS issue; normal reconciliation updates the stable policy without
rotating the key.

The AppRole bootstrap files are encrypted for the selected host:

- `secrets/seaweedfs-s3-provisioner-approle-role-id.age`
- `secrets/seaweedfs-s3-provisioner-approle-secret-id.age`

Create or rotate them only after the host is an agenix recipient. Pipe the
values directly into agenix; do not display or save plaintext copies:

```bash
bao read -field=role_id auth/approle/role/seaweedfs-s3-provisioner/role-id \
  | agenix -e secrets/seaweedfs-s3-provisioner-approle-role-id.age -i "$HOME/.ssh/id_ed25519"

bao write -f -field=secret_id auth/approle/role/seaweedfs-s3-provisioner/secret-id \
  | agenix -e secrets/seaweedfs-s3-provisioner-approle-secret-id.age -i "$HOME/.ssh/id_ed25519"
```

Creating a SecretID issues an additional valid bootstrap credential; revoke the
previous SecretID after the replacement agent has authenticated successfully.
Never print the agent token at `/run/seaweedfs-agent-s3-provisioner/openbao.token`.

### Explicit grant cleanup

Registry removal is not cleanup. Before removing a grant, stop its consumers,
confirm no consumer needs the credential, and verify the bucket contains no
objects that must be retained. Remove the grant declaration from every
control-plane evaluation and deploy that desired state first. Then inspect the
IAM user and policy names; stop if their state differs from the intended grant.

Open an authenticated SeaweedFS shell on a healthy control-plane node, then
run the commands individually under the cluster lock. Replace the grant ID and
verify the displayed user/policy names before deleting anything:

```bash
sudo -u seaweedfs-filer /run/current-system/sw/bin/bash -c '
  set -euo pipefail
  set -a
  . /run/seaweedfs-pki/jwt.env
  set +a
  export HOME=/run/seaweedfs-filer
  exec /run/current-system/sw/bin/weed shell -master=gaia-01.node.jort.haus:9333,gaia-02.node.jort.haus:9333,gaia-03.node.jort.haus:9333 -filer=127.0.0.1:8888
'
```

At the `weed shell` prompt, replace `your-grant-id` and run one command at a
time, checking each response before continuing:

```text
lock
s3.policy.detach -policy jorthaus-s3-your-grant-id -user your-grant-id
s3.user.delete -name your-grant-id
s3.policy -delete -name jorthaus-s3-your-grant-id
unlock
exit
```

Then, using a human-admin OpenBao token, permanently remove all KVv2 versions
after consumers are shut down and the credential is decommissioned:

```bash
GRANT_ID=your-grant-id
bao kv metadata delete -mount=seaweedfs "s3/bindings/$GRANT_ID"
```

This deletion is irreversible; the provisioner AppRole cannot perform it. Do
not delete a bucket as part of grant cleanup. SeaweedFS bucket deletion can
remove stored object data. Any bucket deletion requires a separate data review
and explicit approval.

### Grant credential rotation and recovery

The provisioner is additive and never rotates an existing grant key. Do not
edit a binding's credential fields manually or expect a normal retry to rotate
them. Rotation is not yet an approved production procedure: host and Kubernetes
consumers do not exist, version-pinned reads are untested, and a secret-safe
key-generation and publication workflow has not been validated. On the pinned
SeaweedFS release, `s3.accesskey.create` prints generated access and secret
keys; do not invoke it interactively or allow its output into logs.

The intended sequence for a future reviewed rotation is to add a second key to
the same IAM identity, publish a KVv2 version containing that exact key pair,
refresh consumers, and verify the new key while the old one remains active.
Only revoke the old key after consumer refresh and the rollback window have
been verified.

- Before revocation, if the new key or consumer refresh fails, keep both keys
  active and return consumers to the last known-good credential bundle. If a
  consumer reads only the latest version, publish the known-good bundle as a
  new KVv2 version rather than deleting or rewriting history.
- After revocation, the old key cannot be reactivated. Recovery requires a new
  key pair, a new binding version, and another consumer rollout using a
  reviewed secret-safe workflow.
- Preserve prior KVv2 versions until rollback is no longer required. Validate
  the actual provider's version-selection behavior before relying on pinned
  reads or this rollback procedure.

## Notes

- The anycast endpoints already front the live cluster directly.
- `weed shell` operations can run from any healthy controlplane node.
- Periodic repair and balancing are future day-2 automation work.
