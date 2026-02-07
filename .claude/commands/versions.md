# Check Addon Versions

Extract and display all version information from addon manifests.

## What to check

For each addon YAML file, extract:
- `spec.version` - Helm chart version
- Any image tags in `valuesContent`
- Any embedded chart versions

## Output format

Display a summary table showing:
- Addon name
- Chart version
- Key component versions (K3s, Rancher, vCluster, etc.)
