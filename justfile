set dotenv-load

# list recipes
default:
  @just --list

# build all VM images into result/
build:
  nix build .#vm-images --out-link result

# build the home VM image into result-home/
build-home:
  nix build .#home --out-link result-home

# plan terraform changes after building images
[working-directory: 'terraform']
plan: build
  tofu plan

# apply terraform changes after building images
[working-directory: 'terraform']
apply: build
  tofu apply
