set dotenv-load

# list recipes
default:
  @just --list

# ssh into a nixos node
ssh host:
  ssh matt@{{host}}.jort.haus

# build and switch a nixos node
switch host:
  nh os switch --elevation-strategy passwordless --target-host {{host}}.jort.haus .#{{host}}

# plan terraform changes for unifi
[working-directory: 'terraform/unifi']
plan-unifi:
  tofu plan

# apply terraform changes for unifi
[working-directory: 'terraform/unifi']
apply-unifi:
  tofu apply
