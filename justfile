set dotenv-load

# list recipes
default:
  @just --list

# build the bootstrap VM image into result/
build:
  nix build .#bootstrap-image --out-link result

# generate terraform variables from inventory.nix
tfvars:
  nix eval --json .#terraform.vars > terraform/generated.auto.tfvars.json

# create or edit an agenix-managed secret file
secret-edit name:
  agenix -e secrets/{{name}}.age -i "$HOME/.ssh/id_ed25519"

# switch a host to its nixosConfiguration using inventory metadata
switch host:
  nh os switch --elevation-strategy passwordless --target-host $(nix eval --raw .#inventory.{{host}}.ipv4.address) .#{{host}}

# plan terraform changes after building images
[working-directory: 'terraform']
plan: build tfvars
  tofu plan

# apply terraform changes after building images
[working-directory: 'terraform']
apply: build tfvars
  tofu apply
