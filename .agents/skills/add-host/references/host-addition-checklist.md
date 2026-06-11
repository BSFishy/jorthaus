# Host Addition Checklist

1. Read the current deployment docs.
2. Verify the current inventory schema in `inventory.nix`.
3. Add a new host entry with the same shape.
4. Create `modules/hosts/<host>.nix`.
5. Enable only the intended services in that host module.
6. Verify `.#nixosConfigurations.<host>` evaluates.
7. Verify `.#terraform.vars` includes the host.
8. Update docs if network, DNS, or secret assumptions changed.
