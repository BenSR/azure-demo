terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.50"
    }
  }

  # Backend config is supplied at init time via -backend-config flags or a
  # backend.hcl file so that secrets never appear in source control.
  #
  # Example backend.hcl:
  #   resource_group_name  = "rg-core-deploy"
  #   storage_account_name = "<your-state-storage-account>"
  #   container_name       = "tfstate"
  #   key                  = "phase2.tfstate"
  #
  # Phase 2 is workspace-driven (dev/prod).  Use the same workspace as
  # the phase1/env deployment it targets:
  #
  #   terraform -chdir=terraform/phase2/env workspace select dev
  #   terraform -chdir=terraform/phase2/env apply \
  #     -var-file=terraform.tfvars -var-file=dev.tfvars
  #
  # Phase 2 MUST run from a VNet-injected runner (snet-runner subnet) so it
  # can reach Key Vault and APIM Private Endpoints.
  backend "azurerm" {}
}

provider "azurerm" {


  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azuread" {
}
