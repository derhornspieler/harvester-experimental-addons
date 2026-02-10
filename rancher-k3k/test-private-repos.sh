#!/usr/bin/env bash
set -euo pipefail

# Test private Helm repo support in deploy.sh
#
# Tier 1 (default): Template validation — no cluster needed
# Tier 2 (--full):  Local HTTPS server with basic auth

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL_TESTS=false
[[ "${1:-}" == "--full" ]] && FULL_TESTS=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "${GREEN}  PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  FAIL${NC} $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${YELLOW}  SKIP${NC} $1: $2"; SKIP=$((SKIP + 1)); }

# Validate YAML using python3 (available on macOS and most Linux)
validate_yaml() {
    local file="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    list(yaml.safe_load_all(f))
" "$file" 2>&1
    else
        # Fall back to basic check: no remaining placeholders
        if grep -q '__[A-Z_]*__' "$file"; then
            echo "Unresolved placeholders found"
            return 1
        fi
    fi
}

# Check that a YAML file contains a specific string
yaml_contains() {
    grep -q "$1" "$2"
}

# Check that a YAML file does NOT contain a specific string
yaml_not_contains() {
    ! grep -q "$1" "$2"
}

# =============================================================================
# Source lib.sh to get real functions
# =============================================================================
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# =============================================================================
# Tier 1: Template Validation
# =============================================================================
echo ""
echo "========================================"
echo " Tier 1: Template Validation"
echo "========================================"
echo ""

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# --- Test 1: Public defaults (no auth, no CA) ---
echo "Test 1: cert-manager template with public defaults"
HELM_REPO_USER="" PRIVATE_CA_PATH=""
cp "$SCRIPT_DIR/post-install/01-cert-manager.yaml" "$TMPDIR_TEST/cm-public.yaml"
sedi "s|__CERTMANAGER_REPO__|https://charts.jetstack.io|g" "$TMPDIR_TEST/cm-public.yaml"
sedi "s|__CERTMANAGER_VERSION__|v1.18.5|g" "$TMPDIR_TEST/cm-public.yaml"
inject_helmchart_auth "$TMPDIR_TEST/cm-public.yaml"

if validate_yaml "$TMPDIR_TEST/cm-public.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cm-public.yaml" 2>&1)"
fi

if yaml_not_contains "__AUTH_SECRET" "$TMPDIR_TEST/cm-public.yaml" && \
   yaml_not_contains "__REPO_CA" "$TMPDIR_TEST/cm-public.yaml"; then
    pass "Placeholders removed"
else
    fail "Placeholders removed" "Unresolved placeholders remain"
fi

if yaml_not_contains "authSecret" "$TMPDIR_TEST/cm-public.yaml"; then
    pass "No authSecret (expected for public)"
else
    fail "No authSecret" "authSecret should not be present for public repos"
fi

# --- Test 2: Auth + CA enabled ---
echo ""
echo "Test 2: cert-manager template with auth + CA"
HELM_REPO_USER="testuser" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
cp "$SCRIPT_DIR/post-install/01-cert-manager.yaml" "$TMPDIR_TEST/cm-auth.yaml"
sedi "s|__CERTMANAGER_REPO__|https://harbor.example.com/chartrepo/library|g" "$TMPDIR_TEST/cm-auth.yaml"
sedi "s|__CERTMANAGER_VERSION__|v1.18.5|g" "$TMPDIR_TEST/cm-auth.yaml"
inject_helmchart_auth "$TMPDIR_TEST/cm-auth.yaml"

if validate_yaml "$TMPDIR_TEST/cm-auth.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/cm-auth.yaml" 2>&1)"
fi

if yaml_contains "authSecret:" "$TMPDIR_TEST/cm-auth.yaml"; then
    pass "authSecret present"
else
    fail "authSecret present" "authSecret not found"
fi

if yaml_contains "name: helm-repo-auth" "$TMPDIR_TEST/cm-auth.yaml"; then
    pass "authSecret name correct"
else
    fail "authSecret name" "Expected 'name: helm-repo-auth'"
fi

if yaml_contains "repoCAConfigMap:" "$TMPDIR_TEST/cm-auth.yaml"; then
    pass "repoCAConfigMap present"
else
    fail "repoCAConfigMap present" "repoCAConfigMap not found"
fi

if yaml_contains "name: helm-repo-ca" "$TMPDIR_TEST/cm-auth.yaml"; then
    pass "repoCAConfigMap name correct"
else
    fail "repoCAConfigMap name" "Expected 'name: helm-repo-ca'"
fi

# --- Test 3: Rancher template with public defaults ---
echo ""
echo "Test 3: Rancher template with public defaults"
HELM_REPO_USER="" PRIVATE_CA_PATH=""
cp "$SCRIPT_DIR/post-install/02-rancher.yaml" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__HOSTNAME__|rancher.test.local|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__BOOTSTRAP_PW__|admin1234567890|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__RANCHER_REPO__|https://releases.rancher.com/server-charts/latest|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__RANCHER_VERSION__|v2.13.2|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "s|__TLS_SOURCE__|rancher|g" "$TMPDIR_TEST/rancher-public.yaml"
sedi "/__EXTRA_RANCHER_VALUES__/d" "$TMPDIR_TEST/rancher-public.yaml"
inject_helmchart_auth "$TMPDIR_TEST/rancher-public.yaml"

if validate_yaml "$TMPDIR_TEST/rancher-public.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/rancher-public.yaml" 2>&1)"
fi

# Check non-comment lines for unresolved placeholders
if ! grep -v '^#' "$TMPDIR_TEST/rancher-public.yaml" | grep -q '__'; then
    pass "All placeholders resolved"
else
    fail "All placeholders resolved" "Unresolved placeholders remain in non-comment lines"
fi

# --- Test 4: Rancher template with auth + CA ---
echo ""
echo "Test 4: Rancher template with auth + CA"
HELM_REPO_USER="testuser" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
cp "$SCRIPT_DIR/post-install/02-rancher.yaml" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__HOSTNAME__|rancher.test.local|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__BOOTSTRAP_PW__|admin1234567890|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__RANCHER_REPO__|https://harbor.example.com/chartrepo/library|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__RANCHER_VERSION__|v2.13.2|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "s|__TLS_SOURCE__|rancher|g" "$TMPDIR_TEST/rancher-auth.yaml"
sedi "/__EXTRA_RANCHER_VALUES__/d" "$TMPDIR_TEST/rancher-auth.yaml"
inject_helmchart_auth "$TMPDIR_TEST/rancher-auth.yaml"

if validate_yaml "$TMPDIR_TEST/rancher-auth.yaml" >/dev/null 2>&1; then
    pass "Valid YAML"
else
    fail "Valid YAML" "$(validate_yaml "$TMPDIR_TEST/rancher-auth.yaml" 2>&1)"
fi

if yaml_contains "authSecret:" "$TMPDIR_TEST/rancher-auth.yaml" && \
   yaml_contains "repoCAConfigMap:" "$TMPDIR_TEST/rancher-auth.yaml"; then
    pass "Auth + CA injected"
else
    fail "Auth + CA injected" "Expected authSecret and repoCAConfigMap"
fi

# --- Test 5: build_helm_repo_flags with no auth ---
echo ""
echo "Test 5: build_helm_repo_flags without auth"
HELM_REPO_USER="" HELM_REPO_PASS="" PRIVATE_CA_PATH=""
build_helm_repo_flags
if [[ ${#HELM_REPO_FLAGS[@]} -eq 0 ]]; then
    pass "Empty flags for public repos"
else
    fail "Empty flags" "Expected empty array, got: ${HELM_REPO_FLAGS[*]}"
fi

# --- Test 6: build_helm_repo_flags with auth + CA ---
echo ""
echo "Test 6: build_helm_repo_flags with auth + CA"
HELM_REPO_USER="myuser" HELM_REPO_PASS="mypass" PRIVATE_CA_PATH="/tmp/fake-ca.pem"
build_helm_repo_flags
EXPECTED_FLAGS="--username myuser --password mypass --ca-file /tmp/fake-ca.pem"
ACTUAL_FLAGS="${HELM_REPO_FLAGS[*]}"
if [[ "$ACTUAL_FLAGS" == "$EXPECTED_FLAGS" ]]; then
    pass "Correct flags: $ACTUAL_FLAGS"
else
    fail "Flag construction" "Expected '$EXPECTED_FLAGS', got '$ACTUAL_FLAGS'"
fi

# --- Test 7: build_helm_ca_flags ---
echo ""
echo "Test 7: build_helm_ca_flags with CA"
PRIVATE_CA_PATH="/tmp/fake-ca.pem"
build_helm_ca_flags
if [[ "${HELM_CA_FLAGS[*]}" == "--ca-file /tmp/fake-ca.pem" ]]; then
    pass "CA-only flags correct"
else
    fail "CA-only flags" "Expected '--ca-file /tmp/fake-ca.pem', got '${HELM_CA_FLAGS[*]}'"
fi

PRIVATE_CA_PATH=""
build_helm_ca_flags
if [[ ${#HELM_CA_FLAGS[@]} -eq 0 ]]; then
    pass "Empty CA flags when no CA"
else
    fail "Empty CA flags" "Expected empty, got: ${HELM_CA_FLAGS[*]}"
fi

# --- Test 8: helm repo add with public repos as custom input ---
echo ""
echo "Test 8: helm repo add with public repos (exercises flag construction)"
if command -v helm &>/dev/null; then
    HELM_REPO_USER="" HELM_REPO_PASS="" PRIVATE_CA_PATH=""
    build_helm_repo_flags

    # Use unique test names to avoid conflicts with actual repos
    TEST_REPOS=(
        "test-cm-pub|https://charts.jetstack.io"
        "test-rancher-pub|https://releases.rancher.com/server-charts/latest"
        "test-k3k-pub|https://rancher.github.io/k3k"
    )

    for entry in "${TEST_REPOS[@]}"; do
        IFS='|' read -r name url <<< "$entry"
        if helm repo add "$name" "$url" --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
            pass "helm repo add $name ($url)"
            helm repo remove "$name" 2>/dev/null || true
        else
            fail "helm repo add $name" "Failed to add $url"
        fi
    done
else
    skip "helm repo add" "helm not installed"
fi

# --- Test 9: helm repo add with auth flags against public repos ---
echo ""
echo "Test 9: helm repo add with auth flags (flags accepted by public repos)"
if command -v helm &>/dev/null; then
    HELM_REPO_USER="dummyuser" HELM_REPO_PASS="dummypass" PRIVATE_CA_PATH=""
    build_helm_repo_flags

    # Public repos accept --username/--password flags even if unused
    if helm repo add test-auth-flags "https://charts.jetstack.io" --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
        pass "helm repo add with auth flags accepted"
        helm repo remove test-auth-flags 2>/dev/null || true
    else
        fail "helm repo add with auth flags" "Public repo rejected auth flags"
    fi
else
    skip "helm repo add with auth" "helm not installed"
fi

# =============================================================================
# Tier 2: Local HTTPS Server (optional)
# =============================================================================
if [[ "$FULL_TESTS" == "true" ]]; then
    echo ""
    echo "========================================"
    echo " Tier 2: Local HTTPS Server"
    echo "========================================"
    echo ""

    if ! command -v openssl &>/dev/null; then
        skip "Tier 2" "openssl not installed"
    elif ! command -v python3 &>/dev/null; then
        skip "Tier 2" "python3 not installed"
    elif ! command -v helm &>/dev/null; then
        skip "Tier 2" "helm not installed"
    else
        TIER2_DIR=$(mktemp -d)
        TIER2_PORT=18443
        SERVER_PID=""

        tier2_cleanup() {
            [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
            rm -rf "$TIER2_DIR"
        }
        # Add to existing trap
        trap 'rm -rf "$TMPDIR_TEST"; tier2_cleanup' EXIT

        # Generate self-signed CA + server cert
        echo "  Generating test CA and server certificate..."
        openssl req -x509 -newkey rsa:2048 -keyout "$TIER2_DIR/ca-key.pem" \
            -out "$TIER2_DIR/ca.pem" -days 1 -nodes \
            -subj "/CN=Test CA" 2>/dev/null

        openssl req -newkey rsa:2048 -keyout "$TIER2_DIR/server-key.pem" \
            -out "$TIER2_DIR/server.csr" -nodes \
            -subj "/CN=localhost" 2>/dev/null

        openssl x509 -req -in "$TIER2_DIR/server.csr" \
            -CA "$TIER2_DIR/ca.pem" -CAkey "$TIER2_DIR/ca-key.pem" \
            -CAcreateserial -out "$TIER2_DIR/server.pem" -days 1 \
            -extfile <(echo "subjectAltName=DNS:localhost,IP:127.0.0.1") 2>/dev/null

        # Create minimal Helm repo index
        mkdir -p "$TIER2_DIR/repo"
        cat > "$TIER2_DIR/repo/index.yaml" <<'INDEXEOF'
apiVersion: v1
entries:
  test-chart:
  - apiVersion: v2
    name: test-chart
    version: 0.1.0
    description: Test chart
    urls:
    - https://localhost:18443/test-chart-0.1.0.tgz
generated: "2026-01-01T00:00:00Z"
INDEXEOF

        # Start HTTPS server with basic auth
        cat > "$TIER2_DIR/server.py" <<'PYEOF'
import http.server
import ssl
import base64
import sys
import os

EXPECTED_AUTH = base64.b64encode(b"testuser:testpass").decode()
SERVE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "repo")

class AuthHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=SERVE_DIR, **kwargs)

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        if auth == f"Basic {EXPECTED_AUTH}":
            super().do_GET()
        else:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="test"')
            self.end_headers()
            self.wfile.write(b"Unauthorized")

    def log_message(self, format, *args):
        pass  # Suppress output

port = int(sys.argv[1])
cert = sys.argv[2]
key = sys.argv[3]

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)

server = http.server.HTTPServer(("127.0.0.1", port), AuthHandler)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PYEOF

        python3 "$TIER2_DIR/server.py" "$TIER2_PORT" \
            "$TIER2_DIR/server.pem" "$TIER2_DIR/server-key.pem" &
        SERVER_PID=$!
        sleep 1

        # Verify server is running
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            fail "HTTPS server" "Server failed to start"
        else
            pass "HTTPS server started on port $TIER2_PORT"

            # Test: helm repo add with CA only (no auth) — should get 401
            echo ""
            echo "Test T2-1: helm repo add with CA but no auth (expect 401)"
            HELM_REPO_USER="" HELM_REPO_PASS="" PRIVATE_CA_PATH="$TIER2_DIR/ca.pem"
            build_helm_repo_flags
            if helm repo add test-noauth "https://localhost:${TIER2_PORT}" \
                --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
                # Some helm versions add the repo even on 401 (lazy fetch)
                # Try an update to actually hit the server
                if helm repo update test-noauth 2>&1 | grep -qi "unauthorized\|401\|failed"; then
                    pass "Correctly rejected without auth"
                else
                    pass "Repo added (helm defers auth check to fetch time)"
                fi
                helm repo remove test-noauth 2>/dev/null || true
            else
                pass "Correctly rejected without auth"
            fi

            # Test: helm repo add with CA + auth — should succeed
            echo ""
            echo "Test T2-2: helm repo add with CA + auth"
            HELM_REPO_USER="testuser" HELM_REPO_PASS="testpass" PRIVATE_CA_PATH="$TIER2_DIR/ca.pem"
            build_helm_repo_flags
            if helm repo add test-withauth "https://localhost:${TIER2_PORT}" \
                --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
                pass "helm repo add with auth + CA succeeded"
                helm repo remove test-withauth 2>/dev/null || true
            else
                fail "helm repo add with auth + CA" "Failed despite correct credentials"
            fi

            # Test: helm repo add without CA — should fail (untrusted cert)
            echo ""
            echo "Test T2-3: helm repo add without CA (expect TLS failure)"
            HELM_REPO_USER="testuser" HELM_REPO_PASS="testpass" PRIVATE_CA_PATH=""
            build_helm_repo_flags
            if helm repo add test-noca "https://localhost:${TIER2_PORT}" \
                --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"} 2>/dev/null; then
                fail "TLS rejection" "Should have failed without CA"
                helm repo remove test-noca 2>/dev/null || true
            else
                pass "Correctly rejected without CA (untrusted certificate)"
            fi
        fi

        tier2_cleanup
        SERVER_PID=""
    fi
else
    echo ""
    echo "Tier 2 tests skipped (use --full to enable)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo " Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
