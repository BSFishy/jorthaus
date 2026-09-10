---
description: Minecraft restore and region recovery runbook
---

# Minecraft restore

Treat Minecraft world recovery as a stateful-data incident. Stop writers first,
preserve the current data, restore into scratch storage, and verify the world
structure before touching production.

## Stop writers

```bash
kubectl -n minecraft scale deploy/minecraft-server --replicas=0
kubectl -n minecraft wait --for=delete pod -l app=minecraft-server --timeout=180s
```

Confirm only helper/debug pods are mounted to the data PVC before modifying it.

## Restore restic into a scratch PVC

Create a scratch PVC with the same storage class:

```bash
kubectl -n minecraft apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minecraft-restic-restore-test
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: seaweedfs-storage
  resources:
    requests:
      storage: 20Gi
EOF
```

Run restic from `itzg/mc-backup` using the synced backup Secret:

```bash
kubectl -n minecraft apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: minecraft-restic-restore-test
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: itzg/mc-backup:latest
      command: ["sh", "-c", "sleep 3600"]
      envFrom:
        - secretRef:
            name: minecraft-backup-restic
      env:
        - name: RESTIC_CACHE_DIR
          value: /tmp/restic-cache
      volumeMounts:
        - name: restore
          mountPath: /restore
  volumes:
    - name: restore
      persistentVolumeClaim:
        claimName: minecraft-restic-restore-test
EOF

kubectl -n minecraft wait --for=condition=Ready pod/minecraft-restic-restore-test --timeout=180s
kubectl -n minecraft exec minecraft-restic-restore-test -- restic snapshots --host vanilla
kubectl -n minecraft exec minecraft-restic-restore-test -- restic restore latest --target /restore
kubectl -n minecraft exec minecraft-restic-restore-test -- restic check --read-data-subset=1/20
```

Restic restores the `/data` path under the target directory, so world files land
under `/restore/data`.

## Validate Minecraft region files

Minecraft region files (`*.mca`) contain a header pointing to chunk records.
Each chunk record starts with a length, compression byte, and compressed NBT
payload. A region can be structurally suspicious even when a generic archive or
restic check succeeds.

Use a Python scanner pod mounted read-only to both the scratch PVC and the
frozen production PVC before selecting a restore candidate. A healthy region
has zero structural problems and decompresses all referenced chunks. Record
read errors separately: they can indicate storage-level missing data even when
an Anvil header is structurally valid.

Map the player position to a region before restoring it: floor-divide block
coordinates by 16 to obtain chunk coordinates, then floor-divide those by 32
to obtain region coordinates. Do not retain a prior incident's affected region
as the current target without rescanning production.

A clean Paper startup does not validate every region. Paper loads regions as
players or forced chunks require them, so scan or deliberately load the
suspected area before declaring the world healthy.

## Surgical region replacement

If only one region needs replacement, keep the server stopped and replace just
that file from a verified source.

1. Create a timestamped full-PVC preservation copy when the current production
   state has not already been preserved. Mount production read-only in the copy
   pod and verify file count, byte count, and per-file SHA256 manifests.
2. Mount the production PVC read/write in a temporary pod.
3. Copy the current file aside with a timestamped suffix.
4. Upload the verified replacement file.
5. Verify SHA256 after upload.
6. Install the replacement with ownership `1000:3000` and mode `0664`.
7. Delete the helper pod and restart Minecraft.

Example target path:

```text
/data/world/dimensions/minecraft/overworld/region/r.-12.-3.mca
```

Example preservation suffix:

```text
.pre-surgical-restore-<timestamp>
```

## Paper `.backup` files

Paper may create `*.backup` region files when it detects a bad region header and
recalculates offsets. These files preserve the pre-repair bytes; they are useful
for forensics but are not necessarily recoverable.

In the 2026-09-05 incident:

- `r.-12.-3.mca.390717034322168368.backup` contained only 2 readable chunks and
  1022 zero-length/bad chunk records.
- the clean replacement came from an earlier partial local extraction under
  `/tmp`, not from the Paper `.backup` file.

## SeaweedFS historical data note

This cluster's Minecraft PVC is backed by SeaweedFS CSI. During the incident,
Kubernetes did not expose `VolumeSnapshot` or `VolumeSnapshotClass` resources,
and no obvious historical object versions were available through the PVC path.
Treat restic and explicit PVC copies as the recovery sources for Minecraft.

## Restart

After restore or surgical replacement:

```bash
kubectl -n minecraft scale deploy/minecraft-server --replicas=1
kubectl -n minecraft rollout status deploy/minecraft-server --timeout=240s
kubectl -n minecraft logs deploy/minecraft-server -c minecraft-server --tail=300 \
  | rg 'could not be recovered|corrupt|regenerated|regionfile|ERROR|WARN' || true
```

Minecraft/Paper generally detects region corruption when regions or chunks are
loaded, not by scanning every region file at startup. A clean startup log does
not prove every region in the world has been loaded.
