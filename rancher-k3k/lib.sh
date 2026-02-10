#!/usr/bin/env bash
# Shared functions for rancher-k3k deploy scripts
#
# Functions:
#   sedi                  - Cross-platform sed -i
#   build_helm_repo_flags - Populate HELM_REPO_FLAGS array
#   build_helm_ca_flags   - Populate HELM_CA_FLAGS array
#   inject_helmchart_auth - Replace auth/CA placeholders in HelmChart CRs
#   build_registries_yaml - Generate K3s registries.yaml for Harbor proxy caches
#   inject_secret_mounts  - Replace secretMounts/serverArgs placeholders in Cluster CR

# Cross-platform sed -i
sedi() {
    if sed --version &>/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# Build Helm repo flags for authentication and CA.
# Sets HELM_REPO_FLAGS array (--username, --password, --ca-file as needed).
# Reads: HELM_REPO_USER, HELM_REPO_PASS, PRIVATE_CA_PATH
build_helm_repo_flags() {
    HELM_REPO_FLAGS=()
    if [[ -n "${HELM_REPO_USER:-}" && -n "${HELM_REPO_PASS:-}" ]]; then
        HELM_REPO_FLAGS+=(--username "$HELM_REPO_USER" --password "$HELM_REPO_PASS")
    fi
    if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
        HELM_REPO_FLAGS+=(--ca-file "$PRIVATE_CA_PATH")
    fi
}

# Build Helm CA flags only (for install/upgrade commands that don't take --username/--password).
# Sets HELM_CA_FLAGS array.
# Reads: PRIVATE_CA_PATH
build_helm_ca_flags() {
    HELM_CA_FLAGS=()
    if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
        HELM_CA_FLAGS+=(--ca-file "$PRIVATE_CA_PATH")
    fi
}

# Replace auth/CA placeholders in a HelmChart CR manifest file.
# If HELM_REPO_USER is set, injects authSecret lines; otherwise removes placeholders.
# If PRIVATE_CA_PATH is set, injects repoCAConfigMap lines; otherwise removes placeholders.
#
# Usage: inject_helmchart_auth <manifest-file>
# Reads: HELM_REPO_USER, PRIVATE_CA_PATH
inject_helmchart_auth() {
    local file="$1"

    if [[ -n "${HELM_REPO_USER:-}" ]]; then
        sedi "s|^__AUTH_SECRET_LINE1__$|  authSecret:|" "$file"
        sedi "s|^__AUTH_SECRET_LINE2__$|    name: helm-repo-auth|" "$file"
    else
        sedi "/__AUTH_SECRET_LINE1__/d" "$file"
        sedi "/__AUTH_SECRET_LINE2__/d" "$file"
    fi

    if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
        sedi "s|^__REPO_CA_LINE1__$|  repoCAConfigMap:|" "$file"
        sedi "s|^__REPO_CA_LINE2__$|    name: helm-repo-ca|" "$file"
    else
        sedi "/__REPO_CA_LINE1__/d" "$file"
        sedi "/__REPO_CA_LINE2__/d" "$file"
    fi
}

# Upstream registries that the Rancher-on-k3k stack pulls from.
# Each needs a corresponding proxy cache project in Harbor.
#   docker.io  - K3s system images, Rancher, Fleet
#   quay.io    - cert-manager (jetstack)
#   ghcr.io    - CloudNativePG, Zalando postgres-operator
MIRROR_REGISTRIES=("docker.io" "quay.io" "ghcr.io")

# Generate a K3s registries.yaml with mirror entries for all upstream registries.
# Writes the YAML to the file path given as the first argument.
#
# PRIVATE_REGISTRY is the registry host (e.g. harbor.tiger.net).
# Mirror entries are generated for each registry in MIRROR_REGISTRIES.
# Each mirror uses a rewrite rule that maps image paths through the
# Harbor proxy cache project named after the upstream registry:
#   docker.io/rancher/k3s:v1.34 → harbor.tiger.net/docker.io/rancher/k3s:v1.34
#   quay.io/jetstack/cert-manager-controller:v1.18 → harbor.tiger.net/quay.io/jetstack/cert-manager-controller:v1.18
#
# Usage: build_registries_yaml <output-file>
# Reads: PRIVATE_REGISTRY, PRIVATE_CA_PATH, HELM_REPO_USER, HELM_REPO_PASS
build_registries_yaml() {
    local outfile="$1"
    local reg_host="${PRIVATE_REGISTRY:-}"

    if [[ -z "$reg_host" ]]; then
        return 1
    fi

    # Generate mirror entries for each upstream registry
    cat > "$outfile" <<REGEOF
mirrors:
REGEOF

    for upstream in "${MIRROR_REGISTRIES[@]}"; do
        cat >> "$outfile" <<REGEOF
  ${upstream}:
    endpoint:
      - "https://${reg_host}"
    rewrite:
      "^(.*)$": "${upstream}/\$1"
REGEOF
    done

    # Add configs section for TLS and/or auth (single entry for the Harbor host)
    if [[ -n "${PRIVATE_CA_PATH:-}" || -n "${HELM_REPO_USER:-}" ]]; then
        cat >> "$outfile" <<REGEOF
configs:
  "${reg_host}":
REGEOF

        if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
            cat >> "$outfile" <<REGEOF
    tls:
      ca_file: /etc/rancher/k3s/tls/ca.crt
REGEOF
        fi

        if [[ -n "${HELM_REPO_USER:-}" ]]; then
            cat >> "$outfile" <<REGEOF
    auth:
      username: "${HELM_REPO_USER}"
      password: "${HELM_REPO_PASS}"
REGEOF
        fi
    fi
}

# Replace secretMounts and extra serverArgs placeholders in a Cluster CR manifest.
# If PRIVATE_REGISTRY is set, injects secretMounts for registries.yaml (and optionally CA).
# If PRIVATE_REGISTRY is set, injects --system-default-registry serverArg.
# Otherwise removes the placeholders.
#
# Usage: inject_secret_mounts <manifest-file>
# Reads: PRIVATE_REGISTRY, PRIVATE_CA_PATH
inject_secret_mounts() {
    local file="$1"

    if [[ -n "${PRIVATE_REGISTRY:-}" ]]; then
        # Build the secretMounts block in a temp file
        local mounts_file
        mounts_file=$(mktemp)
        {
            echo "  secretMounts:"
            echo "    - secretName: k3s-registry-config"
            echo "      mountPath: /etc/rancher/k3s/registries.yaml"
            echo "      subPath: registries.yaml"
            if [[ -n "${PRIVATE_CA_PATH:-}" ]]; then
                echo "    - secretName: k3s-registry-ca"
                echo "      mountPath: /etc/rancher/k3s/tls/ca.crt"
                echo "      subPath: ca.crt"
            fi
        } > "$mounts_file"

        # Replace __SECRET_MOUNTS__ with the contents of mounts_file
        # Use line-by-line approach for macOS/Linux portability
        local tmpfile
        tmpfile=$(mktemp)
        while IFS= read -r line; do
            if [[ "$line" == *"__SECRET_MOUNTS__"* ]]; then
                cat "$mounts_file"
            else
                printf '%s\n' "$line"
            fi
        done < "$file" > "$tmpfile"
        mv "$tmpfile" "$file"
        rm -f "$mounts_file"

        # Inject --system-default-registry serverArg (K3s system images are all on docker.io)
        sedi "s|^__EXTRA_SERVER_ARGS__$|    - \"--system-default-registry=${PRIVATE_REGISTRY}/docker.io\"|" "$file"
    else
        sedi "/__SECRET_MOUNTS__/d" "$file"
        sedi "/__EXTRA_SERVER_ARGS__/d" "$file"
    fi
}
