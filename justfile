set dotenv-load
set default-list := true

import 'kubernetes/justfile'
import 'terraform/justfile'

# initialize the Terraform providers used for application configuration
[group('terraform')]
[working-directory: 'terraform/apps']
init-apps:
  tofu init

# plan application configuration with the Authentik token read directly from OpenBao
[group('terraform')]
[working-directory: 'terraform/apps']
plan-apps:
  AUTHENTIK_URL=https://auth.jort.haus AUTHENTIK_TOKEN="$(vault kv get -mount=authentik -field=token terraform)" tofu plan

# apply application configuration with the Authentik token read directly from OpenBao
[group('terraform')]
[working-directory: 'terraform/apps']
apply-apps:
  AUTHENTIK_URL=https://auth.jort.haus AUTHENTIK_TOKEN="$(vault kv get -mount=authentik -field=token terraform)" tofu apply

# synchronize the version-controlled AppDaemon apps into its persistent volume
[script]
[group('kubernetes')]
appdaemon-deploy:
  set -euo pipefail
  test -f appdaemon-apps/apps.yaml
  pod=$(kubectl -n home-assistant get pod -l app.kubernetes.io/name=appdaemon -o jsonpath='{.items[0].metadata.name}')
  tar --exclude='apps.yaml' --exclude='__pycache__' --exclude='*.pyc' -C appdaemon-apps -cf - . \
    | kubectl -n home-assistant exec -i "$pod" -c appdaemon -- tar -C /conf/apps -xf -
  cat appdaemon-apps/apps.yaml \
    | kubectl -n home-assistant exec -i "$pod" -c appdaemon -- sh -ec 'cat > /conf/apps/.apps.yaml.next && mv /conf/apps/.apps.yaml.next /conf/apps/apps.yaml'
  kubectl -n home-assistant logs deployment/appdaemon -c appdaemon --tail=20

# verify nix diagnostics pass
[group('nix')]
nix-check:
  find . -name '*.nix' | xargs nil diagnostics --deny-warnings
  nix --option abort-on-warn true --option warn-dirty false flake check --all-systems

# validate static and generated Prometheus alert rules
[group('nix')]
prometheus-rules-test:
  nix-shell -p prometheus.cli python3 --run 'promtool check rules nix/modules/sliver/prometheus/rules.yml && promtool test rules nix/modules/sliver/prometheus/rules.test.yml && promtool test rules nix/modules/sliver/prometheus/openbao-backup-rules.test.yml && promtool test rules nix/modules/sliver/prometheus/kubernetes-rules.test.yml && promtool test rules nix/modules/sliver/prometheus/kubernetes-resource-rules.test.yml && promtool test rules nix/modules/sliver/prometheus/xfs-quota-rules.test.yml && scripts/test-xfs-project-quota-metrics && scripts/test-prometheus-systemd-rules'

# ssh into a nixos node
[group('nix')]
ssh host:
  ssh matt@{{host}}.node.jort.haus

# reboot a nixos node
[group('nix')]
reboot host:
  ssh matt@{{host}}.node.jort.haus sudo reboot

# build and switch a nixos node
[group('nix')]
switch host:
  # TODO: Orchestrate K3s-restarting switches: detect K3s, cordon and drain
  # before activation, then uncordon after recovery only if this switch did.
  nh os switch --elevation-strategy passwordless --show-activation-logs --target-host {{host}}.node.jort.haus .#{{host}}

# Restart K3s on one node using the documented cordon/drain procedure.
[group('kubernetes')]
restart-k8s host:
  scripts/restart-k8s-node '{{host}}'

# install a nixos node from a live environment over ssh
[group('nix')]
install-node target host:
  nix run nixpkgs#nixos-anywhere -- --flake .#{{host}} {{target}}

# create or edit an agenix-managed secret file
[group('secret')]
secret-edit name:
  agenix -e secrets/{{name}} -i "$HOME/.ssh/id_ed25519"

# re-encrypts all secrets with specified recipients
[group('secret')]
secret-rekey:
  agenix -r -i "$HOME/.ssh/id_ed25519"

# generate and encrypt a new random hex secret
[script]
[group('secret')]
secret-random name bytes='32':
  tmp=$(printf %s "$(nix-shell -p openssl --run 'openssl rand -hex {{bytes}}')")
  printf %s "$tmp" | agenix -e secrets/{{name}}

# Create the encrypted static K3s datastore password without printing plaintext.
[group('secret')]
create-k3s-datastore-secret:
  scripts/create-k3s-datastore-secret

# Create the encrypted static SeaweedFS PostgreSQL password.
[group('secret')]
create-seaweedfs-postgres-secret:
  scripts/create-seaweedfs-postgres-secret

# Apply the declarative PostgreSQL roles and grants through the host oneshot.
[group('postgres')]
postgres-ensure:
  ssh matt@gaia-01.node.jort.haus sudo systemctl start jorthaus-postgres-ensure.service

# Stage, roll back, or retire a SeaweedFS S3 grant key without printing it.
[script]
[group('seaweedfs')]
seaweedfs-s3-rotate phase grant confirmation='':
  scripts/run-seaweedfs-s3-operation rotate '{{phase}}' '{{grant}}' '{{confirmation}}'

# Exercise PUT/HEAD/GET/DELETE through a selected Gaia SeaweedFS filer.
[group('seaweedfs')]
seaweedfs-s3-canary host='gaia-03':
  scripts/run-seaweedfs-s3-operation canary '{{host}}'

# Encrypt the public K3s server CA for the host-native Prometheus pair.
[group('secret')]
create-prometheus-kubelet-ca:
  scripts/create-prometheus-kubelet-ca

# Issue a one-year TokenRequest token for host-native kubelet scraping.
[group('secret')]
create-prometheus-kubelet-token mode='create':
  scripts/create-prometheus-kubelet-token '{{mode}}'

# Issue one-year TokenRequest tokens for Kubernetes metrics scraping.
[group('secret')]
create-prometheus-control-plane-token mode='create':
  scripts/create-prometheus-control-plane-token '{{mode}}'

[group('secret')]
create-prometheus-app-metrics-token mode='create':
  scripts/create-prometheus-app-metrics-token '{{mode}}'

# generate & encrypt new openbao unsealing key
[group('secret')]
openbao-key name:
  just secret-random {{name}} 32

[script]
[group('secret')]
create-openbao-backup-approle-secrets:
  set -euo pipefail
  role_id_file=secrets/openbao-backup-approle-role-id.age
  secret_id_file=secrets/openbao-backup-approle-secret-id.age
  test ! -e "$role_id_file" && test ! -e "$secret_id_file"
  bao read -field=role_id auth/approle/role/openbao-raft-backup/role-id \
    | agenix -e "$role_id_file"
  bao write -f -field=secret_id auth/approle/role/openbao-raft-backup/secret-id \
    | agenix -e "$secret_id_file"

# Initialize the OpenBao Restic repository once on a deployed host.
[group('openbao')]
openbao-backup-init host:
  ssh matt@{{host}}.node.jort.haus sudo systemctl start openbao-raft-backup-init.service

# Run the host-native OpenBao backup once on the selected node.
[group('openbao')]
openbao-backup-run host:
  ssh matt@{{host}}.node.jort.haus sudo systemctl start openbao-raft-backup.service

# Check the Restic repository and preview the configured retention policy.
[group('openbao')]
openbao-backup-verify host:
  ssh matt@{{host}}.node.jort.haus sudo systemctl start openbao-raft-backup-verify.service
  ssh matt@{{host}}.node.jort.haus sudo systemctl start openbao-raft-backup-metrics.service
