# Implementation Planning — Terraform Modules & Root Resources

This document defines which Terraform resources are implemented as reusable modules and which are defined directly in the root configurations (Phase 1 / Phase 3). The guiding principle is **pragmatic modularisation** — modules exist only where repeatability or composability justifies the abstraction.

---

## Decision Framework

| Criterion | Module? | Rationale |
|-----------|---------|-----------|
| Resource will exist exactly once (e.g., ACR, APIM, Log Analytics) | No | A module adds indirection with no reuse benefit. Define inline in the root config. |
| Resource group is a repeatable "stamp" (e.g., Function App + ASP + Storage) | Yes | Future environments / regions add another `module` block. |
| Resource is a cross-cutting concern consumed by many other resources (e.g., Private DNS zones) | Yes | Centralises zone creation, exports zone IDs as clean named attributes — simplifies private endpoint wiring everywhere else. |
| VNet + subnets + NSGs | Yes | Subnet definitions vary per deployment; module accepts a list of subnet objects and keeps networking self-contained. |

---

## Resource Naming Convention

All resources follow a consistent naming pattern. The workload name for this project is **`wkld`**.

### Pattern

```
<resource-abbreviation>-<workload>-<stamp|shared>-<environment>
```

- **Stamp resources** (resources inside a workload stamp module) use a numeric stamp identifier: `<abbr>-wkld-<N>-<env>`
- **Shared resources** (single-instance resources at root level) replace the stamp number with `shared`: `<abbr>-wkld-shared-<env>`
- **Storage accounts** (and any other resources that prohibit hyphens) use the same convention with hyphens removed: `<abbr>wkld<stamp|shared><env>`

### Design Decision — Global Uniqueness

Storage accounts and a handful of other Azure resources require globally unique names. The author has made a deliberate design choice that **naming collisions are unlikely** given the short workload name and environment qualifier. No random suffix or subscription-ID hash is appended. If a collision occurs at `apply` time it will be immediately obvious and can be resolved by adjusting the workload name or adding a disambiguator — but the expectation is that this will not happen.

### Examples

#### Stamp Resources (stamp 1, dev environment)

| Resource | Abbreviation | Name |
|----------|-------------|------|
| App Service Plan | `asp` | `asp-wkld-1-dev` |
| Function App | `func` | `func-wkld-1-dev` |
| Storage Account | `st` | `stwkld1dev` |
| Application Insights | `appi` | `appi-wkld-1-dev` |

#### Shared Resources (dev environment)

| Resource | Abbreviation | Name |
|----------|-------------|------|
| Resource Group | `rg` | `rg-wkld-shared-dev` |
| Virtual Network | `vnet` | `vnet-wkld-shared-dev` |
| Key Vault | `kv` | `kv-wkld-shared-dev` |
| Container Registry | `acr` | `acrwkldshareddev` |
| API Management | `apim` | `apim-wkld-shared-dev` |
| Log Analytics Workspace | `log` | `log-wkld-shared-dev` |
| NSG | `nsg` | `nsg-wkld-shared-dev-<subnet>` |

### Terraform Implementation

Root variables `workload_name`, `environment`, and (for stamps) `stamp_number` feed into a `locals` block that constructs all resource names. Modules accept a pre-built name or the components needed to build one — keeping the convention enforced in one place.

```hcl
variable "workload_name" {
  type    = string
  default = "wkld"
}

variable "environment" {
  type = string # e.g. "dev", "prod"
}

locals {
  shared_prefix  = "${var.workload_name}-shared-${var.environment}"    # e.g. "wkld-shared-dev"
  shared_prefix_clean = "${var.workload_name}shared${var.environment}" # e.g. "wkldshareddev"
}
```

Inside the workload-stamp module:

```hcl
variable "stamp_number" {
  type = number
}

locals {
  stamp_prefix       = "${var.workload_name}-${var.stamp_number}-${var.environment}"    # e.g. "wkld-1-dev"
  stamp_prefix_clean = "${var.workload_name}${var.stamp_number}${var.environment}"      # e.g. "wkld1dev"
}
```

---

## Modules

### 1. `modules/vnet`

**Purpose:** Provision a VNet, its subnets, NSGs, and NSG-to-subnet associations. Optionally link provided Private DNS Zone IDs to the VNet.

**Why a module:** Subnet layouts will differ between phases and environments. Passing a list of subnet objects keeps things DRY and makes adding subnets a one-line change.

#### Inputs

| Variable | Type | Description |
|----------|------|-------------|
| `name` | `string` | VNet name. |
| `resource_group_name` | `string` | Target resource group. |
| `location` | `string` | Azure region. |
| `address_space` | `list(string)` | VNet CIDR(s). |
| `subnets` | `list(object)` | Each object: `name`, `address_prefixes`, `delegation` (optional), `service_endpoints` (optional). |
| `private_dns_zone_ids` | `list(string)` | Zone IDs to link to the VNet (output from `modules/private-dns`). |
| `tags` | `map(string)` | Resource tags. |

#### Outputs

| Output | Description |
|--------|-------------|
| `vnet_id` | VNet resource ID. |
| `vnet_name` | VNet name. |
| `subnet_ids` | `map(string)` — subnet name → subnet ID. |
| `nsg_ids` | `map(string)` — subnet name → NSG ID. |

#### Defaults & Security Posture

- One NSG created per subnet; default rule denies all inbound.
- NSG flow logs enabled where a Log Analytics Workspace ID is supplied.

---

### 2. `modules/private-dns`

**Purpose:** Create the standard set of Azure Private DNS Zones required by the workload's Private Endpoints, and export each zone ID as a **named attribute** so consumers can reference them without string matching.

**Why a module:** Every Private Endpoint–backed service needs a DNS zone. Centralising creation in one module avoids scattered `azurerm_private_dns_zone` blocks and makes zone IDs trivially consumable. When adding a new PaaS service, add one zone to this module and every root config gets it automatically.

#### Zones Created

| Named Attribute | DNS Zone | Used By |
|-----------------|----------|---------|
| `key_vault_zone_id` | `privatelink.vaultcore.azure.net` | Key Vault |
| `blob_storage_zone_id` | `privatelink.blob.core.windows.net` | Storage Account (blob) |
| `file_storage_zone_id` | `privatelink.file.core.windows.net` | Storage Account (file share) |
| `table_storage_zone_id` | `privatelink.table.core.windows.net` | Storage Account (table) |
| `queue_storage_zone_id` | `privatelink.queue.core.windows.net` | Storage Account (queue) |
| `acr_zone_id` | `privatelink.azurecr.io` | Azure Container Registry |
| `websites_zone_id` | `privatelink.azurewebsites.net` | Function App (private endpoint) |
| `apim_zone_id` | `privatelink.azure-api.net` | API Management (if private endpoint used) |

#### Inputs

| Variable | Type | Description |
|----------|------|-------------|
| `resource_group_name` | `string` | Target resource group. |
| `tags` | `map(string)` | Resource tags. |

#### Outputs

Each zone ID is exposed as an individual, clearly named output (see table above). This means downstream resources reference `module.private_dns.key_vault_zone_id` rather than digging into a map or constructing zone names.

| Output | Description |
|--------|-------------|
| `key_vault_zone_id` | Zone ID for Key Vault private endpoints. |
| `blob_storage_zone_id` | Zone ID for Blob Storage private endpoints. |
| `file_storage_zone_id` | Zone ID for File Storage private endpoints. |
| `table_storage_zone_id` | Zone ID for Table Storage private endpoints. |
| `queue_storage_zone_id` | Zone ID for Queue Storage private endpoints. |
| `acr_zone_id` | Zone ID for ACR private endpoints. |
| `websites_zone_id` | Zone ID for Function App / Web App private endpoints. |
| `apim_zone_id` | Zone ID for APIM private endpoints. |
| `all_zone_ids` | `list(string)` — convenience output for bulk VNet linking. |

> **Note:** VNet linking is handled by the `modules/vnet` module, which accepts `private_dns_zone_ids` and creates the link resources. This keeps DNS zone *creation* and DNS zone *linking* cleanly separated.

---

### 3. `modules/workload-stamp`

**Purpose:** Deploy one complete workload instance — App Service Plan, Function App (container-based), VNet integration, dedicated Storage Account, Application Insights, and the private endpoints that connect them. This is the repeatable unit of compute.

**Why a module:** The solution design explicitly anticipates multi-region / multi-environment deployments. Spinning up a second stamp should be a second `module` block with different parameters — not a copy-paste of 200 lines of HCL.

#### Inputs

| Variable | Type | Description |
|----------|------|-------------|
| `workload_name` | `string` | Workload identifier (default: `wkld`). Used in resource naming. |
| `stamp_number` | `number` | Stamp instance number (e.g., `1`). Combined with `workload_name` and `environment` to form resource names like `func-wkld-1-dev`. |
| `environment` | `string` | Environment name (e.g., `dev`, `prod`). |
| `resource_group_name` | `string` | Target resource group. |
| `location` | `string` | Azure region. |
| `asp_sku` | `string` | App Service Plan SKU. Default: `P1v3` (minimum for VNet integration + containers). |
| `function_apps` | `map(object)` | Map of Function App definitions. Each: `image` (ACR image ref), `app_settings` (map). |
| `subnet_id` | `string` | Subnet ID for App Service Plan VNet integration (must be delegated to `Microsoft.Web/serverFarms`). |
| `private_endpoint_subnet_id` | `string` | Subnet ID for Private Endpoints. |
| `acr_id` | `string` | ACR resource ID (for role assignment — AcrPull). |
| `key_vault_id` | `string` | Key Vault resource ID (for role assignment — Secrets User). |
| `log_analytics_workspace_id` | `string` | Log Analytics Workspace ID for diagnostic settings. |
| `private_dns_zone_ids` | `object` | Object containing relevant zone IDs (blob, file, table, queue, websites) from `modules/private-dns`. |
| `tags` | `map(string)` | Resource tags. |

#### Outputs

| Output | Description |
|--------|-------------|
| `app_service_plan_id` | ASP resource ID. |
| `function_app_ids` | `map(string)` — function app name → resource ID. |
| `function_app_identities` | `map(object)` — function app name → managed identity principal ID + tenant ID. |
| `function_app_hostnames` | `map(string)` — function app name → default hostname. |
| `storage_account_id` | Stamp storage account resource ID. |
| `app_insights_instrumentation_key` | App Insights key (for downstream config). |
| `app_insights_connection_string` | App Insights connection string. |

#### Defaults & Security Posture

- **Managed Identity**: System-assigned Managed Identity enabled on every Function App by default.
- **Public access disabled**: Function App `public_network_access_enabled = false`; Storage Account `public_network_access_enabled = false`.
- **HTTPS only**: `https_only = true` on Function Apps.
- **Minimum TLS**: `minimum_tls_version = "1.2"` on Function Apps and Storage.
- **VNet integration**: Automatically configured using the supplied `subnet_id`.
- **Private Endpoints**: Created for the Storage Account (blob, file, table, queue) and Function App, wired to the supplied DNS zone IDs.
- **Diagnostic settings**: Created for ASP, Function App(s), Storage Account — all streaming to the supplied Log Analytics Workspace.
- **Role assignments**: AcrPull on the ACR, Key Vault Secrets User on Key Vault — granted to each Function App's Managed Identity.

---

## Root-Level Resources (No Module)

These resources exist once per deployment and do not benefit from modularisation. They are defined directly in the Phase 1 or Phase 3 root configuration.

### Phase 1 — Bootstrap (GitHub-hosted runner)

| Resource | File | Notes |
|----------|------|-------|
| Resource Groups | `resource-groups.tf` | One for shared infra, one per workload stamp (or a single flat group — decide at implementation time). |
| Module call: `modules/private-dns` | `dns.tf` | Creates all Private DNS Zones. |
| Module call: `modules/vnet` | `network.tf` | Creates VNet, subnets, NSGs, DNS zone links. |
| Azure Container Registry | `acr.tf` | Single instance. Private Endpoint + DNS zone group referencing `module.private_dns.acr_zone_id`. Admin disabled, managed identity pull only. |
| Azure Key Vault | `keyvault.tf` | Single instance. RBAC authorisation mode. Private Endpoint + DNS zone group referencing `module.private_dns.key_vault_zone_id`. Public access disabled. Purge protection enabled. |
| API Management | `apim.tf` | Single instance, Developer tier, internal VNet mode in its own delegated subnet. No module — APIM is a shared front door, not a repeatable stamp. |
| Log Analytics Workspace | `observability.tf` | Single instance. Retention set via variable. |
| Self-signed CA + client cert | `certificates.tf` | Terraform `tls` provider. Stored in Key Vault. |
| Module call: `modules/workload-stamp` | `workload.tf` | Instantiates one stamp. Adding another region/env = another `module` block here. |
| Jump Box VM | `jumpbox.tf` | Windows 11 (`Standard_B2s`), Entra ID auth via `AADLoginForWindows` extension. Public IP (static Standard SKU) for RDP. NIC in `snet-jumpbox`. No local admin password — Entra ID only. |

### Phase 3 — Private Data-Plane Operations (self-hosted VNet runner)

| Resource / Action | File | Notes |
|-------------------|------|-------|
| Container image build + push to ACR | CI/CD step | Not Terraform — Docker build + `az acr login` + push. |
| Key Vault secrets / certificates | `secrets.tf` | Write certs + any app secrets into Key Vault (data-plane op, needs VNet access). |
| APIM backend + API + mTLS policy | `apim-config.tf` | Wire APIM to Function App backend(s). Configure client cert validation policy using the CA cert from Key Vault. |
| Monitor alert rules | `alerts.tf` | Alert on 5xx rate, availability test failures. Action group with email/webhook. |
| Availability test | `alerts.tf` | App Insights standard web test against Function App health endpoint (via APIM or direct). |

---

## Module Interaction Diagram

```
Root Config (Phase 1)
│
├── module "private_dns"   (modules/private-dns)
│       ↓ outputs: zone IDs (named attributes)
│
├── module "vnet"          (modules/vnet)
│   │   ↑ consumes: private_dns.all_zone_ids (for VNet linking)
│   │   ↓ outputs: subnet_ids map
│   │
├── azurerm_container_registry          (inline)
│   │   ↑ consumes: vnet.subnet_ids["infra"], private_dns.acr_zone_id
│   │
├── azurerm_key_vault                   (inline)
│   │   ↑ consumes: vnet.subnet_ids["infra"], private_dns.key_vault_zone_id
│   │
├── azurerm_api_management              (inline)
│   │   ↑ consumes: vnet.subnet_ids["apim"]
│   │
├── azurerm_log_analytics_workspace     (inline)
│   │
├── azurerm_windows_virtual_machine     (inline — jumpbox.tf)
│   │   ↑ consumes: vnet.subnet_ids["snet-jumpbox"]
│   │   Entra ID login extension, public IP for RDP
│   │
└── module "workload_stamp" (modules/workload-stamp)
        ↑ consumes: vnet.subnet_ids["asp"], vnet.subnet_ids["infra"],
                    private_dns.blob_storage_zone_id, private_dns.file_storage_zone_id,
                    private_dns.table_storage_zone_id, private_dns.queue_storage_zone_id,
                    private_dns.websites_zone_id,
                    acr.id, key_vault.id, log_analytics.id
```

---

## Directory Structure

```
terraform/
  modules/
    private-dns/
      main.tf           # Zone resources
      outputs.tf        # Named zone ID outputs
      variables.tf
    vnet/
      main.tf           # VNet, subnets, NSGs, DNS zone links
      outputs.tf
      variables.tf
    workload-stamp/
      main.tf           # ASP, Function App(s), Storage, App Insights
      identity.tf       # Managed Identity role assignments
      private-endpoints.tf
      diagnostics.tf    # Diagnostic settings
      outputs.tf
      variables.tf
  phase1/
    main.tf             # Provider config, backend, module calls
    resource-groups.tf
    dns.tf              # module "private_dns"
    network.tf          # module "vnet"
    acr.tf
    keyvault.tf
    apim.tf
    observability.tf
    certificates.tf
    jumpbox.tf          # Jump box VM + NIC + Public IP + AAD extension
    workload.tf         # module "workload_stamp"
    variables.tf
    outputs.tf
    terraform.tfvars
  phase3/
    main.tf
    secrets.tf
    apim-config.tf
    alerts.tf
    variables.tf
    outputs.tf
    terraform.tfvars
```

---

## Summary

| Item | Implementation | Justification |
|------|---------------|---------------|
| Private DNS Zones | **Module** | Consumed by every private endpoint. Named outputs make zone IDs trivial to reference. |
| VNet / Subnets / NSGs | **Module** | Subnet definitions are data-driven (list of objects). Reusable across environments. |
| Workload Stamp (ASP + Function App + Storage + App Insights) | **Module** | Primary unit of repeatability. Multi-env / multi-region = multiple stamp instances. |
| ACR | **Root inline** | Single instance, no reuse case. |
| Key Vault | **Root inline** | Single instance, shared across stamps. |
| APIM | **Root inline** | Single instance, shared front door. |
| Log Analytics | **Root inline** | Single instance, central sink. |
| Certificates | **Root inline** | One-time generation via `tls` provider. |
| Jump Box VM | **Root inline** | Single instance, developer connectivity tool. Windows 11 + Entra ID auth + public IP for RDP. |
| Alert Rules / Availability Tests | **Root inline** | Defined once per deployment. |
