# VictoriaLogs runbook

VictoriaLogs runs as three independent standalone replicas on `gaia-01`,
`gaia-02`, and `gaia-03`. Each instance listens on its node address at TCP port
`9428` and stores data on its local XFS project quota.

## Topology and guarantees

| Host | HTTP endpoint | Data path |
| --- | --- | --- |
| `gaia-01` | `http://10.1.10.1:9428` | `/srv/storage/victorialogs` |
| `gaia-02` | `http://10.1.10.2:9428` | `/srv/storage/victorialogs` |
| `gaia-03` | `http://10.1.10.3:9428` | `/srv/storage/victorialogs` |

The native NixOS service uses `/var/lib/victorialogs`; this is a bind mount of
the quota-bound data path above. Each project has a 100 GiB hard XFS quota.
VictoriaLogs retains entries for 31 days and begins removing old partitions when
its data directory exceeds 90 GiB.

The replicas have separate local storage. A record is present on every replica
only when its producer delivers that record to every endpoint. No automated
backup or cross-replica synchronization exists. Fluent Bit fan-out is the
planned producer for complete replicated collection and must pass its own
outage tests before it is relied upon.

## Health and storage checks

```bash
for h in gaia-01 gaia-02 gaia-03; do
  echo "== $h =="
  ssh matt@$h.node.jort.haus \
    'systemctl is-active victorialogs var-lib-victorialogs.mount xfs_quota-victorialogs && \
     findmnt -no SOURCE,TARGET /var/lib/victorialogs && \
     curl --fail --silent http://$(hostname -I | awk "{print \$1}"):9428/ping >/dev/null && \
     sudo xfs_quota -x -c "report -p -N" /srv/storage | grep victorialogs'
done
```

The service exposes Prometheus-format metrics at `/metrics`. Inspect its active
arguments, including retention settings, with:

```bash
ssh matt@gaia-01.node.jort.haus \
  'systemctl show victorialogs -p ExecStart --value'
```

## Direct ingestion and query

Use an explicit timestamp field and the JSON-stream content type for JSON-line
ingestion. A timestamp of `"0"` uses the server time.

```bash
endpoint=http://10.1.10.1:9428
marker=manual-test-$(date -u +%Y%m%dT%H%M%SZ)

printf '{"timestamp":"0","message":"VictoriaLogs manual test","test_marker":"%s"}\n' "$marker" \
  | curl --fail --silent -X POST \
      -H 'Content-Type: application/stream+json' \
      --data-binary @- \
      "$endpoint/insert/jsonline?_time_field=timestamp&_msg_field=message"

curl --fail --silent "$endpoint/select/logsql/query" \
  -d 'query=test_marker:*' \
  | grep -F "$marker"
```

`/select/logsql/query` returns JSON lines. Bound broad queries with `limit` or
a LogsQL time filter before using them interactively against collected logs.

## Fluent Bit collection

Fluent Bit runs natively on `gaia-01` through `gaia-05`. It reads journald and
K3s CRI files below `/var/log/pods` without Kubernetes API access, then sends
each record to every VictoriaLogs replica. Cursor databases and filesystem
chunks persist at `/var/lib/fluent-bit`.

Kubernetes records use these stream fields: `host`, `source`,
`kubernetes_namespace`, `kubernetes_pod`, `kubernetes_container`, and
`stream`. Journald records use `host`, `source`, `journal_unit`,
`journal_identifier`, `journal_priority`, and `journal_transport`. These fields
are available as stream-label filters in the VictoriaLogs UI for newly ingested
records. The full native journald fields remain on the record.

The collector caps each input's memory buffer at 64 MiB, loaded filesystem
backlog at 128 MiB, and the service at 512 MiB. Each HTTP output has a 10 GiB
filesystem-buffer limit. The service logs warnings and errors so that routine
successful delivery does not grow the journal.

Verify the collector and its persistent state on every host:

```bash
for h in gaia-01 gaia-02 gaia-03 gaia-04 gaia-05; do
  echo "== $h =="
  ssh matt@$h.node.jort.haus \
    'systemctl is-active fluent-bit && \
     findmnt -no SOURCE,TARGET /var/lib/fluent-bit && \
     sudo find /var/lib/fluent-bit/cursors -maxdepth 1 -type f -name "*.db" -printf "%f\\n" && \
     sudo du -sh /var/lib/fluent-bit'
done
```

To verify fan-out, write one controlled journal marker on a selected host and
require it from all three direct query endpoints:

```bash
marker=fluent-bit-check-$(date -u +%Y%m%dT%H%M%SZ)
ssh matt@gaia-04.node.jort.haus \
  "sudo logger -p user.notice -t fluent-bit-check '$marker'"

for endpoint in http://10.1.10.1:9428 http://10.1.10.2:9428 http://10.1.10.3:9428; do
  curl --fail --silent "$endpoint/select/logsql/query" \
    --data-urlencode "query=$marker" \
    --data-urlencode 'limit=1' | grep -F "$marker"
done
```

When one destination is unavailable, Fluent Bit retains its pending output in
its filesystem buffer and continues delivering to healthy destinations. Restore
the destination, then query for a marker created during the outage on each
replica before considering the outage recovered. Do not delete cursors or
chunk files to clear an outage; inspect available space, the output warnings,
and destination health first.

## Service recovery

Do not delete, reinitialize, or copy the data directory while VictoriaLogs is
running. Its data is local to the host; stopping one replica does not stop the
other two.

For a failed service, first verify the quota, bind mount, and service logs:

```bash
ssh matt@gaia-01.node.jort.haus
systemctl status victorialogs var-lib-victorialogs.mount xfs_quota-victorialogs
findmnt /var/lib/victorialogs
sudo xfs_quota -x -c 'report -p -N' /srv/storage
journalctl -u victorialogs -b --no-pager
```

After mount and quota dependencies are active, restart only the affected
replica:

```bash
sudo systemctl restart victorialogs
systemctl is-active victorialogs
curl --fail --silent http://10.1.10.1:9428/ping >/dev/null
```

The service stops with `SIGINT`, which lets VictoriaLogs close its local
storage cleanly. A host reboot must return the bind mount, quota unit, service,
and a known local test record before the replica is accepted as recovered.

If the local data directory requires restoration, stop the service first,
preserve byte-for-byte copies of the directory, and use a tested restore plan.
There is no configured backup source in this phase, so do not claim a replica
can be reconstructed from the others.
