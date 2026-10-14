# Thanos B2 block backup plan

**Status: Deployed and restore-tested (2026-10-13).** Thanos block backups run
from the SeaweedFS `thanos` bucket to a dedicated private Backblaze B2 bucket.

## Goal and boundaries

- Preserve the Thanos block data available from the source bucket, independently
  of SeaweedFS failure, using Thanos-native tooling.
- Keep the B2 bucket within the same 90-day raw, 5-minute, and 1-hour retention
  policy configured for the source Compactor.
- Back up closed blocks only. Prometheus WALs and currently open blocks are not
  in the source object bucket and are outside this plan.
- Treat this as a recoverable Thanos object store, not a byte-for-byte mirror or
  point-in-time copy. The B2-side Compactor may produce different block IDs and
  compaction boundaries.

## Data flow

1. A Kubernetes Job in the `thanos` namespace runs the Thanos `0.42.4` CLI,
   matching the deployed Thanos version.
2. `thanos tools bucket replicate` copies eligible blocks from SeaweedFS to B2
   with `--single-run` and `--ignore-marked-for-deletion`. It runs to completion
   before the next step starts.
3. A separate Thanos Compactor process targets **only** the B2 bucket. It runs
   one compaction pass (`--no-wait`) after replication, with downsampling
   enabled and raw, 5-minute, and 1-hour retention set to `90d`. It is the only
   Compactor allowed to operate on B2.
4. The Compactor's normal deletion-mark delay and cleanup lifecycle removes
   blocks superseded by compaction and blocks beyond retention. No separate
   `bucket retention` or `bucket cleanup` job is needed if this Compactor flow
   is used.

The B2 Compactor is important: replication does not copy source
`deletion-mark.json` files and never prunes destination objects. A B2-only
age-retention pass would eventually remove blocks older than 90 days, but would
leave recently superseded source blocks in the destination until they aged out.
An independent Compactor lets the backup bucket establish and clean up its own
compaction lineage. Keep replication and the B2 compaction pass serialized so
the backup has one controlled writer at a time.

`--ignore-marked-for-deletion` avoids importing source blocks already marked
for deletion. It does not remove copies already in B2; the B2 Compactor handles
those copies based on B2's own block state.

## Operational settings

- **Replication cadence:** every 6 hours, at `17 0,6,12,18 * * *` UTC. It
  bounds expected lag while allowing for asynchronous upload of closed
  two-hour blocks.
- **Retention:** `90d` for each of raw, 5-minute, and 1-hour resolution, matching
  `kubernetes/thanos/values/thanos.yaml`.
- **Deletion delay:** retain Thanos's normal deletion-mark safety delay (48h
  unless an explicit configuration decision changes it).
- **Overlap:** configure the scheduled Job to forbid overlapping runs. A
  failed or missed run should be visible; the next complete replication pass
  retries the copy without running concurrent destination maintenance.

The source Compactor remains the singleton Compactor for the SeaweedFS bucket.
The B2 Compactor is a distinct process with a distinct object-store
configuration and dedicated working storage. Never point both Compactors at
the same bucket.

## Storage and credential boundaries

- Provision a dedicated private B2 bucket using Terraform in
  `terraform/system`, with server-side encryption and `prevent_destroy`.
  Thanos's block retention owns block deletion. The B2 lifecycle rule is
  configured to delete hidden object versions after 7 days, not to age-expire
  active blocks. This lifecycle behavior has not been separately exercised
  against a disposable B2 object.
- Use a dedicated source SeaweedFS identity limited to listing and reading the
  `thanos` bucket. Do not reuse the existing Compactor credential, which has
  delete permission.
- Use a separate B2 application key scoped to the backup bucket. Replication
  and Compaction require listing, reading, writing, and deleting objects.
- Store runtime credentials in OpenBao and deliver them to Kubernetes through
  the existing CSI/OpenBao pattern. Never put credentials in Helm values,
  manifests, command arguments, or logs.
- A separate read-only B2 key is delivered only to the
  `thanos-block-restore-readonly` ServiceAccount through its dedicated OpenBao
  policy, Kubernetes auth role, and SecretProviderClass. Restore drills do not
  receive the replication key.

## Deployment and verification record

- `just plan-system` showed seven creates and no changes or destroys before
  provisioning the private B2 bucket, replication and read-only restore keys,
  OpenBao secrets/policies, and Kubernetes auth role.
- The SeaweedFS provisioner on Gaia-01 created the dedicated list/read-only
  `thanos-backup-source` grant; its reconciliation completed successfully.
- `just k8s-diff thanos` showed the backup resources before `just k8s-apply
  thanos` deployed them. The 10Gi B2 Compactor PVC completed its initial
  one-shot compaction/downsampling pass without errors.
- The manual initial backup Job
  `thanos-block-backup-test-20261013-1137` completed successfully. Replication
  copied 28 eligible blocks; the B2 Compactor synchronized all 28, completed
  compaction/downsampling and retention passes, and exited successfully.
- The isolated restore used the read-only B2 key and a fresh 50Gi scratch PVC.
  Thanos replication to a local filesystem bucket exited successfully;
  `bucket inspect` found 28 restored blocks and `bucket verify` completed with
  no reported issues. A scratch Thanos Store/Query returned `count(up) = 76` at
  `2026-10-13T15:00:00Z`. The scratch PVC, query pod, and temporary test
  configuration were removed afterward.
- The earlier in-memory Thanos `v0.42.4` test validated source deletion-mark
  handling, destination-side retention marking, and delayed cleanup. It remains
  separate from the completed B2 restore test.

## Monitoring and recovery expectations

- Existing Kubernetes Job-failure and CronJob-missed-schedule alerts cover
  failed or missed runs. Confirm both alerts include the `thanos` namespace.
- Record counts and timings for copied, compacted, marked, and deleted blocks;
  keep object-store credentials and credential-bearing configuration out of
  logs.
- During an outage, restore from B2 into fresh isolated storage first. Validate
  the resulting blocks and queries before considering any production recovery.
