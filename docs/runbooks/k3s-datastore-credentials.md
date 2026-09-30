# K3s datastore credential migration

K3s control planes use PostgreSQL through Kine. The old `k3s` PostgreSQL role
is rotated by OpenBao and its environment file is read when the K3s process
starts. This runbook migrates K3s to an agenix-backed `k3s_static` login while
retaining the old login as rollback during the rollout.

## Secret handling

Create the encrypted password once from the repository root:

```bash
just create-k3s-datastore-secret
```

The script verifies `XDG_RUNTIME_DIR` is a private tmpfs, then generates 32
random bytes as hexadecimal and pipes them directly to agenix. Agenix's private
plaintext temp directory is created there and removed by its cleanup handler.
The script also verifies the encrypted file can be decrypted by the local
identity without displaying plaintext, and refuses to overwrite an existing
secret. The password never appears in command arguments, terminal output,
shell history, or logs. Do not decrypt or display the secret.

The encrypted file is `secrets/k3s-datastore-password.age`; `secrets.nix`
limits its recipients to Matt and Gaia-01 through Gaia-03. The PostgreSQL
ensure service applies it to `k3s_static` using psql's `\password` command,
which computes the verifier on the client before sending the role update.

## Provision the parallel login

The NixOS PostgreSQL ensure configuration creates `k3s_static`, grants it
membership in the existing `k3s` owner role, and sets the password from the
agenix file. This lets the new login use the existing K3s database and schema
without changing ownership during the migration.

Apply the credential declaration to Gaia-01 first, one node at a time using
the maintenance procedure in [the K3s node runbook](k3s-node-maintenance.md):

1. Cordon and drain Gaia-01.
2. Run `just switch gaia-01`.
3. Wait for the K3s service, node, and running pods to recover.
4. Confirm `jorthaus-postgres-ensure.service` succeeded and the new role can
   authenticate with PostgreSQL TLS verification, without printing a DSN or
   password.
5. Uncordon Gaia-01.

At this stage all three control planes still use the OpenBao-issued `k3s`
credential. Keep that credential and its OpenBao policy available.

## Cut over control planes

After the parallel role is verified, change the K3s datastore environment to
use `k3s_static` and the agenix password. Switch Gaia-01, Gaia-02, and Gaia-03
one at a time. Before each switch, cordon and drain the node; after the switch,
wait for K3s, the node, and running pods to recover before uncordoning. Keep
the old OpenBao login valid until every control plane is using `k3s_static` and
K3s datastore authentication is healthy.

Verify the connected PostgreSQL login using a query that reports only role
names and connection state. Never inspect or print the complete K3s process
environment or datastore URL.

## Retire the old login

Only after the rollout and rollback window are complete:

1. Remove the K3s AppRole's permission to read
   `postgres/static-creds/k3s` and remove the OpenBao static-role rotation.
2. Set the PostgreSQL `k3s` role to `NOLOGIN`.
3. Verify all K3s connections use `k3s_static` and no new connections use the
   old login.

Keep the `k3s` PostgreSQL role as a `NOLOGIN` owner role. It owns the database
and schema; do not drop it or reassign those objects as part of credential
cleanup. Preserve the encrypted `k3s_static` password as the durable credential.
