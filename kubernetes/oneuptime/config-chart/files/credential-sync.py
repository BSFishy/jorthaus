import base64
import datetime as dt
import json
import logging
import os
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request


VAULT_ADDR = os.environ["VAULT_ADDR"].rstrip("/")
VAULT_ROLE = os.environ["VAULT_ROLE"]
POSTGRES_CREDS_PATH = os.environ["POSTGRES_CREDS_PATH"]
VALKEY_CREDS_PATH = os.environ["VALKEY_CREDS_PATH"]
VALKEY_HOSTS = [host.strip() for host in os.environ["VALKEY_HOSTS"].split(",") if host.strip()]
VALKEY_PORT = int(os.environ.get("VALKEY_PORT", "6379"))
VALKEY_DB = os.environ.get("VALKEY_DB", "1")
VALKEY_CA_FILE = os.environ.get("VALKEY_CA_FILE", "/etc/ssl/certs/ca-certificates.crt")
VALKEY_PROPAGATION_TIMEOUT = int(os.environ.get("VALKEY_PROPAGATION_TIMEOUT", "180"))
NAMESPACE = os.environ["POD_NAMESPACE"]
SECRET_NAME = "oneuptime-backend-credentials"
ROTATION_SECONDS = int(os.environ.get("ROTATION_SECONDS", "604800"))
RETRY_SECONDS = int(os.environ.get("RETRY_SECONDS", "300"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "300"))
ISSUED_ANNOTATION = "oneuptime.jort.haus/credentials-issued-at"
VALID_UNTIL_ANNOTATION = "oneuptime.jort.haus/credentials-valid-until"

K8S_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
K8S_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
VAULT_JWT_PATH = "/var/run/secrets/openbao/token"
PENDING_CREDENTIALS = None


class HTTPStatusError(RuntimeError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"HTTP request returned status {status}")


def request_json(url, method="GET", body=None, headers=None, context=None):
    request_headers = {"Accept": "application/json"}
    if body is not None:
        request_headers["Content-Type"] = "application/json"
    if headers:
        request_headers.update(headers)
    encoded_body = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        url, data=encoded_body, headers=request_headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=20, context=context) as response:
            return json.loads(response.read()) if response.status != 204 else {}
    except urllib.error.HTTPError as error:
        raise HTTPStatusError(error.code) from None
    except urllib.error.URLError:
        raise RuntimeError("HTTP request failed") from None


def vault_token():
    jwt = open(VAULT_JWT_PATH).read().strip()
    response = request_json(
        f"{VAULT_ADDR}/v1/auth/kubernetes/login",
        method="POST",
        body={"role": VAULT_ROLE, "jwt": jwt},
    )
    return response["auth"]["client_token"]


def read_dynamic_credentials(token, path):
    response = request_json(
        f"{VAULT_ADDR}/v1/{path.lstrip('/')}",
        headers={"X-Vault-Token": token},
    )
    data = response["data"]
    username = data.get("username")
    password = data.get("password")
    lease_duration = response.get("lease_duration", 0)
    if not isinstance(username, str) or not username:
        raise RuntimeError("dynamic credential response has no username")
    if not isinstance(password, str) or not password:
        raise RuntimeError("dynamic credential response has no password")
    if not isinstance(lease_duration, int) or lease_duration < ROTATION_SECONDS * 2:
        raise RuntimeError("dynamic credential lease is shorter than the rotation safety window")
    return {
        "username": username,
        "password": password,
        "lease_duration": lease_duration,
        "valid_until": (
            dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=lease_duration)
        ).isoformat(timespec="seconds").replace("+00:00", "Z"),
    }


def resp_command(stream, *arguments):
    payload = [f"*{len(arguments)}\r\n".encode()]
    for argument in arguments:
        encoded = argument.encode()
        payload.extend([f"${len(encoded)}\r\n".encode(), encoded, b"\r\n"])
    stream.sendall(b"".join(payload))

    response = bytearray()
    while not response.endswith(b"\r\n"):
        chunk = stream.recv(1)
        if not chunk:
            raise RuntimeError("Valkey closed the credential validation connection")
        response.extend(chunk)
    if response.startswith(b"-"):
        raise RuntimeError("Valkey rejected the credential validation command")
    if not response.startswith(b"+"):
        raise RuntimeError("Valkey returned an unexpected credential validation response")
    return response[1:-2].decode()


def valkey_authenticates(host, username, password):
    context = ssl.create_default_context(cafile=VALKEY_CA_FILE)
    with socket.create_connection((host, VALKEY_PORT), timeout=5) as connection:
        with context.wrap_socket(connection, server_hostname=host) as stream:
            stream.settimeout(5)
            if resp_command(stream, "AUTH", username, password) != "OK":
                return False
            if resp_command(stream, "SELECT", VALKEY_DB) != "OK":
                return False
            return resp_command(stream, "PING") == "PONG"


def wait_for_valkey_credential(username, password):
    if not VALKEY_HOSTS:
        raise RuntimeError("no Valkey nodes are configured for credential validation")
    deadline = time.monotonic() + VALKEY_PROPAGATION_TIMEOUT
    while time.monotonic() < deadline:
        ready = True
        for host in VALKEY_HOSTS:
            try:
                if not valkey_authenticates(host, username, password):
                    ready = False
            except Exception:
                ready = False
        if ready:
            return
        time.sleep(5)
    raise RuntimeError("dynamic Valkey credentials did not authenticate on every node")


def k8s_context():
    return ssl.create_default_context(cafile=K8S_CA_PATH)


def k8s_headers():
    token = open(K8S_TOKEN_PATH).read().strip()
    return {"Authorization": f"Bearer {token}"}


def k8s_url(path):
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    port = os.environ.get("KUBERNETES_SERVICE_PORT_HTTPS", "443")
    return f"https://{host}:{port}{path}"


def read_backend_secret():
    path = f"/api/v1/namespaces/{NAMESPACE}/secrets/{SECRET_NAME}"
    try:
        return request_json(k8s_url(path), headers=k8s_headers(), context=k8s_context())
    except HTTPStatusError as error:
        if error.status == 404:
            return None
        raise


def store_backend_secret(credentials, issued_at, valid_until, existing):
    data = {
        key: base64.b64encode(value.encode()).decode()
        for key, value in credentials.items()
    }
    metadata = {
        "name": SECRET_NAME,
        "namespace": NAMESPACE,
        "annotations": {
            ISSUED_ANNOTATION: issued_at,
            VALID_UNTIL_ANNOTATION: valid_until,
        },
        "labels": {"app.kubernetes.io/part-of": "oneuptime"},
    }
    if existing:
        metadata["resourceVersion"] = existing["metadata"]["resourceVersion"]
        metadata["labels"].update(existing["metadata"].get("labels", {}))
        metadata["annotations"].update(existing["metadata"].get("annotations", {}))
        metadata["annotations"][ISSUED_ANNOTATION] = issued_at
        metadata["annotations"][VALID_UNTIL_ANNOTATION] = valid_until

    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": metadata,
        "type": "Opaque",
        "data": data,
    }
    path = f"/api/v1/namespaces/{NAMESPACE}/secrets/{SECRET_NAME}"
    request_json(
        k8s_url(path),
        method="PUT",
        body=body,
        headers=k8s_headers(),
        context=k8s_context(),
    )


def rollout_consumers(issued_at):
    selector = urllib.parse.quote("appname=oneuptime", safe="")
    path = f"/apis/apps/v1/namespaces/{NAMESPACE}/deployments?labelSelector={selector}"
    deployments = request_json(
        k8s_url(path), headers=k8s_headers(), context=k8s_context()
    ).get("items", [])
    patched = 0
    for deployment in deployments:
        metadata = deployment["metadata"]
        template = deployment.get("spec", {}).get("template", {}).get("metadata", {})
        annotations = template.get("annotations", {})
        if annotations.get(ISSUED_ANNOTATION) == issued_at:
            continue
        patch = {
            "spec": {
                "template": {
                    "metadata": {
                        "annotations": {ISSUED_ANNOTATION: issued_at}
                    }
                }
            }
        }
        request_json(
            k8s_url(
                f"/apis/apps/v1/namespaces/{NAMESPACE}/deployments/{metadata['name']}"
            ),
            method="PATCH",
            body=patch,
            headers={
                **k8s_headers(),
                "Content-Type": "application/merge-patch+json",
            },
            context=k8s_context(),
        )
        patched += 1
    return patched


def parse_timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def sync_once():
    global PENDING_CREDENTIALS

    existing = read_backend_secret()
    annotations = existing.get("metadata", {}).get("annotations", {}) if existing else {}
    issued_at = annotations.get(ISSUED_ANNOTATION)
    now = dt.datetime.now(dt.timezone.utc)
    due = not issued_at
    if issued_at:
        due = (now - parse_timestamp(issued_at)).total_seconds() >= ROTATION_SECONDS

    if due:
        if PENDING_CREDENTIALS is None:
            PENDING_CREDENTIALS = {
                "issued_at": now.isoformat(timespec="seconds").replace("+00:00", "Z"),
                "postgres": None,
                "valkey": None,
            }

        if (
            PENDING_CREDENTIALS["postgres"] is None
            or PENDING_CREDENTIALS["valkey"] is None
        ):
            token = vault_token()
            if PENDING_CREDENTIALS["postgres"] is None:
                PENDING_CREDENTIALS["postgres"] = read_dynamic_credentials(
                    token, POSTGRES_CREDS_PATH
                )
            if PENDING_CREDENTIALS["valkey"] is None:
                PENDING_CREDENTIALS["valkey"] = read_dynamic_credentials(
                    token, VALKEY_CREDS_PATH
                )

        valkey = PENDING_CREDENTIALS["valkey"]
        wait_for_valkey_credential(valkey["username"], valkey["password"])

        leases = [PENDING_CREDENTIALS["postgres"], valkey]
        valid_until = min(lease["valid_until"] for lease in leases)
        lease_duration = min(lease["lease_duration"] for lease in leases)
        credentials = {
            "database-username": PENDING_CREDENTIALS["postgres"]["username"],
            "database-password": PENDING_CREDENTIALS["postgres"]["password"],
            "valkey-username": valkey["username"],
            "valkey-password": valkey["password"],
        }
        store_backend_secret(
            credentials,
            PENDING_CREDENTIALS["issued_at"],
            valid_until,
            existing,
        )
        issued_at = PENDING_CREDENTIALS["issued_at"]
        PENDING_CREDENTIALS = None
        logging.info(
            "stored new PostgreSQL and Valkey credential pairs with minimum lease %d seconds",
            lease_duration,
        )

    patched = rollout_consumers(issued_at)
    if patched:
        logging.info("requested credential adoption rollout for %d deployments", patched)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    while True:
        try:
            sync_once()
            time.sleep(POLL_SECONDS)
        except Exception as error:
            logging.error("credential synchronization failed (%s)", type(error).__name__)
            time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    main()
