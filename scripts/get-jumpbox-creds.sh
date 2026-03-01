#!/usr/bin/env bash
# =============================================================================
# get-jumpbox-creds.sh
#
# Initialises Terraform (phase1/core) and prints the jumpbox connection info:
#   - Public IP
#   - Admin username
#   - Admin password
#
# Usage:
#   bash scripts/get-jumpbox-creds.sh
#
# Prerequisites:
#   - Authenticated Azure CLI session (az login)
#   - Terraform >= 1.7
# =============================================================================

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BOLD='\033[1m'
RST='\033[0m'

info()    { echo -e "${BLU}[INFO]${RST}  $*"; }
success() { echo -e "${GRN}[OK]${RST}    $*"; }
error()   { echo -e "${RED}[ERROR]${RST} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYN}══ $* ══${RST}"; }

die() { error "$*"; exit 1; }

# ─── Dependency checks ───────────────────────────────────────────────────────
for cmd in az terraform; do
  command -v "$cmd" &>/dev/null || die "Missing required tool: $cmd"
done

# ─── Derive backend config from the active subscription ─────────────────────
header "Resolving backend configuration"

SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null) \
  || die "No active Azure CLI session. Run: az login"

DEPLOY_RG="rg-core-deploy"
SUB_SUFFIX=$(echo "$SUBSCRIPTION_ID" | tr -d '-' | cut -c1-8)
SA_NAME="tfstate${SUB_SUFFIX}"
CONTAINER="tfstate"
STATE_KEY="phase1-core.tfstate"

info "Resource group:  ${DEPLOY_RG}"
info "Storage account: ${SA_NAME}"
info "Container:       ${CONTAINER}"
info "State key:       ${STATE_KEY}"

# ─── Terraform init ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${SCRIPT_DIR}/../terraform/phase1/core"

header "Initialising Terraform (phase1/core)"

terraform -chdir="$CORE_DIR" init -input=false \
  -backend-config="resource_group_name=${DEPLOY_RG}" \
  -backend-config="storage_account_name=${SA_NAME}" \
  -backend-config="container_name=${CONTAINER}" \
  -backend-config="key=${STATE_KEY}" \
  > /dev/null

success "Terraform initialised"

# ─── Retrieve jumpbox credentials ────────────────────────────────────────────
header "Jumpbox credentials"

PUBLIC_IP=$(terraform -chdir="$CORE_DIR" output -raw jumpbox_public_ip)
USERNAME=$(terraform  -chdir="$CORE_DIR" output -raw jumpbox_admin_username)
PASSWORD=$(terraform  -chdir="$CORE_DIR" output -raw jumpbox_admin_password)

echo ""
echo -e "  ${BOLD}Public IP :${RST}  ${PUBLIC_IP}"
echo -e "  ${BOLD}Username  :${RST}  ${USERNAME}"
echo -e "  ${BOLD}Password  :${RST}  ${PASSWORD}"
echo ""
info "RDP to ${PUBLIC_IP} with the credentials above."
