# ═══════════════════════════════════════════════════════════════════════════════
# Self-hosted GitHub Actions Runner VM
#
# A small Ubuntu VM in snet-runner that acts as the GitHub Actions self-hosted
# runner. It is the only subnet with internet egress (via NAT Gateway), enabling
# it to reach GitHub, package repos, and Azure ARM endpoints, while also having
# private VNet access to ACR, Key Vault, APIM, and storage endpoints.
#
# cloud-init (custom_data) installs Docker + Azure CLI, downloads the pinned
# runner binary, and registers it with GitHub using a short-lived token obtained
# from the API via runner_github_pat. The runner starts as a systemd service.
#
# Auth:
#   - Primary:  Entra ID SSH via AADSSHLoginForLinux extension
#               `az ssh vm --name vm-runner-core --resource-group rg-core`
#   - Fallback: local admin SSH key (sensitive output in runner_ssh_private_key_pem)
# ═══════════════════════════════════════════════════════════════════════════════

# ─── SSH key ─────────────────────────────────────────────────────────────────
# Generated locally; Entra ID login (below) is the expected day-to-day method.
# This key is kept as a sensitive break-glass fallback.

resource "tls_private_key" "runner" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ─── NIC ─────────────────────────────────────────────────────────────────────
# No public IP — all outbound internet traffic is NAT'd via pip-nat-core.
# SSH access from the jumpbox is permitted by the NSG rule in network.tf.

resource "azurerm_network_interface" "runner" {
  name                = "nic-runner-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location

  ip_configuration {
    name                          = "ipconfig-runner"
    subnet_id                     = module.vnet.subnet_ids["snet-runner"]
    private_ip_address_allocation = "Dynamic"
  }

  tags = local.tags
}

# ─── VM ──────────────────────────────────────────────────────────────────────
# Ubuntu 22.04 LTS.  cloud-init installs Docker and common CI tooling.
# GitHub Actions runner registration is performed manually after first boot.

resource "azurerm_linux_virtual_machine" "runner" {
  name                = "vm-runner-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  size                = var.runner_vm_size
  admin_username      = var.runner_admin_username

  network_interface_ids = [azurerm_network_interface.runner.id]

  admin_ssh_key {
    username   = var.runner_admin_username
    public_key = tls_private_key.runner.public_key_openssh
  }

  os_disk {
    name                 = "osdisk-runner-${local.name_suffix}"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  # System-assigned identity is required by the AADSSHLoginForLinux extension.
  identity {
    type = "SystemAssigned"
  }

  # cloud-init:
  #   1. Install Docker Engine + Azure CLI (tools the runner jobs need)
  #   2. Download and verify the pinned runner binary
  #   3. Exchange runner_github_pat for a short-lived registration token
  #   4. Register and start the runner as a systemd service
  custom_data = base64encode(<<-INIT
  #!/bin/bash
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release git jq unzip

  # ── Docker Engine (official repo) ──────────────────────────────────────────
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin

  # ── Azure CLI ──────────────────────────────────────────────────────────────
  curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash

  # Allow the runner admin user to run Docker without sudo
  usermod -aG docker ${var.runner_admin_username}

  # ── GitHub Actions runner v2.331.0 ─────────────────────────────────────────
  RUNNER_VERSION="2.331.0"
  RUNNER_HASH="5fcc01bd546ba5c3f1291c2803658ebd3cedb3836489eda3be357d41bfcf28a7"
  RUNNER_HOME="/home/${var.runner_admin_username}/actions-runner"
  RUNNER_USER="${var.runner_admin_username}"

  mkdir -p "$RUNNER_HOME"
  curl -fsSL -o "$RUNNER_HOME/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" \
    "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
  echo "$RUNNER_HASH  $RUNNER_HOME/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" \
    | shasum -a 256 -c
  tar xzf "$RUNNER_HOME/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" -C "$RUNNER_HOME"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

  # Configure the runner as the runner user (config.sh must not run as root).
  # Registration token is passed in from the runner_registration_token variable
  # (sourced from the GITHUB_RUNNER_REGISTRATION_TOKEN GitHub secret in CI).
  sudo -u "$RUNNER_USER" bash -c "
    '$RUNNER_HOME/config.sh' \
      --url 'https://github.com/BenSR/azure-demo' \
      --token '${var.runner_registration_token}' \
      --name 'azure-self-hosted' \
      --labels 'self-hosted,linux' \
      --unattended \
      --replace
  "

  # Install as a systemd service and start it
  "$RUNNER_HOME/svc.sh" install "$RUNNER_USER"
  "$RUNNER_HOME/svc.sh" start
  INIT
  )

  tags = local.tags
}

# ─── Entra ID SSH Login extension ────────────────────────────────────────────
# Enables passwordless SSH using Entra ID credentials:
#   az ssh vm --name vm-runner-core --resource-group rg-core

resource "azurerm_virtual_machine_extension" "runner_aad_ssh" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.runner.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  tags = local.tags
}

# ─── VM Administrator Login RBAC ─────────────────────────────────────────────
# Grants the specified UPN admin-level SSH access via Entra ID.
# Set runner_admin_upn in terraform.tfvars (or as a -var argument).

resource "azurerm_role_assignment" "runner_vm_admin_login" {
  scope                = azurerm_linux_virtual_machine.runner.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = data.azuread_user.runner_admin.object_id
}
