# rancher-vcluster Addon

Deploys Rancher management server inside a vCluster on Harvester.

See the root [CLAUDE.md](../../CLAUDE.md) for full project context.

## Quick Reference

```bash
# Edit rancher-vcluster.yaml first - set hostname and bootstrapPassword in the manifestsTemplate

# Apply addon
kubectl apply -f rancher-vcluster.yaml

# Enable
kubectl patch addon rancher-vcluster -n rancher-vcluster --type=merge -p '{"spec":{"enabled":true}}'

# Check status
kubectl get addon rancher-vcluster -n rancher-vcluster
```

## vCluster 0.30.0 Schema Note

vCluster 0.20+ has strict Helm schema validation. Custom values like `global.hostname` are **not allowed**. Values must be hardcoded directly in `manifestsTemplate`.

## Versions

- vCluster chart: v0.30.0
- K3s: v1.31.4-k3s1
- Rancher: v2.13.0
- cert-manager: v1.17.1
