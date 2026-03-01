# ═══════════════════════════════════════════════════════════════════════════════
# Self-hosted GitHub Actions Runner VM
#
# A small Ubuntu VM in snet-runner that acts as the GitHub Actions self-hosted
# runner. It is the only subnet with internet egress (via NAT Gateway), enabling
# it to reach GitHub, package repos, and Azure ARM endpoints, while also having
# private VNet access to ACR, Key Vault, APIM, and storage endpoints.
#
# Setup is handled by the CustomScript extension (runner_setup below), which
# downloads scripts/setup-runner.sh from blob storage via a SAS URL and runs
# it at VM provisioning time. The script uses the runner_management_pat to
# request a fresh short-lived GitHub registration token at execution time,
# avoiding the 1-hour expiry problem inherent in baking a static token into
# cloud-init or Terraform state.  Updating the extension settings in Terraform
# re-triggers the script, allowing runner re-registration without VM recreation.
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

# ─── Scripts container + setup script blob ───────────────────────────────────
# Terraform uploads setup-runner.sh from the local repo to blob storage.
# This runs in GitHub Actions, which has data-plane access to the storage
# account (it already reads/writes Terraform state there).  The bootstrap
# script (prepare-azure-env.sh) intentionally skips this — it runs outside
# the network and can only make management-plane calls.
#
# The blob's content hash is baked into commandToExecute so that updating
# setup-runner.sh in the repo automatically triggers the CSE to re-run on the
# next terraform apply, without any manual intervention.

locals {
  runner_setup_script = "${path.root}/../../../scripts/setup-runner.sh"
}

resource "azurerm_storage_container" "scripts" {
  name                  = "scripts"
  storage_account_name  = var.deploy_storage_account_name
  container_access_type = "private"
}

resource "azurerm_storage_blob" "runner_setup" {
  name                   = "setup-runner-${filemd5(local.runner_setup_script)}.sh"
  storage_account_name   = var.deploy_storage_account_name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = local.runner_setup_script
  content_type           = "text/x-shellscript"
}

# ─── Custom Script Extension — runner setup ───────────────────────────────────
# Downloads setup-runner.sh from blob storage and executes it.
#
# fileUris contains the plain HTTPS blob URL; the storage account name and key
# go in protected_settings so Azure encrypts them at rest and omits them from
# activity logs.  The key is read at plan time via the azurerm_storage_account
# data source — no extra GitHub secret required.
#
# The runner_management_pat (also in protected_settings) lets setup-runner.sh
# exchange for a fresh 1-hour GitHub registration token at execution time.
# commandToExecute includes the script's MD5 hash as a shell comment.  It is
# ignored at runtime but ensures Terraform detects a settings change (and
# therefore re-triggers the extension) whenever setup-runner.sh is modified.

resource "azurerm_virtual_machine_extension" "runner_setup" {
  name                       = "runner-setup"
  virtual_machine_id         = azurerm_linux_virtual_machine.runner.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    fileUris = [
      "https://${var.deploy_storage_account_name}.blob.core.windows.net/scripts/setup-runner-${filemd5(local.runner_setup_script)}.sh"
    ]
  })

  protected_settings = jsonencode({
    commandToExecute   = "RUNNER_MANAGEMENT_PAT='${var.runner_management_pat}' bash setup-runner-${filemd5(local.runner_setup_script)}.sh"
    storageAccountName = var.deploy_storage_account_name
    storageAccountKey  = data.azurerm_storage_account.deploy.primary_access_key
  })

  depends_on = [azurerm_storage_blob.runner_setup]

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
