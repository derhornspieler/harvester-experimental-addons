#!/usr/bin/env bash
# Shared functions for rancher-k3k deploy scripts

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
