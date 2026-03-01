#!/usr/bin/env bash
# =============================================================================
# setup-runner.sh
#
# Executed by the Azure Custom Script Extension on the runner VM.
# Installs Docker Engine, downloads the pinned GitHub Actions runner binary,
# obtains a fresh short-lived registration token via the supplied PAT, then
# registers and starts the runner as a systemd service.
#
# The script is idempotent: re-running it (triggered by updating the CSE
# extension settings in Terraform) re-registers the runner and restarts the
# service without re-downloading the binary.
#
# Environment variables (set inline by CSE commandToExecute, stored encrypted
# in protected_settings — not visible in the Azure portal or activity logs):
#   RUNNER_MANAGEMENT_PAT  GitHub PAT used to obtain a registration token.
#                          Required permissions:
#                            Classic PAT  : repo scope
#                            Fine-grained : Administration → Read and write
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${RUNNER_MANAGEMENT_PAT:?RUNNER_MANAGEMENT_PAT env var is required (set via CSE commandToExecute)}"

GITHUB_REPO="BenSR/azure-demo"
RUNNER_VERSION="2.331.0"
RUNNER_HASH="5fcc01bd546ba5c3f1291c2803658ebd3cedb3836489eda3be357d41bfcf28a7"
RUNNER_HOME="/home/runneradmin/actions-runner"
RUNNER_USER="runneradmin"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# ── System packages ────────────────────────────────────────────────────────────

log "Installing system packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release git jq unzip

# ── Docker Engine (official repo) ─────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
  log "Installing Docker Engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  usermod -aG docker "$RUNNER_USER"
  log "Docker installed"
else
  log "Docker already present — skipping"
fi

# ── Azure CLI ──────────────────────────────────────────────────────────────────

if ! command -v az &>/dev/null; then
  log "Installing Azure CLI"
  curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
fi

# ── Node.js (required by GitHub Actions JavaScript actions) ───────────────────
# actions/checkout, azure/login, hashicorp/setup-terraform, etc. are all
# Node-based. ubuntu-latest runners ship with Node pre-installed; self-hosted
# runners do not.

if ! command -v node &>/dev/null; then
  log "Installing Node.js 20 LTS"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
  log "Node.js $(node --version) installed"
else
  log "Node.js $(node --version) already present — skipping"
fi

# ── Runner registration token (fresh from GitHub API) ─────────────────────────
# Using the long-lived management PAT to exchange for a 1-hour registration
# token at boot time. This avoids embedding a pre-generated token in Terraform
# state or cloud-init, where it would expire before the VM boots.
#
# Required PAT permissions:
#   Classic PAT  : repo scope
#   Fine-grained : Administration → Read and write (for the target repository)

log "Requesting runner registration token from GitHub API"
API_RESPONSE=$(curl -sS \
  -X POST \
  -H "Authorization: Bearer ${RUNNER_MANAGEMENT_PAT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GITHUB_REPO}/actions/runners/registration-token")

RUNNER_TOKEN=$(echo "$API_RESPONSE" | jq -r '.token // empty')

if [[ -z "$RUNNER_TOKEN" ]]; then
  log "ERROR: GitHub API did not return a token. Response:"
  echo "$API_RESPONSE" | jq . || echo "$API_RESPONSE"
  log "Check that the PAT has the correct permissions:"
  log "  Classic PAT  : repo scope"
  log "  Fine-grained : Administration → Read and write on ${GITHUB_REPO}"
  exit 1
fi

# ── Runner binary ──────────────────────────────────────────────────────────────

mkdir -p "$RUNNER_HOME"
if [[ ! -f "$RUNNER_HOME/config.sh" ]]; then
  log "Downloading runner v${RUNNER_VERSION}"
  curl -fsSL \
    -o /tmp/actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  echo "${RUNNER_HASH}  /tmp/actions-runner.tar.gz" | sha256sum -c
  tar xzf /tmp/actions-runner.tar.gz -C "$RUNNER_HOME"
  rm -f /tmp/actions-runner.tar.gz
  log "Runner binary extracted"
else
  log "Runner binary already present — skipping download"
fi

chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_HOME"

# ── Tear down any existing service and configuration (idempotent re-run) ───────
# Stop and uninstall the systemd service first, then remove the local runner
# config files so config.sh can run fresh.  The --replace flag passed to
# config.sh (below) handles deregistering the old runner on the GitHub side.

if [[ -f "$RUNNER_HOME/svc.sh" ]]; then
  pushd "$RUNNER_HOME" >/dev/null
  ./svc.sh stop 2>/dev/null || true
  ./svc.sh uninstall 2>/dev/null || true
  popd >/dev/null
fi

if [[ -f "$RUNNER_HOME/.runner" ]]; then
  log "Removing existing local runner configuration"
  rm -f "$RUNNER_HOME/.runner" "$RUNNER_HOME/.credentials" "$RUNNER_HOME/.credentials_rsaparams"
fi

# ── Configure runner ───────────────────────────────────────────────────────────

log "Configuring runner against https://github.com/${GITHUB_REPO}"
sudo -u "$RUNNER_USER" "$RUNNER_HOME/config.sh" \
  --url    "https://github.com/${GITHUB_REPO}" \
  --token  "$RUNNER_TOKEN" \
  --name   "azure-self-hosted" \
  --labels "self-hosted,linux" \
  --unattended \
  --replace

# ── Install and start systemd service ─────────────────────────────────────────

log "Installing systemd service"
pushd "$RUNNER_HOME" >/dev/null
./svc.sh install "$RUNNER_USER"
./svc.sh start
popd >/dev/null

log "Runner setup complete — service is running"
