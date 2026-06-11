# Service Addition Checklist

1. Read docs for routing, environment, and secrets.
2. Decide whether the service belongs under a host path or a shared path.
3. Create a dedicated module unless there is a strong reason not to.
4. Define `homelab.<service>.enable`.
5. Gate all side effects on that enable option.
6. Expose additional `homelab.<service>.*` options for meaningful config.
7. Register `homelab.services.<service>` if the service should be externally reachable.
8. Import the module from the correct `default.nix`.
9. Enable the service in the target host module.
10. Update docs if DNS, routing, or secrets changed.
