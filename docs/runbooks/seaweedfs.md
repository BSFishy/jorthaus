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
