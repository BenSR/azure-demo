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
