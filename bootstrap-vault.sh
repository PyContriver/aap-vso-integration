#!/usr/bin/env bash
# =============================================================================
# bootstrap-vault.sh — Seed HCP Vault with all secrets required for full
#                       AAP + VSO integration.
#
# Secret key names are sourced directly from the operator templates:
#   awx-operator/roles/installer/templates/secrets/
#   galaxy-operator/roles/common/templates/
#   eda-server-operator/roles/eda/
#
# Usage:
#   export VAULT_ADDR=https://your-vault.example.com:8200
#   export VAULT_NAMESPACE=admin   # HCP Vault
#   export VAULT_TOKEN=<token>
#   export CLUSTER_NAME=rosa-cnet-01
#   ./bootstrap-vault.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}─── $* ${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config.env if present
if [[ -f "$SCRIPT_DIR/overlays/non-saas/config.env" ]]; then
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"
    [[ -n "$v" ]] && export "$k=$v"
  done < <(grep -v '^\s*#' "$SCRIPT_DIR/overlays/non-saas/config.env" | grep -v '^\s*$')
fi

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME not set}"
VAULT_MOUNT="${VAULT_MOUNT:-secret}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR not set}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN not set}"

echo ""
echo -e "${BOLD}AAP VSO Vault Bootstrap${RESET}"
echo "Vault: $VAULT_ADDR"
echo "Cluster: $CLUSTER_NAME"
echo "Mount: $VAULT_MOUNT"
echo ""

# ── Helper ────────────────────────────────────────────────────────────────────
vault_write() {
  local path="$1"; shift
  vault write "${VAULT_MOUNT}/data/${path}" - <<< "$@"
}

prompt_or_generate() {
  local varname="$1" desc="$2" length="${3:-32}"
  if [[ -z "${!varname:-}" ]]; then
    read -rsp "$desc (press Enter to auto-generate): " val; echo
    if [[ -z "$val" ]]; then
      val=$(openssl rand -base64 "$length" | tr -d '=/+' | head -c "$length")
      info "Auto-generated $varname"
    fi
    eval "$varname='$val'"
  fi
}

fernet_key() {
  python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null \
    || openssl rand -base64 32
}

# ── Ensure KV v2 engine ───────────────────────────────────────────────────────
step "Checking KV v2 engine at $VAULT_MOUNT/"
if vault secrets list -format=json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if '${VAULT_MOUNT}/' in d else 1)" 2>/dev/null; then
  info "KV v2 engine already mounted at $VAULT_MOUNT/"
else
  vault secrets enable -path="${VAULT_MOUNT}" kv-v2
  success "Enabled KV v2 at $VAULT_MOUNT/"
fi

# ── Prompt for passwords ──────────────────────────────────────────────────────
step "Admin passwords"
prompt_or_generate CTRL_ADMIN_PASS  "Controller admin password"
prompt_or_generate HUB_ADMIN_PASS   "Hub admin password"
prompt_or_generate PLAT_ADMIN_PASS  "Platform admin password"
prompt_or_generate EDA_ADMIN_PASS   "EDA admin password"

step "Controller internal secrets"
prompt_or_generate CTRL_SECRET_KEY       "Controller SECRET_KEY (32 chars)" 32
prompt_or_generate CTRL_WEBSOCKET_SECRET "Broadcast websocket secret (32 chars)" 32

step "Postgres credentials (host must be your running postgres)"
read -rp "Postgres host (e.g. aap-postgres.ansible-automation-platform.svc): " PG_HOST
prompt_or_generate CTRL_PG_PASS "Controller postgres password"
prompt_or_generate HUB_PG_PASS  "Hub postgres password"
prompt_or_generate PLAT_PG_PASS "Platform postgres password"
prompt_or_generate EDA_PG_PASS  "EDA postgres password"

step "Encryption keys (Fernet format)"
info "Generating Fernet keys for db_fields_encryption_secret..."
HUB_FERNET=$(fernet_key)
EDA_FERNET=$(fernet_key)
success "Generated Hub Fernet key"
success "Generated EDA Fernet key"

# ── Write to Vault ────────────────────────────────────────────────────────────
step "Writing secrets to Vault"

# Admin passwords (all in one path)
vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/credentials/aap" - <<EOF
{
  "data": {
    "controller_admin_password": "${CTRL_ADMIN_PASS}",
    "hub_admin_password": "${HUB_ADMIN_PASS}",
    "platform_admin_password": "${PLAT_ADMIN_PASS}",
    "eda_admin_password": "${EDA_ADMIN_PASS}"
  }
}
EOF
success "Stored: aap/${CLUSTER_NAME}/credentials/aap"

# Controller internal secrets
vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/secrets/controller" - <<EOF
{
  "data": {
    "secret_key": "${CTRL_SECRET_KEY}",
    "broadcast_websocket_secret": "${CTRL_WEBSOCKET_SECRET}"
  }
}
EOF
success "Stored: aap/${CLUSTER_NAME}/secrets/controller"

# Postgres credentials
for component in controller hub platform eda; do
  case "$component" in
    controller) PG_PASS="$CTRL_PG_PASS"; DB="automationcontroller"; USER="controller" ;;
    hub)        PG_PASS="$HUB_PG_PASS";  DB="automationhub";        USER="hub"        ;;
    platform)   PG_PASS="$PLAT_PG_PASS"; DB="gateway";              USER="platform"   ;;
    eda)        PG_PASS="$EDA_PG_PASS";  DB="automationeda";        USER="eda"        ;;
  esac

  vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/database/${component}" - <<EOF
{
  "data": {
    "host": "${PG_HOST}",
    "username": "${USER}",
    "password": "${PG_PASS}"
  }
}
EOF
  success "Stored: aap/${CLUSTER_NAME}/database/${component}"
done

# Encryption keys (Fernet)
vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/encryption/hub" - <<EOF
{"data": {"database_fields_encryption_key": "${HUB_FERNET}"}}
EOF
success "Stored: aap/${CLUSTER_NAME}/encryption/hub"

vault write "${VAULT_MOUNT}/data/aap/${CLUSTER_NAME}/encryption/eda" - <<EOF
{"data": {"database_fields_encryption_key": "${EDA_FERNET}"}}
EOF
success "Stored: aap/${CLUSTER_NAME}/encryption/eda"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Vault bootstrap complete!${RESET}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${RESET}"
echo ""
echo "  Paths written:"
echo "  ${VAULT_MOUNT}/aap/${CLUSTER_NAME}/credentials/aap"
echo "  ${VAULT_MOUNT}/aap/${CLUSTER_NAME}/secrets/controller"
echo "  ${VAULT_MOUNT}/aap/${CLUSTER_NAME}/database/{controller,hub,platform,eda}"
echo "  ${VAULT_MOUNT}/aap/${CLUSTER_NAME}/encryption/{hub,eda}"
echo ""
echo -e "  ${CYAN}Next steps:${RESET}"
echo "  1. Apply VSO secrets:  oc kustomize overlays/non-saas | oc apply -f -"
echo "  2. Apply AAP CR:       oc kustomize aap-cr | oc apply -f -"
echo "  3. Monitor:            oc get pods -n ansible-automation-platform -w"
echo ""
