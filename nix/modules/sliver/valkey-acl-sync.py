import hashlib
import logging
import os
import shlex
import subprocess
import time


CLI = os.environ["VALKEY_CLI"]
PRIMARY_HOST = os.environ["VALKEY_PRIMARY_HOST"]
LOCAL_HOST = os.environ["VALKEY_LOCAL_HOST"]
PORT = os.environ.get("VALKEY_PORT", "6379")
PASSWORD_FILE = os.environ["VALKEY_PASSWORD_FILE"]
CA_FILE = os.environ["VALKEY_CA_FILE"]
STATE_FILE = os.environ["VALKEY_ACL_SYNC_STATE"]
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "15"))


def read_password():
    with open(PASSWORD_FILE, encoding="utf-8") as password_file:
        return password_file.read().rstrip("\r\n")


def command(host, password, *arguments):
    environment = os.environ.copy()
    environment["REDISCLI_AUTH"] = password
    result = subprocess.run(
        [
            CLI,
            "--tls",
            "--cacert",
            CA_FILE,
            "--sni",
            host,
            "--no-auth-warning",
            "--raw",
            "-h",
            host,
            "-p",
            PORT,
            *arguments,
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
        env=environment,
    )
    return result.stdout.strip()


def users_from_acl_list(output):
    users = {}
    for line in output.splitlines():
        parts = shlex.split(line)
        if len(parts) < 2 or parts[0] != "user":
            raise RuntimeError("ACL LIST returned an invalid user entry")
        username = parts[1]
        if username in users:
            raise RuntimeError("ACL LIST returned a duplicate username")
        users[username] = parts
    if "default" not in users:
        raise RuntimeError("authoritative ACL list has no default user")
    return users


def canonical(users):
    return "\n".join(" ".join(users[name]) for name in sorted(users))


def reconcile(password):
    desired = users_from_acl_list(command(PRIMARY_HOST, password, "ACL", "LIST"))
    current = users_from_acl_list(command(LOCAL_HOST, password, "ACL", "LIST"))
    if current["default"] != desired["default"]:
        raise RuntimeError("default ACL differs between the primary and this node")

    changed = False
    for username, desired_entry in desired.items():
        if username == "default" or current.get(username) == desired_entry:
            continue
        command(
            LOCAL_HOST,
            password,
            "ACL",
            "SETUSER",
            username,
            "reset",
            *desired_entry[2:],
        )
        changed = True

    stale_users = sorted(set(current) - set(desired) - {"default"})
    if stale_users:
        command(LOCAL_HOST, password, "ACL", "DELUSER", *stale_users)
        changed = True

    if changed:
        current = users_from_acl_list(command(LOCAL_HOST, password, "ACL", "LIST"))
        if current != desired:
            raise RuntimeError("local ACL does not match the authoritative ACL")

    # A primary-side ACL update can leave memory equal to the source while its
    # file is stale, so persist when the source fingerprint changes.
    digest = hashlib.sha256(canonical(desired).encode()).hexdigest()
    try:
        with open(STATE_FILE, encoding="ascii") as state_file:
            saved_digest = state_file.read().strip()
    except FileNotFoundError:
        saved_digest = None

    if changed or digest != saved_digest:
        command(LOCAL_HOST, password, "ACL", "SAVE")
        temporary_file = f"{STATE_FILE}.tmp"
        with open(temporary_file, "w", encoding="ascii") as state_file:
            state_file.write(digest + "\n")
            state_file.flush()
            os.fsync(state_file.fileno())
        os.replace(temporary_file, STATE_FILE)
        logging.info("saved the reconciled ACL set")


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    while True:
        try:
            reconcile(read_password())
        except Exception as error:
            logging.warning("ACL reconciliation failed (%s)", type(error).__name__)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
