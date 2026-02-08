# experimental-addons

[![Built with Claude Code](https://img.shields.io/badge/Built%20with-Claude%20Code-blue?logo=anthropic)](https://claude.ai/code)

Experimental addons for [Harvester HCI](https://github.com/harvester/harvester) — additional Kubernetes resources not directly packaged in Harvester.

> **Warning**: These addons should not be used in a production environment.

## Addons

### Rancher Virtual Clusters

Two methods to deploy Rancher management server as a virtual cluster on Harvester:

| | [rancher-vcluster](rancher-vcluster/) | [rancher-k3k](rancher-k3k/) |
|---|---|---|
| Technology | [vCluster](https://github.com/loft-sh/vcluster) (Loft Labs) | [k3k](https://github.com/rancher/k3k) (Rancher) |
| Maturity | Production | Development |
| Embedded manifests | Yes (`manifestsTemplate`) | No (multi-step post-install) |
| Helm schema | Strict (`additionalProperties: false`) | Flexible |
| Single-step deploy | Yes | No |
| Harvester requirement | v1.7.0+ | v1.6.x+ |

### Other Addons

- [`harvester-csi-driver-lvm`](harvester-csi-driver-lvm/) — LVM-based local storage CSI driver ([docs](https://docs.harvesterhci.io/latest/advanced/addons/lvm-local-storage))
- [`harvester-vm-dhcp-controller`](harvester-vm-dhcp-controller/) — Managed DHCP for Harvester VMs ([docs](https://docs.harvesterhci.io/latest/advanced/addons/managed-dhcp))

## Quick Start

### Interactive deploy script

```bash
./deploy.sh
```

Prompts you to choose between vCluster and k3k, then guides you through configuration.

### Manual deployment

See individual addon READMEs:
- [rancher-vcluster/README.md](rancher-vcluster/README.md)
- [rancher-k3k/README.md](rancher-k3k/README.md)
