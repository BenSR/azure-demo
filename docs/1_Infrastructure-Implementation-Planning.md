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
<resource-abbreviation>-<workload>-<tier>[-<environment>]
```

Three naming tiers:

| Tier | Pattern | Env suffix? | Description |
|------|---------|-------------|-------------|
| **Core** | `<abbr>-core` or `<abbr>core` | No | Core platform resources (VNet, ACR, Log Analytics, DNS, NAT GW, Jump box, Runner). Shared across all environments. No workload prefix, no env suffix. |
| **Shared env** | `<abbr>-wkld-shared-<env>` | Yes | Per-environment shared infra (APIM, Key Vault). Policy and secrets differ by env. |
| **Stamp** | `<abbr>-wkld-<N>-<app_slug>-<env>` | Yes | Per-stamp, per-environment compute (ASP, Function App, Storage, App Insights). The app slug distinguishes multiple Function Apps within a single stamp. |

- **Storage accounts** (and any other resources that prohibit hyphens) drop hyphens: `<abbr>wkld<N><env>` (e.g. `stwkld1dev`). ACR uses a subscription-ID hex prefix for global uniqueness: `acr<scope><8-hex-chars>` (e.g. `acrcore09d0073b`).

### Design Decision — Global Uniqueness

Storage accounts and a handful of other Azure resources require globally unique names. The author has made a deliberate design choice that **naming collisions are unlikely** given the short workload name and environment qualifier. No random suffix or subscription-ID hash is appended. If a collision occurs at `apply` time it will be immediately obvious and can be resolved by adjusting the workload name or adding a disambiguator — but the expectation is that this will not happen.

### Examples

#### Core Resources (deployed once — no env suffix)

| Resource | Abbreviation | Name |
|----------|-------------|------|
| Resource Group | `rg` | `rg-core` |
| Virtual Network | `vnet` | `vnet-core` |
| Container Registry | `acr` | `acrcore<sub-hex>` (e.g. `acrcore09d0073b`) |
| Log Analytics Workspace | `law` | `law-core` |
| Diagnostic Storage Account | `st` | *(removed — NSG flow logs disabled, no storage account created)* |
| NAT Gateway | `nat` | `nat-core` |
| NAT GW Public IP | `pip` | `pip-nat-core` |
| NSG (fixed subnet) | `nsg` | `nsg-core-<subnet>` e.g. `nsg-core-apim` |
| NSG (stamp subnet) | `nsg` | `nsg-core-stamp-<env>-<N>-pe` |
| Jump Box VM | `vm` | `vm-jumpbox-core` |
| Jump Box NIC | `nic` | `nic-jumpbox-core` |
| Jump Box Public IP | `pip` | `pip-jumpbox-core` |

#### Shared Resources (dev environment — `phase1/env/`)

| Resource | Abbreviation | Name |
|----------|-------------|------|
| Resource Group | `rg` | `rg-wkld-shared-dev` |
| API Management | `apim` | `apim-wkld-shared-dev` |

> **Key Vault is per-stamp** (not shared). It lives inside `modules/workload-stamp` in each stamp's resource group.

#### Stamp Resources (stamp 1, dev environment — `modules/workload-stamp`)

| Resource | Abbreviation | Name |
|----------|-------------|------|
| Resource Group | `rg` | `rg-wkld-stamp-1-dev` |
| App Service Plan | `asp` | `asp-wkld-1-dev` |
| Function App | `func` | `func-wkld-1-api-dev` (app slug `api` hardcoded in `phase1/env/workload.tf`) |
| Storage Account | `st` | `stwkld1dev` |
| Application Insights | `appi` | `appi-wkld-1-dev` |
| Key Vault | `kv` | `kv-wkld-1-dev` |

### Terraform Implementation

**`phase1/core/`** — environment-agnostic, deployed once. No workspace; no `environment` local. Core resources use a simple `name_suffix = "core"`:

```hcl
# phase1/core/main.tf locals
locals {
  name_suffix = "core"  # → rg-core, vnet-core, law-core, acrcore, etc.
}

# All environments' stamp subnets declared in one list:
variable "stamp_subnets" {
  type = list(object({
    environment     = string
    stamp_name      = string
    subnet_pe_cidr  = string
    subnet_asp_cidr = string
  }))
}

# One workload-stamp-subnet module instance per entry:
module "workload_stamp_subnet" {
  for_each = { for s in var.stamp_subnets : "${s.environment}-${s.stamp_name}" => s }
  source   = "../../modules/workload-stamp-subnet"
  environment  = each.value.environment
  stamp_name   = each.value.stamp_name
  stamp_index  = local.stamp_index[each.key]  # deterministic 0-based index for NSG priority offsets
  # ...
}
```

**`phase1/env/`** — workspace-driven (`dev`/`prod`). Environment derived from workspace name. `stamps` is a list (not a map):

```hcl
# phase1/env/main.tf locals
locals {
  workload    = "wkld"
  environment = terraform.workspace == "default" ? "dev" : terraform.workspace
  name_suffix = "${local.workload}-shared-${local.environment}"   # e.g. "wkld-shared-dev"
}

# Stamps as a list; converted to map for for_each in workload.tf:
variable "stamps" {
  type = list(object({
    stamp_name = string
    location   = string
    image_name = string
    image_tag  = optional(string, "latest")
  }))
}

module "workload_stamp" {
  for_each = { for s in var.stamps : s.stamp_name => s }
  source   = "../../modules/workload-stamp"

  stamp_number = tonumber(each.key)
  # Function App name: func-wkld-<stamp_name>-api-<env>
  function_apps = {
    "func-${local.workload}-${each.key}-api-${local.environment}" = {
      registry_url = local.core.acr_login_server
      image_name   = each.value.image_name
      image_tag    = each.value.image_tag
    }
  }
  # Subnet IDs come from core remote state — named by convention:
  subnet_id                  = local.core.subnet_ids["snet-stamp-${local.environment}-${each.key}-asp"]
  private_endpoint_subnet_id = local.core.subnet_ids["snet-stamp-${local.environment}-${each.key}-pe"]
}
```

Inside the workload-stamp module, `stamp_number` is a `number`:

```hcl
variable "stamp_number" {
  type = number
}

locals {
  stamp_prefix       = "${var.workload_name}-${var.stamp_number}-${var.environment}"  # e.g. "wkld-1-dev"
  stamp_prefix_clean = "${var.workload_name}${var.stamp_number}${var.environment}"    # e.g. "wkld1dev"
}
```

### Workspace Workflow

```bash
# ── phase1/core — deploy ONCE (no workspace) ──────────────────────────────
terraform -chdir=terraform/phase1/core init -backend-config=backend.hcl
terraform -chdir=terraform/phase1/core apply

# ── phase1/env — workspace-driven ─────────────────────────────────────────
# Create workspaces (one-time):
terraform -chdir=terraform/phase1/env workspace new dev
terraform -chdir=terraform/phase1/env workspace new prod

# Deploy dev:
terraform -chdir=terraform/phase1/env workspace select dev
terraform -chdir=terraform/phase1/env apply \
  -var-file=terraform.tfvars -var-file=dev.tfvars

# Deploy prod:
terraform -chdir=terraform/phase1/env workspace select prod
terraform -chdir=terraform/phase1/env apply \
  -var-file=terraform.tfvars -var-file=prod.tfvars
```

State is automatically namespaced per workspace by the azurerm backend (`env:/dev/...`, `env:/prod/...`). The core state key is a single flat `phase1-core.tfstate`.

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
- NSG flow logs disabled (`flow_logs_enabled = false`). Azure blocked new NSG flow log creation from June 2025. The module retains flow log resource definitions gated behind the flag.

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
| `websites_zone_id` | `privatelink.azurewebsites.net` | Function App (private endpoint) || `apim_zone_id` | `azure-api.net` | APIM internal VNet mode (gateway hostname resolution) |
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
| `apim_zone_id` | Zone ID for APIM internal VNet mode hostname resolution. |
| `all_zone_ids` | `list(string)` — convenience output for bulk VNet linking. |

> **Note:** VNet linking is handled by the `modules/vnet` module, which accepts `private_dns_zones` (a map of zone name → zone ID) and creates the link resources. This keeps DNS zone *creation* and DNS zone *linking* cleanly separated.

---

### 3. `modules/workload-stamp-subnet`

**Purpose:** Create one PE subnet + one ASP subnet for a single workload stamp, along with their NSGs, all per-stamp NSG rules, and cross-cutting NSG rules on the shared infrastructure NSGs (APIM, shared-PE, runner, jumpbox). Called once per stamp entry in `var.stamp_subnets`.

**Why a module:** Per-stamp subnets and their NSG rules depend on the environment and stamp number. Encapsulating this logic avoids 200+ lines of for_each rules in the root `network.tf`. Adding a stamp is one new entry in `terraform.tfvars`; the module generates all required subnets and firewall rules automatically.

#### Inputs

| Variable | Type | Description |
|----------|------|-------------|
| `environment` | `string` | Environment name (e.g. `dev`). Included in subnet and NSG names. |
| `stamp_name` | `string` | Numeric stamp identifier (e.g. `"1"`). |
| `stamp_index` | `number` | 0-based sorted index of this stamp — used for NSG rule priority offsets to avoid collisions when multiple stamps exist. |
| `subnet_pe_cidr` | `string` | CIDR for the PE subnet. |
| `subnet_asp_cidr` | `string` | CIDR for the ASP subnet. |
| `vnet_name` | `string` | Name of the VNet to add subnets to. |
| `resource_group_name` | `string` | Resource group (must be `rg-core`). |
| `nsg_name_prefix` | `string` | Prefix for NSG names (derived as `replace(vnet_name, "vnet-", "nsg-")` = `"nsg-core"`). |
| `shared_subnet_cidrs` | `object` | CIDRs for APIM, shared-pe, runner, jumpbox — used in cross-cutting NSG rules. |
| `shared_nsg_names` | `object` | Names of the shared NSGs — rules targeting stamp subnets are attached to these. |
| `log_analytics_*` / `flow_log_*` | various | NSG flow log config. |

#### Outputs

| Output | Description |
|--------|-------------|
| `pe_subnet_id` | ID of `snet-stamp-<env>-<N>-pe`. |
| `asp_subnet_id` | ID of `snet-stamp-<env>-<N>-asp`. |
| `pe_nsg_id`, `pe_nsg_name` | NSG for the PE subnet. |
| `asp_nsg_id`, `asp_nsg_name` | NSG for the ASP subnet. |

---

### 4. `modules/workload-stamp`

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
| `asp_sku` | `string` | App Service Plan SKU. Default: `P1v3` (overridden to `B1` in `phase1/env/workload.tf` for cost efficiency). |
| `function_apps` | `map(object)` | Map of Function App definitions. Each: `image` (ACR image ref), `app_settings` (map). |
| `subnet_id` | `string` | Subnet ID for App Service Plan VNet integration (must be delegated to `Microsoft.Web/serverFarms`). |
| `private_endpoint_subnet_id` | `string` | Subnet ID for Private Endpoints. |
| `acr_id` | `string` | ACR resource ID (for role assignment — AcrPull). |
| `key_vault_id` | `string` | *(Removed — Key Vault is created inside the module, not passed in.)* |
| `log_analytics_workspace_id` | `string` | Log Analytics Workspace ID for diagnostic settings. |
| `private_dns_zone_ids` | `object` | Object containing relevant zone IDs (blob, file, table, queue, websites, key_vault) from `modules/private-dns`. |
| `entra_app_client_id` | `string` | Application (client) ID of the Entra ID app registration for this stamp's Function App. Used to configure EasyAuth (auth_settings_v2). |
| `apim_principal_id` | `string` | Object ID of the APIM system-assigned managed identity. Granted Key Vault Certificate User and Secrets User so APIM can retrieve mTLS certs in Phase 3. |
| `admin_user_principal_name` | `string` | UPN of the Entra ID user to grant Key Vault Secrets Officer on this stamp’s Key Vault. |
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
- **Diagnostic settings**: Created for Function App(s) (FunctionAppLogs) and Key Vault (AuditEvent) \u2014 streaming to the supplied Log Analytics Workspace.
- **Role assignments**: AcrPull on the ACR, Key Vault Secrets User on Key Vault (for Function App MI), Key Vault Certificate User + Secrets User on Key Vault (for APIM MI), Key Vault Administrator (for CI/CD SP), Key Vault Secrets Officer (for admin user), Storage Blob Data Owner / Queue Data Contributor / Table Data Contributor (for Function App MI) — granted to each Function App's Managed Identity or the relevant principal.

---

## Root-Level Resources (No Module)

These resources exist once per deployment and do not benefit from modularisation. They are defined directly in the Phase 1 or Phase 3 root configuration.

### `phase1/core/` — Deploy once (no workspace)

| Resource | File | Resource Group | Notes |
|----------|------|---------------|-------|
| Core Resource Group | `resource-groups.tf` | — | `rg-core`. Pre-created deploy RG: `rg-core-deploy` (manual, holds state). |
| Module call: `modules/private-dns` | `dns.tf` | `rg-core` | Creates all 8 Private DNS Zones (7 privatelink zones + `azure-api.net` for APIM). Linked to VNet by `modules/vnet`. |
| Module call: `modules/vnet` | `network.tf` | `rg-core` | Creates `vnet-core` (`10.100.0.0/16`), 4 fixed shared subnets, their NSGs, DNS zone links (all 8 zones), NAT GW association (to all subnets). |
| Module call: `modules/workload-stamp-subnet` (for_each) | `network.tf` | `rg-core` | One instance per `var.stamp_subnets` entry. Creates `snet-stamp-<env>-<N>-pe/asp`, NSGs, all per-stamp and cross-cutting NSG rules. |
| NSG rules — shared subnets | `network.tf` | `rg-core` | APIM, shared-PE, runner, jumpbox static NSG rules. Stamp-referencing cross-cutting rules are delegated to the module above. |
| NAT Gateway + Public IP | `network.tf` | `rg-core` | `nat-core` + `pip-nat-core`. Associated to all subnets via `modules/vnet` (`attach_nat_gateway = true`). NSG rules control which subnets can actually reach the internet. |
| Azure Container Registry | `acr.tf` | `rg-core` | `acrcore<sub-hex>` — single shared ACR, Premium SKU, no public access. |
| Log Analytics Workspace | `observability.tf` | `rg-core` | `law-core`. |
| Self-signed CA + client cert | `certificates.tf` | — | `tls` provider generates cert objects in Terraform state. KV write deferred to Phase 3. |
| CI/CD Identity | `identity.tf` | — | `data.azurerm_client_config` to detect the CI/CD SP for downstream role assignments. |
| Jump Box VM | `jumpbox.tf` | `rg-core` | `vm-jumpbox-core` — Windows 11 + Entra ID auth + `pip-jumpbox-core` for RDP. Custom Script Extension downloads and runs `Setup-Jumpbox.ps1` (installs Azure CLI, Git). |
| Self-Hosted Runner VM | `runner.tf` | `rg-core` | `vm-runner-core` — Ubuntu 22.04 + Entra ID SSH + Custom Script Extension (`setup-runner.sh`). Break-glass SSH key generated via `tls_private_key`. |

### `phase1/env/` — Workspace-driven (dev / prod)

*Resource names below use `dev` workspace as an example.*

| Resource | File | Resource Group | Notes |
|----------|------|---------------|-------|
| Resource Groups | `resource-groups.tf` | — | `rg-wkld-shared-dev` + one `rg-wkld-stamp-<N>-dev` per stamp (via `for_each`). |
| API Management | `apim.tf` | `rg-wkld-shared-dev` | `apim-wkld-shared-dev` — Developer tier, internal VNet mode, system-assigned MI. Private DNS A record in `azure-api.net` zone. Diagnostic settings: GatewayLogs + WebSocketConnectionLogs. |
| Entra ID App Registrations | `entra.tf` | — | One `azuread_application` + `azuread_service_principal` per stamp per environment. Display name: `app-func-wkld-<N>-api-<env>`. Identifier URI: `api://<tenant_id>/func-wkld-<N>-api-<env>`. |
| Module call: `modules/workload-stamp` (for_each) | `workload.tf` | `rg-wkld-stamp-<N>-dev` | One per stamp in `var.stamps`. ASP SKU overridden to `B1`. Subnet IDs resolved from core remote state by name convention. Function App: `func-wkld-<N>-api-dev`. |

### Phase 3 — Private Data-Plane Operations (self-hosted VNet runner)

| Resource / Action | File | Notes |
|-------------------|------|-------|
| Container image build + push to ACR | CI/CD step | Not Terraform — Docker build + `az acr login` + push. |
| Key Vault secrets / certificates | `secrets.tf` | Writes CA cert, client cert, client private key, and deploy webhook URLs into each stamp\u2019s Key Vault. Data-plane op \u2014 requires the VNet-injected runner. |
| APIM backend + API + mTLS policy | `apim-config.tf` | Wire APIM to Function App backend(s). Configure client cert validation policy using the CA cert from Key Vault. |
| Monitor alert rules | `alerts.tf` | Alert on 5xx rate, availability test failures. Action group with email/webhook. |
| Availability test | `alerts.tf` | App Insights standard web test against Function App health endpoint (via APIM or direct). |

---

## Module Interaction Diagram

```
phase1/core/ (deployed once)
│
├── module "private_dns"   (modules/private-dns)
│       ↓ outputs: zone IDs (named attributes) + all_zone_ids list
│
├── module "vnet"          (modules/vnet)
│   │   ↑ consumes: private_dns.all_zone_ids (for VNet linking)
│   │   ↑ consumes: nat_gateway.id (for snet-runner association)
│   │   ↓ outputs: subnet_ids map, nsg_ids map, nsg_names map
│   │
├── module "workload_stamp_subnet" [for_each = stamp_subnets] (modules/workload-stamp-subnet)
│   │   ↑ consumes: vnet.vnet_name, vnet.nsg_names (for cross-cutting rules)
│   │   ↓ outputs: pe/asp subnet IDs, NSG IDs/names
│   │
├── azurerm_container_registry          (inline — acr.tf)
│   │   ↑ consumes: vnet.subnet_ids["snet-shared-pe"], private_dns.acr_zone_id
│   │
├── azurerm_log_analytics_workspace     (inline — observability.tf)
│   │   Also creates: azurerm_storage_account.diag (for NSG flow logs)
│   │
├── azurerm_windows_virtual_machine     (inline — jumpbox.tf)
│   │   ↑ consumes: vnet.subnet_ids["snet-jumpbox"]
│   │
└── azurerm_network_security_rule(s)    (inline — network.tf)
        NSG rules for fixed shared subnets (APIM, shared-pe, runner, jumpbox)


phase1/env/ (workspace-driven: dev / prod)
│   reads core/ outputs via terraform_remote_state
│
├── azurerm_api_management              (inline — apim.tf)
│   │   ↑ consumes: core.subnet_ids["snet-apim"]
│   │
└── module "workload_stamp" [for_each = stamps_map] (modules/workload-stamp)
        ↑ consumes: core.subnet_ids["snet-stamp-<env>-<N>-asp/pe"]
                    core.acr_id, core.log_analytics_workspace_id
                    core.private_dns_zone_ids (blob/file/table/queue/websites/key_vault)
                    apim.identity.principal_id, 
        Deploys per stamp: ASP, Function App, Storage, App Insights,
                           Key Vault (per-stamp), all Private Endpoints, role assignments
```

---

## Directory Structure

```
terraform/
  modules/
    private-dns/
      main.tf           # 8 Private DNS zone resources (7 privatelink + azure-api.net)
      outputs.tf        # Named zone ID outputs + all_zone_ids list
      variables.tf
      providers.tf
    vnet/
      main.tf           # VNet, fixed subnets, NSGs, DNS zone links, NAT GW assoc (all subnets)
      outputs.tf        # vnet_id, subnet_ids, nsg_ids, nsg_names
      variables.tf
      providers.tf
    workload-stamp-subnet/
      main.tf           # PE + ASP subnets, 2 NSGs
      nsg-rules.tf      # All per-stamp NSG rules + cross-cutting rules on shared NSGs
      outputs.tf        # subnet IDs, NSG IDs/names
      variables.tf
      providers.tf
    workload-stamp/
      main.tf           # ASP, Function App(s), Storage, App Insights
      keyvault.tf       # Key Vault (per-stamp) + KV Private Endpoint
      identity.tf       # Role assignments (AcrPull, KV roles for func/APIM/admin/CI-CD, Storage roles)
      private-endpoints.tf  # Storage × 4 + Function App PEs
      diagnostics.tf    # Diagnostic settings (Function App + Key Vault)
      data.tf           # data.azurerm_client_config for CI/CD SP, data.azuread_user for admin UPN
      outputs.tf
      variables.tf
      providers.tf
  phase1/
    core/               # Deployed ONCE — no workspace
      main.tf           # Provider config, backend, locals (name_suffix = "core")
      resource-groups.tf  # rg-core
      dns.tf            # module "private_dns"
      network.tf        # module "vnet" + module "workload_stamp_subnet" (for_each) + NSG rules
      acr.tf            # acrcore + PE
      observability.tf  # law-core
      certificates.tf   # tls CA + client cert generation
      jumpbox.tf        # vm-jumpbox-core + NIC + PIP + AAD extension + CSE (Setup-Jumpbox.ps1)
      runner.tf         # vm-runner-core + NIC + AAD SSH extension + CSE (setup-runner.sh)
      identity.tf       # data.azurerm_client_config (CI/CD SP detection)
      data.tf           # data lookups
      providers.tf
      variables.tf      # stamp_subnets, jumpbox vars, runner vars
      outputs.tf
      terraform.tfvars  # ALL values: subscription, location, jumpbox, all stamp_subnets
    env/                # Workspace-driven: dev / prod
      main.tf           # Provider config, backend, remote state (reads core)
      resource-groups.tf  # rg-wkld-shared-<env> + per-stamp RGs
      apim.tf           # apim-wkld-shared-<env> + Private DNS A record + diagnostics
      entra.tf          # azuread_application + azuread_service_principal per stamp
      workload.tf       # module "workload_stamp" (for_each over stamps, asp_sku = "B1")
      data.tf           # Remote state data source
      providers.tf
      variables.tf      # stamps list, APIM publisher, state_storage_account_name
      outputs.tf
      terraform.tfvars  # Shared values (subscription, location, APIM publisher)
      dev.tfvars        # dev stamps (stamp_name, image_name, image_tag, location)
      prod.tfvars
  phase3/               # Workspace-driven: dev / prod
    env/                # Phase 3 resources live under env/ subdirectory
      main.tf           # Provider config, backend, remote state (reads core + env)
      secrets.tf        # CA cert, client cert, client key, webhook URL writes to per-stamp KVs
      apim-config.tf    # APIM backends, API, operations, mTLS + MI auth policy
      alerts.tf         # Monitor metric alerts, action groups
      data.tf           # Remote state data sources
      providers.tf
      variables.tf
      outputs.tf
      terraform.tfvars  # Shared values
      dev.tfvars
      prod.tfvars
    terraform.tfvars    # Top-level shared vars (state_storage_account_name)
```

---

## Summary

| Item | Implementation | Justification |
|------|---------------|---------------|
| Private DNS Zones | **Module** (`modules/private-dns`) | Consumed by every private endpoint. Named outputs make zone IDs trivial to reference. |
| VNet / Fixed Subnets / NSGs | **Module** (`modules/vnet`) | Subnet definitions are data-driven (list of objects). |
| Per-Stamp Subnets + NSG Rules | **Module** (`modules/workload-stamp-subnet`) | Per-stamp subnet pair + 200+ lines of NSG rules repeated once per stamp. Module-ising eliminates duplication and enables priority-offset collision avoidance. |
| Workload Stamp (ASP + Function App + Storage + App Insights + Key Vault + PEs) | **Module** (`modules/workload-stamp`) | Primary unit of repeatability. Multi-env / multi-region = multiple stamp instances. Key Vault moved inside stamp for per-stamp HA boundary. |
| ACR | **Root inline** (`phase1/core/acr.tf`) | Single shared instance across all environments. No reuse case. |
| APIM | **Root inline** (`phase1/env/apim.tf`) | Single per-env instance; shared front door. |
| Log Analytics | **Root inline** (`phase1/core/observability.tf`) | Single shared instance. Central sink. |
| Certificates | **Root inline** (`phase1/core/certificates.tf`) | One-time generation via `tls` provider. KV write deferred to Phase 3. |
| Jump Box VM | **Root inline** (`phase1/core/jumpbox.tf`) | Single shared instance. Developer connectivity tool. |
| Alert Rules / Availability Tests | **Root inline** (`phase3/alerts.tf`) | Defined once per environment. Data-plane op — Phase 3 only. |
| APIM Config (backends, API, policy) | **Root inline** (`phase3/apim-config.tf`) | Defined once per environment. Requires private KV + Function App PE access. |
