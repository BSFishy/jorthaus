---
name: victorialogs-operations
description: Query and validate the Jorthaus VictoriaLogs replicas directly, inspect Fluent Bit fan-out and persistent buffering, or investigate a logging-delivery outage. Use for bounded LogsQL queries, known-marker checks, replica consistency, and collector recovery.
---

# VictoriaLogs operations

Use this skill for the three independent VictoriaLogs replicas and host-native
Fluent Bit collectors in Jorthaus.

## Safety

- Read `docs/runbooks/victorialogs.md` before operating on the services.
- Use bounded queries. Supply a narrow marker or LogsQL predicate and `limit`;
  do not run an unbounded query against collected logs.
- Treat direct replica responses as backend evidence. Ask the user to confirm
  UI behavior at `https://logs.jort.haus` when that is the intended outcome.
- Do not delete `/var/lib/fluent-bit`, `/srv/storage/victorialogs`, or cursor or
  chunk files while a service is running. Preserve byte-for-byte copies and
  follow the stateful recovery procedure before any destructive work.
- Use `just switch <host>` for declarative service changes. Do not change
  collector configuration only on a node.

## Endpoints

The direct HTTP endpoints are:

- `http://10.1.10.1:9428`
- `http://10.1.10.2:9428`
- `http://10.1.10.3:9428`

Check health without emitting output:

```bash
for host in 10.1.10.1 10.1.10.2 10.1.10.3; do
  curl --fail --silent "http://$host:9428/ping" >/dev/null
  echo "$host healthy"
done
```

## Query cookbook

Read [the query cookbook](references/query-cookbook.md) before forming an
interactive query. It covers bounded `curl` requests, Kubernetes and journald
filters, counts and rates, safe `jq` processing, replica comparisons, and
redaction requirements.

A Kubernetes record has stream labels including `host`, `source`, namespace,
pod, container, and stdout/stderr stream. A journald record has stream labels
including `host`, `source`, unit, identifier, priority, and transport. Fields
not selected as stream labels remain in the JSON record.

## Produce an acceptance marker

Use `logger` for a journal-source test. Generate the marker locally; it is not
a credential and may be printed in command output.

```bash
marker="fluent-bit-check-$(date -u +%Y%m%dT%H%M%SZ)"
ssh matt@gaia-04.node.jort.haus \
  "sudo logger -p user.notice -t fluent-bit-check '$marker'"
```

Then run the known-record query above. For a Kubernetes-source test, create a
short-lived pod with an explicit marker, wait for it to complete, query all
replicas, and delete the pod after verification.

## Inspect Fluent Bit safely

```bash
for host in gaia-01 gaia-02 gaia-03 gaia-04 gaia-05; do
  echo "== $host =="
  ssh matt@$host.node.jort.haus \
    'systemctl is-active fluent-bit && \
     findmnt -no SOURCE,TARGET /var/lib/fluent-bit && \
     sudo du -sh /var/lib/fluent-bit && \
     sudo find /var/lib/fluent-bit/cursors -maxdepth 1 -type f -name "*.db" -printf "%f\n"'
done
```

For delivery failures, inspect bounded recent logs and destination health:

```bash
ssh matt@gaia-04.node.jort.haus \
  'sudo journalctl -u fluent-bit -n 100 --no-pager'
```

When a destination is down, retain the collector state and restore the
endpoint. Verify a marker generated during the outage appears on every replica
after recovery.
