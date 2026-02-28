#!/usr/bin/env bash
# =============================================================================
# prepare-azure-env.sh
#
# Bootstrap script: creates the Azure pre-requisites that must exist before
# Terraform can run for the first time.
#
#   1. Validate an active Azure CLI session.
#   2. Create the deploy resource group (rg-core-deploy) for Terraform state.
#   3. Create a Storage Account + containers (tfstate, tfplans).
#   4. Create an App Registration / Service Principal for GitHub Actions.
#   5. Add OIDC federated credentials for each GitHub Actions environment.
#   6. Assign roles: Owner on subscription + Storage Blob Data Contributor on SA.
#   7. Print the GitHub Actions secrets that need to be configured.
#
# Usage:
#   bash scripts/prepare-azure-env.sh [OPTIONS]
#
# Options:
#   -l, --location      <region>       Azure region (default: uksouth)
#   -s, --subscription  <id>           Subscription ID (default: current)
#   -r, --repo          <owner/repo>   GitHub repository, e.g. myorg/azure-demo
#   -n, --sp-name       <name>         App Registration display name
#                                      (default: sp-azure-demo-github)
#   -g, --rg            <name>         Deploy resource group name
#                                      (default: rg-core-deploy)
#   -h, --help                         Show this help message
#
# Requirements:
#   - Azure CLI >= 2.55 (for federated credential support)
#   - jq
#   - An authenticated Azure CLI session with sufficient privileges
#     (Owner or User Access Administrator on the target subscription)
# =============================================================================

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BOLD='\033[1m'
RST='\033[0m'

info()    { echo -e "${BLU}[INFO]${RST}  $*"; }
success() { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YLW}[WARN]${RST}  $*"; }
error()   { echo -e "${RED}[ERROR]${RST} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYN}══ $* ══${RST}"; }

die() {
  error "$*"
  exit 1
}

# ─── Dependency checks ───────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in az jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
}

# ─── Defaults ────────────────────────────────────────────────────────────────
LOCATION="uksouth"
SUBSCRIPTION_ID=""
GITHUB_REPO=""
SP_NAME="sp-azure-demo-github"
DEPLOY_RG="rg-core-deploy"

# ─── Argument parsing ────────────────────────────────────────────────────────
usage() {
  sed -n '/^# Usage:/,/^# =====/{/^# =====/d; s/^# \?//; p}' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--location)     LOCATION="$2";      shift 2 ;;
    -s|--subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    -r|--repo)         GITHUB_REPO="$2";   shift 2 ;;
    -n|--sp-name)      SP_NAME="$2";       shift 2 ;;
    -g|--rg)           DEPLOY_RG="$2";     shift 2 ;;
    -h|--help)         usage ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ─── Validate Azure CLI session ──────────────────────────────────────────────
validate_az_session() {
  header "Validating Azure CLI session"

  local account
  account=$(az account show 2>/dev/null) \
    || die "No active Azure CLI session. Run: az login"

  local signed_in_user tenant_id sub_id sub_name
  signed_in_user=$(echo "$account" | jq -r '.user.name')
  tenant_id=$(echo "$account"      | jq -r '.tenantId')
  sub_id=$(echo "$account"         | jq -r '.id')
  sub_name=$(echo "$account"       | jq -r '.name')

  success "Signed in as: ${signed_in_user}"
  info    "Tenant ID:    ${tenant_id}"
  info    "Subscription: ${sub_name} (${sub_id})"

  # Use the current subscription if not overridden.
  if [[ -z "$SUBSCRIPTION_ID" ]]; then
    SUBSCRIPTION_ID="$sub_id"
  fi
  TENANT_ID="$tenant_id"

  # Verify the target subscription is accessible.
  az account set --subscription "$SUBSCRIPTION_ID" \
    || die "Cannot switch to subscription ${SUBSCRIPTION_ID}"
}

# ─── Prompt for GitHub repo if not supplied ───────────────────────────────────
prompt_github_repo() {
  if [[ -n "$GITHUB_REPO" ]]; then
    return
  fi

  echo ""
  read -rp "  GitHub repository (owner/repo, e.g. myorg/azure-demo): " GITHUB_REPO
  [[ "$GITHUB_REPO" =~ ^[^/]+/[^/]+$ ]] \
    || die "Invalid repo format. Expected owner/repo."
}

# ─── Create deploy resource group ────────────────────────────────────────────
create_deploy_rg() {
  header "Deploy resource group: ${DEPLOY_RG}"

  if az group show --name "$DEPLOY_RG" &>/dev/null; then
    success "Already exists — skipping creation."
  else
    az group create \
      --name     "$DEPLOY_RG" \
      --location "$LOCATION" \
      --tags     "managed_by=bootstrap" "project=azure-demo" \
      --output   none
    success "Created resource group: ${DEPLOY_RG} (${LOCATION})"
  fi
}

# ─── Create Terraform state storage account ───────────────────────────────────
create_state_storage() {
  header "Terraform state storage account"

  # Storage account names: 3-24 chars, lowercase alphanumeric only.
  # Derive a stable suffix from the subscription ID to keep runs idempotent.
  local sub_suffix
  sub_suffix=$(echo "$SUBSCRIPTION_ID" | tr -d '-' | cut -c1-8)
  SA_NAME="tfstate${sub_suffix}"

  info "Storage account name: ${SA_NAME}"

  if az storage account show --name "$SA_NAME" --resource-group "$DEPLOY_RG" &>/dev/null; then
    success "Storage account already exists — skipping creation."
  else
    az storage account create \
      --name                   "$SA_NAME" \
      --resource-group         "$DEPLOY_RG" \
      --location               "$LOCATION" \
      --sku                    Standard_LRS \
      --kind                   StorageV2 \
      --min-tls-version        TLS1_2 \
      --allow-blob-public-access false \
      --tags                   "managed_by=bootstrap" "project=azure-demo" \
      --output                 none
    success "Created storage account: ${SA_NAME}"
  fi

  # Containers ─────────────────────────────────────────────────────────────────
  for container in tfstate tfplans; do
    if az storage container show \
        --name           "$container" \
        --account-name   "$SA_NAME" \
        --auth-mode      login \
        &>/dev/null 2>&1; then
      success "Container '${container}' already exists."
    else
      az storage container create \
        --name           "$container" \
        --account-name   "$SA_NAME" \
        --auth-mode      login \
        --output         none
      success "Created container: ${container}"
    fi
  done

  # 30-day lifecycle policy for tfplans (auto-clean reviewed plans).
  info "Applying lifecycle management policy to tfplans container..."
  az storage account management-policy create \
    --account-name    "$SA_NAME" \
    --resource-group  "$DEPLOY_RG" \
    --policy '{
      "rules": [{
        "name": "delete-old-tfplans",
        "type": "Lifecycle",
        "definition": {
          "filters": {
            "blobTypes": ["blockBlob"],
            "prefixMatch": []
          },
          "actions": {
            "baseBlob": {
              "delete": { "daysAfterModificationGreaterThan": 30 }
            }
          }
        }
      }]
    }' \
    --output none 2>/dev/null || warn "Could not set lifecycle policy (may need Storage Account Contributor)."
}

# ─── Create App Registration and Service Principal ───────────────────────────
create_service_principal() {
  header "App Registration / Service Principal: ${SP_NAME}"

  # Check for existing App Registration by display name.
  local app_id
  app_id=$(az ad app list \
    --display-name "$SP_NAME" \
    --query        "[0].appId" \
    --output       tsv 2>/dev/null)

  if [[ -n "$app_id" && "$app_id" != "None" ]]; then
    success "App Registration already exists (appId: ${app_id}) — skipping creation."
    APP_ID="$app_id"
  else
    APP_ID=$(az ad app create \
      --display-name "$SP_NAME" \
      --query        "appId" \
      --output       tsv)
    success "Created App Registration (appId: ${APP_ID})"
  fi

  # Ensure a Service Principal exists for this app.
  local sp_object_id
  sp_object_id=$(az ad sp show \
    --id    "$APP_ID" \
    --query "id" \
    --output tsv 2>/dev/null || true)

  if [[ -z "$sp_object_id" || "$sp_object_id" == "None" ]]; then
    sp_object_id=$(az ad sp create \
      --id     "$APP_ID" \
      --query  "id" \
      --output tsv)
    success "Created Service Principal (objectId: ${sp_object_id})"
  else
    success "Service Principal already exists (objectId: ${sp_object_id})"
  fi

  SP_OBJECT_ID="$sp_object_id"
}

# ─── Add OIDC federated credentials ──────────────────────────────────────────
# GitHub Actions OIDC subjects:
#   Push to branch  → repo:<owner>/<repo>:ref:refs/heads/<branch>
#   Environment     → repo:<owner>/<repo>:environment:<env>
#   Pull request    → repo:<owner>/<repo>:pull_request
#
# We create one credential per subject so the principal only works from the
# expected context (no wildcard subjects).
add_federated_credentials() {
  header "OIDC federated credentials (GitHub Actions)"

  local repo="$GITHUB_REPO"

  # Credentials to register: <name> <subject>
  local -a creds=(
    "github-push-main"   "repo:${repo}:ref:refs/heads/main"
    "github-push-dev"    "repo:${repo}:ref:refs/heads/dev"
    "github-env-prod"    "repo:${repo}:environment:prod"
    "github-env-dev"     "repo:${repo}:environment:dev"
    "github-pull-request" "repo:${repo}:pull_request"
  )

  local issuer="https://token.actions.githubusercontent.com"
  local i=0
  while [[ $i -lt ${#creds[@]} ]]; do
    local cred_name="${creds[$i]}"
    local subject="${creds[$((i+1))]}"
    i=$((i+2))

    # Check if credential already exists.
    local existing
    existing=$(az ad app federated-credential list \
      --id    "$APP_ID" \
      --query "[?name=='${cred_name}'].name | [0]" \
      --output tsv 2>/dev/null || true)

    if [[ -n "$existing" && "$existing" != "None" ]]; then
      success "Federated credential '${cred_name}' already exists — skipping."
    else
      az ad app federated-credential create \
        --id        "$APP_ID" \
        --parameters "{
          \"name\":      \"${cred_name}\",
          \"issuer\":    \"${issuer}\",
          \"subject\":   \"${subject}\",
          \"audiences\": [\"api://AzureADTokenExchange\"]
        }" \
        --output none
      success "Added federated credential: ${cred_name}"
      info    "  Subject: ${subject}"
    fi
  done
}

# ─── Role assignments ─────────────────────────────────────────────────────────
assign_roles() {
  header "Role assignments"

  local scope="/subscriptions/${SUBSCRIPTION_ID}"

  # Owner on the subscription — required so Terraform can create and assign
  # roles to managed identities that the workload stamps use.
  info "Assigning Owner on subscription ${SUBSCRIPTION_ID} ..."
  if az role assignment list \
      --assignee "$SP_OBJECT_ID" \
      --role     "Owner" \
      --scope    "$scope" \
      --query    "[0].id" \
      --output   tsv 2>/dev/null | grep -q .; then
    success "Owner already assigned — skipping."
  else
    az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type "ServicePrincipal" \
      --role  "Owner" \
      --scope "$scope" \
      --output none
    success "Assigned Owner on subscription."
  fi

  # Storage Blob Data Contributor on the state storage account — required for
  # blob upload/download with --auth-mode login used in the pipelines.
  local sa_scope
  sa_scope=$(az storage account show \
    --name           "$SA_NAME" \
    --resource-group "$DEPLOY_RG" \
    --query          "id" \
    --output         tsv)

  info "Assigning Storage Blob Data Contributor on ${SA_NAME} ..."
  if az role assignment list \
      --assignee "$SP_OBJECT_ID" \
      --role     "Storage Blob Data Contributor" \
      --scope    "$sa_scope" \
      --query    "[0].id" \
      --output   tsv 2>/dev/null | grep -q .; then
    success "Storage Blob Data Contributor already assigned — skipping."
  else
    az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type "ServicePrincipal" \
      --role  "Storage Blob Data Contributor" \
      --scope "$sa_scope" \
      --output none
    success "Assigned Storage Blob Data Contributor on storage account."
  fi
}

# ─── Print summary ────────────────────────────────────────────────────────────
print_summary() {
  header "Summary"

  echo ""
  echo -e "${BOLD}Resources created:${RST}"
  echo "  Resource group : ${DEPLOY_RG} (${LOCATION})"
  echo "  Storage account: ${SA_NAME}"
  echo "  Containers     : tfstate, tfplans"
  echo "  App / SP name  : ${SP_NAME}"
  echo "  App ID (client): ${APP_ID}"
  echo ""

  echo -e "${BOLD}${YLW}GitHub Actions secrets to configure:${RST}"
  echo "  (Repository → Settings → Secrets and variables → Actions)"
  echo ""
  printf "  %-35s %s\n" "Secret name" "Value"
  printf "  %-35s %s\n" "-----------" "-----"
  printf "  %-35s %s\n" "ARM_CLIENT_ID"              "$APP_ID"
  printf "  %-35s %s\n" "ARM_TENANT_ID"              "$TENANT_ID"
  printf "  %-35s %s\n" "ARM_SUBSCRIPTION_ID"        "$SUBSCRIPTION_ID"
  printf "  %-35s %s\n" "TF_STATE_STORAGE_ACCOUNT"   "$SA_NAME"
  echo ""

  echo -e "${BOLD}${YLW}GitHub Actions environments to configure:${RST}"
  echo "  (Repository → Settings → Environments)"
  echo ""
  echo "  dev   — No required reviewers (used for plan audit trail on dev branch)"
  echo "  prod  — Add required reviewers to gate production apply"
  echo ""

  echo -e "${BOLD}${GRN}Next steps:${RST}"
  echo "  1. Add the secrets above to your GitHub repository."
  echo "  2. Create the 'dev' and 'prod' environments in GitHub."
  echo "  3. Add required reviewers to the 'prod' environment."
  echo "  4. Run Terraform:"
  echo "     terraform -chdir=terraform/phase1/core init \\"
  echo "       -backend-config=\"resource_group_name=${DEPLOY_RG}\" \\"
  echo "       -backend-config=\"storage_account_name=${SA_NAME}\" \\"
  echo "       -backend-config=\"container_name=tfstate\" \\"
  echo "       -backend-config=\"key=phase1-core.tfstate\""
  echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYN}"
  echo "╔═══════════════════════════════════════════════════════╗"
  echo "║         Azure Demo — Environment Bootstrap            ║"
  echo "╚═══════════════════════════════════════════════════════╝${RST}"

  check_deps
  validate_az_session
  prompt_github_repo

  echo ""
  info "Configuration:"
  info "  Location     : ${LOCATION}"
  info "  Subscription : ${SUBSCRIPTION_ID}"
  info "  Deploy RG    : ${DEPLOY_RG}"
  info "  SP name      : ${SP_NAME}"
  info "  GitHub repo  : ${GITHUB_REPO}"
  echo ""
  read -rp "  Proceed? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }

  create_deploy_rg
  create_state_storage
  create_service_principal
  add_federated_credentials
  assign_roles
  print_summary

  success "Bootstrap complete."
}

main "$@"
