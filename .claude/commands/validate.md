# Validate Addon YAML

Validate all addon YAML files for syntax errors and Kubernetes schema compliance.

## Steps

1. Find all `.yaml` files in the experimental-addons directory
2. Run `kubectl apply --dry-run=client -f <file>` on each to validate syntax
3. Report any validation errors found
4. Summarize which files are valid

## Command to run

```bash
for f in $(find . -name "*.yaml" -type f); do
  echo "Validating: $f"
  kubectl apply --dry-run=client -f "$f" 2>&1
done
```
