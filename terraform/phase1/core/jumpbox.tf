# ─── Jump box — Public IP ──────────────────────────────────────────────────────
# Static public IP for RDP access.
# NOTE: In production, replace with Azure Bastion (no public IP, browser-based).

resource "azurerm_public_ip" "jumpbox" {
  name                = "pip-jumpbox-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# ─── Jump box — NIC ───────────────────────────────────────────────────────────

resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-jumpbox-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location

  ip_configuration {
    name                          = "ipconfig-jumpbox"
    subnet_id                     = module.vnet.subnet_ids["snet-jumpbox"]
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }

  tags = local.tags
}

# ─── Jump box — random local admin password ───────────────────────────────────
# A complex password is generated here and stored in Terraform state.
# Retrieve it with: terraform output -raw jumpbox_admin_password

resource "random_password" "jumpbox" {
  length           = 24
  special          = true
  override_special = "!@#$%^&*"
}

# ─── Jump box — Windows 11 VM ─────────────────────────────────────────────────
# Standard_B2s: burstable, low-cost — appropriate for occasional admin use.
# RDP using the local admin account; retrieve the password from TF outputs.

resource "azurerm_windows_virtual_machine" "jumpbox" {
  name                = "vm-jumpbox-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  size                = var.jumpbox_vm_size
  admin_username      = var.jumpbox_admin_username
  admin_password      = random_password.jumpbox.result

  network_interface_ids = [azurerm_network_interface.jumpbox.id]

  os_disk {
    name                 = "osdisk-jumpbox-${local.name_suffix}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-22h2-ent"
    version   = "latest"
  }

  provision_vm_agent = true

  tags = local.tags
}

# ─── Jump box — upload test script to blob storage ───────────────────────────
# Uses the same "scripts" container created in runner.tf.  The blob name
# includes the MD5 hash of the script so that any edit automatically
# re-triggers the Custom Script Extension on the next terraform apply.

locals {
  jumpbox_test_script  = "${path.root}/../../../scripts/Test-Application-Jumpbox.ps1"
  jumpbox_setup_script = "${path.root}/../../../scripts/Setup-Jumpbox.ps1"
}

resource "azurerm_storage_blob" "jumpbox_test_script" {
  name                   = "Test-Application-Jumpbox-${filemd5(local.jumpbox_test_script)}.ps1"
  storage_account_name   = var.deploy_storage_account_name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = local.jumpbox_test_script
  content_type           = "application/octet-stream"
}

resource "azurerm_storage_blob" "jumpbox_setup_script" {
  name                   = "Setup-Jumpbox-${filemd5(local.jumpbox_setup_script)}.ps1"
  storage_account_name   = var.deploy_storage_account_name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = local.jumpbox_setup_script
  content_type           = "application/octet-stream"
}

# ─── Jump box — Custom Script Extension ──────────────────────────────────────
# Downloads both the setup and test scripts from blob storage, then runs the
# setup script which installs prerequisites and copies the test script to C:\.
#
# Prerequisites installed by Setup-Jumpbox.ps1:
#   1. Azure CLI        — for Key Vault certificate retrieval
#   2. Git for Windows  — bundles openssl, needed to build PFX from PEM certs
#
# Windows VMs use the Microsoft.Compute / CustomScriptExtension publisher
# (not Microsoft.Azure.Extensions which is Linux-only).
#
# The storage account key in protected_settings authenticates the download.

resource "azurerm_virtual_machine_extension" "jumpbox_setup" {
  name                       = "jumpbox-setup"
  virtual_machine_id         = azurerm_windows_virtual_machine.jumpbox.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    fileUris = [
      "https://${var.deploy_storage_account_name}.blob.core.windows.net/scripts/Test-Application-Jumpbox-${filemd5(local.jumpbox_test_script)}.ps1",
      "https://${var.deploy_storage_account_name}.blob.core.windows.net/scripts/Setup-Jumpbox-${filemd5(local.jumpbox_setup_script)}.ps1"
    ]
  })

  protected_settings = jsonencode({
    storageAccountName = var.deploy_storage_account_name
    storageAccountKey  = data.azurerm_storage_account.deploy.primary_access_key
    commandToExecute   = "powershell -ExecutionPolicy Unrestricted -File \"Setup-Jumpbox-${filemd5(local.jumpbox_setup_script)}.ps1\" -TestScriptFileName \"Test-Application-Jumpbox-${filemd5(local.jumpbox_test_script)}.ps1\""
  })

  depends_on = [
    azurerm_storage_blob.jumpbox_test_script,
    azurerm_storage_blob.jumpbox_setup_script
  ]

  tags = local.tags
}
