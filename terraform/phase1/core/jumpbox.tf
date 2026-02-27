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
# The local admin password is generated randomly and stored in state.  It is
# not expected to be used — Entra ID login is the primary access method.

resource "random_password" "jumpbox" {
  length           = 24
  special          = true
  override_special = "!@#$%^&*"
}

# ─── Jump box — Windows 11 VM ─────────────────────────────────────────────────
# Standard_B2s: burstable, low-cost — appropriate for occasional admin use.
# Entra ID (AAD) login is enabled via the extension below; local credentials
# are randomized and are not usable

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

  # Required for the AADLoginForWindows extension.
  identity {
    type = "SystemAssigned"
  }

  # Ensure the VM agent is installed so extensions can run.
  provision_vm_agent = true

  tags = local.tags
}

# ─── Jump box — Entra ID Login extension ──────────────────────────────────────
# Allows administrators to RDP into the jump box using their Entra ID
# (Azure AD) credentials instead of local accounts.
# Users must be assigned the "Virtual Machine Administrator Login" or
# "Virtual Machine User Login" role on the VM resource after provisioning.

resource "azurerm_virtual_machine_extension" "aad_login" {
  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.jumpbox.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true

  tags = local.tags
}
