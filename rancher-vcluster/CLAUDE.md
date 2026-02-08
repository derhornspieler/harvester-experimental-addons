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

## vCluster 0.30.0 Configuration

vCluster 0.20+ has strict Helm schema validation. However, `global:` is a standard Helm construct and IS allowed. The official Harvester v1.7.0 addon uses `global.hostname`, `global.rancherVersion`, and `global.bootstrapPassword` which are templated into `manifestsTemplate` via `{{ .Values.global.* }}`.

Requires Harvester v1.7.0+ (v1.6.x webhook required root-level `hostname:` which conflicts with vCluster's schema).

## Versions

- vCluster chart: v0.30.0
- K3s: v1.34.2-k3s1
- Rancher: v2.13.2
- cert-manager: v1.18.5
