---
description: Validate kured-managed NixOS node reboots
---

# kured runbook

kured runs as a DaemonSet in `kube-system` and coordinates one node reboot at a
time when `/var/run/reboot-required` exists on the host. The chart mounts
`/var/run` into the pod at `/sentinel`, so kured checks
`/sentinel/reboot-required` inside the container.

## Configuration

The kured Helm values live at:

```text
kubernetes/kured/values/kured.yaml
```

The NixOS reboot command must use the host's Nix profile path:

```yaml
configuration:
  rebootSentinel: /var/run/reboot-required
  rebootCommand: /run/current-system/sw/bin/systemctl reboot
```

The default `/bin/systemctl reboot` path does not exist on NixOS hosts when
kured enters the host mount namespace.

## Check DaemonSet health

```bash
kubectl -n kube-system get ds kured
kubectl -n kube-system get pods -l app.kubernetes.io/name=kured -o wide
```

All desired pods should be ready, with one pod on each Linux node.

## Verify rendered arguments

```bash
kubectl -n kube-system describe ds kured | rg 'reboot-command|reboot-sentinel|start-time|end-time|lock-release'
```

Expected values include:

```text
--reboot-sentinel=/sentinel/reboot-required
--reboot-command=/run/current-system/sw/bin/systemctl reboot
```

## Check logs

```bash
for pod in $(kubectl -n kube-system get pods -l app.kubernetes.io/name=kured -o name); do
  echo "===$pod==="
  kubectl -n kube-system logs "$pod" --tail=120 \
    | rg -i 'reboot command|sentinel|reboot required|draining|triggering|unable|fatal|error|lock' || true
  kubectl -n kube-system logs "$pod" --previous 2>/dev/null \
    | rg -i 'triggering reboot|unable to reboot|fatal|error|systemctl' || true
done
```

Healthy logs should show the NixOS `systemctl` path. Failed reboot attempts can
look like:

```text
nsenter: can't execute '/bin/systemctl': No such file or directory
```

## Check the coordination lock

```bash
kubectl -n kube-system get ds kured \
  -o jsonpath='{.metadata.annotations.weave\.works/kured-node-lock}{"\n"}'
```

`lockReleaseDelay: 24h` spaces reboot operations by a day. `lockTtl: 24h`
expires a lock that was not released, so a replaced or failed kured pod cannot
block later maintenance windows indefinitely. A stale-looking lock can be
normal inside that delay window.

## Correlate host sentinels and boot times

```bash
for host in gaia-01 gaia-02 gaia-03; do
  echo "===$host==="
  ssh matt@$host.node.jort.haus '
    cat /proc/stat | awk "/btime/ {print \$2}" | xargs -I{} date -u -d @{}
    uptime
    sudo stat -c "sentinel=%n mode=%a owner=%U group=%G mtime=%y" /var/run/reboot-required 2>/dev/null || echo no-sentinel
    systemctl list-timers --all jorthaus-k3s-weekly-reboot-sentinel.timer --no-pager
  '
done
```

A node has actually rebooted only when its boot time advances. kured pod restarts
or node annotations alone do not prove host reboot success.

## Check failed units after reboots

```bash
for host in gaia-01 gaia-02 gaia-03; do
  echo "===$host==="
  ssh matt@$host.node.jort.haus 'systemctl --failed --no-pager'
done
```

Follow up on any failed units before relying on the weekly reboot cycle for
credential refresh or maintenance workflows.
