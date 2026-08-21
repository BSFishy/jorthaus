set dotenv-load

# list recipes
default:
  @just --list

# plan terraform changes for unifi
[working-directory: 'terraform/unifi']
plan-unifi:
  tofu plan

# apply terraform changes for unifi
[working-directory: 'terraform/unifi']
apply-unifi:
  tofu apply
