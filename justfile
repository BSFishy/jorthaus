set dotenv-load

# list recipes
default:
  @just --list

# ssh into a nixos node
ssh host:
  ssh matt@{{host}}.node.jort.haus

# build and switch a nixos node
switch host:
  nh os switch --elevation-strategy passwordless --target-host {{host}}.node.jort.haus .#{{host}}

# install a nixos node from a live environment over ssh
install-node target host:
  nix run nixpkgs#nixos-anywhere -- --flake .#{{host}} {{target}}

# plan terraform changes for unifi
[working-directory: 'terraform/unifi']
plan-unifi:
  tofu plan

# apply terraform changes for unifi
[working-directory: 'terraform/unifi']
apply-unifi:
  tofu apply

# create or edit an agenix-managed secret file
secret-edit name:
  agenix -e secrets/{{name}} -i "$HOME/.ssh/id_ed25519"

# re-encrypts all secrets with specified recipients
secret-rekey:
  agenix -r -i "$HOME/.ssh/id_ed25519"

# generate and encrypt a new random hex secret
[script]
secret-random name bytes='32':
  tmp=$(printf %s "$(nix-shell -p openssl --run 'openssl rand -hex {{bytes}}')")
  printf %s "$tmp" | agenix -e secrets/{{name}}

# generate & encrypt new openbao unsealing key
openbao-key name:
  just secret-random {{name}} 32
