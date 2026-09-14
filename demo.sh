#!/usr/bin/env bash
# =============================================================================
# demo.sh — 5-minute VSO integration demo
#
# Proves: HCP Vault → VSO → K8s Secrets with exact key names the AAP operator expects
#
# Prerequisites:
#   - oc logged in to ROSA cluster
#   - VAULT_TOKEN set (fresh HCP Vault token)
#
# Usage:
#   export VAULT_TOKEN=<your-token>
#   ./demo.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $*"; }
info() { echo -e "${CYAN}→${RESET} $*"; }
step() { echo -e "\n${BOLD}[$1/4] $2${RESET}"; }

VAULT_ADDR="${VAULT_ADDR:-https://cloud-content-public-vault-1b6418b7.43bfda60.z1.hashicorp.cloud:8200}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"
VAULT_TOKEN="${VAULT_TOKEN:?Set VAULT_TOKEN before running}"
VAULT_MOUNT="${VAULT_MOUNT:-secret}"
CLUSTER_NAME="${CLUSTER_NAME:-rosa-cnet-01}"
AAP_NS="ansible-automation-platform"

export VAULT_ADDR VAULT_NAMESPACE VAULT_TOKEN

echo ""
echo -e "${BOLD}AAP + VSO Integration Demo${RESET}"
echo "Vault:   $VAULT_ADDR"
echo "Cluster: $CLUSTER_NAME"
echo "OCP:     $(oc whoami --show-server 2>/dev/null || echo 'not logged in')"
echo ""

# ── Step 1: Verify OCP login ──────────────────────────────────────────────────
step 1 "Verify OCP + VSO"

oc whoami > /dev/null || { echo -e "${RED}Not logged into OCP. Run: oc login ...${RESET}"; exit 1; }
ok "OCP: $(oc whoami) → $(oc whoami --show-server)"

VSO_POD=$(oc get pods -n vault-secrets-operator-system \
  -l control-plane=controller-manager --no-headers 2>/dev/null | awk '{print $1}' | head -1)
if [[ -n "$VSO_POD" ]]; then
  ok "VSO operator: $VSO_POD"
else
  echo -e "${RED}VSO not found. Deploy it first.${RESET}"; exit 1
fi

# ── Step 2: Seed Vault ────────────────────────────────────────────────────────
step 2 "Seed HCP Vault with AAP secrets"

vault status -format=json | python3 -c "import json,sys; s=json.load(sys.stdin); print(f'Vault sealed: {s[\"sealed\"]}')" 2>/dev/null \
  || { echo -e "${RED}Cannot reach Vault at $VAULT_ADDR${RESET}"; exit 1; }
ok "Vault reachable"

# Admin passwords
vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/credentials/aap" - <<'EOF'
{"data": {"controller_admin_password": "DemoCtrl@123", "hub_admin_password": "DemoHub@123", "platform_admin_password": "DemoPlat@123", "eda_admin_password": "DemoEda@123"}}
EOF
ok "Stored: credentials/aap (admin passwords)"

# Controller internal secrets — exact key names from operator templates:
#   secret_key.yaml.j2 → key: 'secret_key'
#   broadcast_websocket_secret.yaml.j2 → key: 'secret'
vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/secrets/controller" - <<'EOF'
{"data": {"secret_key": "DemoSecretKeyFor32CharsExact1234", "broadcast_websocket_secret": "DemoBroadcastFor32CharsExact123"}}
EOF
ok "Stored: secrets/controller (secret_key + broadcast_websocket)"

# Hub db_fields_encryption — key: 'database_fields.symmetric.key' (Fernet format)
HUB_FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null \
  || openssl rand -base64 32 | tr -d '\n')
vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/encryption/hub" - \
  <<< "{\"data\": {\"database_fields_encryption_key\": \"${HUB_FERNET}\"}}"
ok "Stored: encryption/hub (Fernet key)"

EDA_FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null \
  || openssl rand -base64 32 | tr -d '\n')
vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/encryption/eda" - \
  <<< "{\"data\": {\"database_fields_encryption_key\": \"${EDA_FERNET}\"}}"
ok "Stored: encryption/eda (Fernet key)"

# ── Step 3: Apply VaultStaticSecrets ─────────────────────────────────────────
step 3 "Apply Kustomize (VaultStaticSecrets → K8s Secrets)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

oc create namespace "$AAP_NS" --dry-run=client -o yaml | oc apply -f - 2>/dev/null
oc create namespace vault-secrets-operator-system --dry-run=client -o yaml | oc apply -f - 2>/dev/null

oc kustomize "${SCRIPT_DIR}/overlays/non-saas" | oc apply -f -
ok "Applied $(oc get vaultstaticsecret -n $AAP_NS --no-headers 2>/dev/null | wc -l | tr -d ' ') VaultStaticSecrets"

# ── Step 4: Verify ────────────────────────────────────────────────────────────
step 4 "Verify secrets synced with correct key names"

info "Waiting up to 60s for VSO to sync secrets..."
ELAPSED=0
while [[ $ELAPSED -lt 60 ]]; do
  SYNCED=$(oc get vaultstaticsecret -n "$AAP_NS" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="SecretSynced")].status}' 2>/dev/null | \
    tr ' ' '\n' | grep -c "True" || true)
  TOTAL=$(oc get vaultstaticsecret -n "$AAP_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  info "  Synced: ${SYNCED}/${TOTAL}"
  [[ "$SYNCED" -ge "$TOTAL" && "$TOTAL" -gt 0 ]] && break
  sleep 10; ELAPSED=$((ELAPSED+10))
done

echo ""
echo -e "${BOLD}Secret key name verification (must match AAP operator templates):${RESET}"
echo ""

# Verify each secret has the exact key name the operator expects
check_key() {
  local secret="$1" key="$2" label="$3"
  local val
  val=$(oc get secret "$secret" -n "$AAP_NS" \
    -o jsonpath="{.data['${key//./\\.}']}" 2>/dev/null | base64 -d 2>/dev/null | head -c 20)
  if [[ -n "$val" ]]; then
    ok "$label — key '$key': ${val}..."
  else
    echo -e "${RED}✗ $label — key '$key' NOT FOUND${RESET}"
  fi
}

check_key "automation-controller-secret-key"           "secret_key"                    "Controller SECRET_KEY"
check_key "automation-controller-broadcast-websocket"  "secret"                        "Broadcast websocket"
check_key "automation-controller-admin-password"       "password"                      "Controller admin password"
check_key "automation-hub-admin-password"              "password"                      "Hub admin password"
check_key "automation-platform-admin-password"         "password"                      "Platform admin password"
check_key "automation-hub-db-fields-encryption"        "database_fields.symmetric.key" "Hub db_fields encryption"
check_key "automation-eda-db-fields-encryption"        "database_fields.symmetric.key" "EDA db_fields encryption"

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Demo complete — HCP Vault → VSO → K8s Secrets ✓${RESET}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════${RESET}"
echo ""
echo "  These secrets are pre-created with EXACT key names the AAP operator"
echo "  reads from its Jinja2 templates. Set the CR fields in"
echo "  aap-cr/automation-platform.yaml and deploy AAP — the operator"
echo "  will use these secrets instead of auto-generating them."
echo ""
echo -e "  ${CYAN}Next: deploy AAP with the CR fields set${RESET}"
echo "  oc kustomize aap-cr | oc apply -f -"
echo ""
