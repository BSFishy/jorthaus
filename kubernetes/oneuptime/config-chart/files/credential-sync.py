import base64
import datetime as dt
import json
import logging
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request


VAULT_ADDR = os.environ["VAULT_ADDR"].rstrip("/")
VAULT_ROLE = os.environ["VAULT_ROLE"]
POSTGRES_CREDS_PATH = os.environ["POSTGRES_CREDS_PATH"]
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
    return username, password, lease_duration


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
    selector = urllib.parse.quote("app.kubernetes.io/instance=oneuptime", safe="")
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
            token = vault_token()
            postgres = read_dynamic_credentials(token, POSTGRES_CREDS_PATH)
            issued_at = now.isoformat(timespec="seconds").replace("+00:00", "Z")
            lease_duration = postgres[2]
            valid_until = (now + dt.timedelta(seconds=lease_duration)).isoformat(
                timespec="seconds"
            ).replace("+00:00", "Z")
            PENDING_CREDENTIALS = {
                "credentials": {
                    "database-username": postgres[0],
                    "database-password": postgres[1],
                },
                "issued_at": issued_at,
                "valid_until": valid_until,
                "lease_duration": lease_duration,
            }

        store_backend_secret(
            PENDING_CREDENTIALS["credentials"],
            PENDING_CREDENTIALS["issued_at"],
            PENDING_CREDENTIALS["valid_until"],
            existing,
        )
        issued_at = PENDING_CREDENTIALS["issued_at"]
        lease_duration = PENDING_CREDENTIALS["lease_duration"]
        PENDING_CREDENTIALS = None
        logging.info(
            "stored a new backend credential set with lease %d seconds",
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
