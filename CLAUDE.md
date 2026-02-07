# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains experimental Harvester addons - Kubernetes custom resources that extend Harvester HCI functionality. Two addons deploy Rancher management server in virtual clusters:

- **rancher-vcluster** - Uses Loft's vCluster (production-ready)
- **rancher-k3k** - Uses Rancher's k3k (development, alternative)

**Warning**: These addons are experimental and not for production use.

## Architecture

### Harvester Addon CRD
Each addon is a `harvesterhci.io/v1beta1/Addon` resource that wraps a Helm chart:
- `spec.repo` - Helm chart repository URL
- `spec.chart` - Chart name
- `spec.version` - Chart version
- `spec.valuesContent` - Inline Helm values (YAML)
- `spec.enabled` - Toggle addon on/off

### rancher-vcluster Addon
Deploys vCluster v0.30.0 with embedded manifests that bootstrap cert-manager and Rancher.

**Important:** vCluster 0.20+ has strict schema validation. Custom values must be hardcoded directly in `manifestsTemplate` (not under `global:`).

### rancher-k3k Addon
Alternative using Rancher's k3k (Kubernetes in Kubernetes). Unlike vCluster, k3k does **not** support embedded manifests - Rancher must be deployed separately after cluster creation.

## Deployment

Use the interactive deploy script:
```bash
./deploy.sh
```

Or deploy manually - see individual addon READMEs.

## Comparison: vCluster vs k3k

| Feature | vCluster | k3k |
|---------|----------|-----|
| Maturity | Production | Development |
| Embedded manifests | Yes (manifestsTemplate) | No |
| Helm schema | Strict (0.20+) | Flexible |
| Single-step deploy | Yes | No (multi-step) |

## Other Addons

- `harvester-csi-driver-lvm` - LVM-based local storage CSI driver
- `harvester-vm-dhcp-controller` - Managed DHCP for Harvester VMs

## Key Versions

- vCluster: v0.30.0
- k3k: v0.2.1 (requires `--devel` flag)
- Rancher: v2.13.0
- K3s: v1.31.4-k3s1
- cert-manager: v1.17.1
