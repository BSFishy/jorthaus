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
