# Implementation Planning — Modules & Root Resources

Which Terraform resources are modules and which are root-level, and why.

---

## Decision Framework

| Criterion | Module? | Rationale |
|-----------|---------|-----------|
| Exists exactly once (ACR, APIM, LAW) | No | Indirection with no reuse benefit. |
| Repeatable stamp (Function App + ASP + Storage + KV) | Yes | Future envs/regions = another `module` block. |
| Cross-cutting concern (DNS zones) | Yes | Centralises creation, exports named zone IDs. |
| VNet + subnets + NSGs | Yes | Data-driven subnet definitions keep things DRY. |

---

## Naming Convention

All resources follow `<abbreviation>-<workload>-<tier>[-<environment>]`. Workload name: **`wkld`**.

| Tier | Pattern | Env suffix? | Examples |
|------|---------|-------------|---------|
| **Core** | `<abbr>-core` | No | `rg-core`, `vnet-core`, `law-core`, `acrcore<hex>` |
| **Shared env** | `<abbr>-wkld-shared-<env>` | Yes | `apim-wkld-shared-dev` |
| **Stamp** | `<abbr>-wkld-<N>-<env>` | Yes | `asp-wkld-1-dev`, `func-wkld-1-api-dev`, `kv-wkld-1-dev` |

Storage accounts drop hyphens (`stwkld1dev`). ACR uses a subscription-ID hex prefix for global uniqueness (`acrcore<8hex>`). NSG names derive from VNet name: `nsg-core-<suffix>`.

Global uniqueness collisions are accepted as unlikely — a clash at `apply` time is immediately obvious and resolvable.

---

## Workspace Workflow

```bash
# phase1/core — deploy ONCE (no workspace)
terraform -chdir=terraform/phase1/core init -backend-config=backend.hcl
terraform -chdir=terraform/phase1/core apply

# phase1/env — workspace-driven
terraform -chdir=terraform/phase1/env workspace select dev
terraform -chdir=terraform/phase1/env apply -var-file=terraform.tfvars -var-file=dev.tfvars

# phase2/env — workspace-driven (self-hosted runner)
terraform -chdir=terraform/phase2/env workspace select dev
terraform -chdir=terraform/phase2/env apply -var-file=terraform.tfvars -var-file=dev.tfvars

# phase3 — deploy ONCE (not workspace-driven, reads all env workspaces)
terraform -chdir=terraform/phase3 apply -var-file=terraform.tfvars
```

State is namespaced per workspace by the azurerm backend. Core and phase3 state keys are flat.

---

## Modules

### `modules/vnet`

VNet, subnets, NSGs, NSG-to-subnet associations, optional NAT GW attachment, Private DNS Zone VNet links, optional NSG flow logs.

Takes a list of subnet objects — adding a subnet is a one-line change. Outputs `subnet_ids`, `nsg_ids`, and `nsg_names` as maps.

### `modules/private-dns`

Creates 8 Private DNS Zones (7 privatelink + `internal.contoso.com` for APIM). Exports each zone ID as a **named attribute** (e.g. `key_vault_zone_id`, `acr_zone_id`) plus a convenience `all_zone_ids` list.

### `modules/workload-stamp-subnet`

Creates one PE subnet + one ASP subnet for a single stamp, their NSGs, all per-stamp NSG rules, and cross-cutting rules on the shared NSGs (APIM, shared-PE, runner, jumpbox). Called once per stamp via `for_each`.

Priority offsets (`stamp_index`) prevent NSG rule collisions when multiple stamps exist.

### `modules/workload-stamp`

The repeatable compute unit. Deploys: App Service Plan, Function App(s) (containerised, Docker-based), Storage Account (no public access, 4 PEs), App Insights, Key Vault (RBAC mode, PE, diagnostics), all Private Endpoints, role assignments, diagnostic settings.

Security posture by default:
- System-assigned Managed Identity on every Function App
- `public_network_access_enabled = false` on Function App, Storage, Key Vault
- HTTPS only, TLS 1.2 minimum
- EasyAuth v2 with Entra ID validation (health endpoint excluded)
- Role assignments: AcrPull, KV Secrets User (func MI), KV Admin (CI/CD SP), KV Certificate+Secrets User (APIM MI), Storage Blob/Queue/Table roles (func MI)

---

## Root-Level Resources

### `phase1/core/` — Deploy once

| File | Resources |
|------|-----------|
| `resource-groups.tf` | `rg-core` |
| `dns.tf` | `modules/private-dns` (8 zones) |
| `network.tf` | `modules/vnet` (VNet, 4 fixed subnets, NSGs, DNS links, NAT GW), `modules/workload-stamp-subnet` (`for_each`), ~40 NSG rules for fixed subnets |
| `acr.tf` | ACR (Premium, no public access, PE, diagnostics) |
| `observability.tf` | Log Analytics Workspace (PerGB2018, self-diagnostic) |
| `certificates.tf` | TLS CA (RSA 4096) + client cert (RSA 2048) |
| `jumpbox.tf` | Windows 11 VM + NIC + Public IP + Entra ID extension + Custom Script Extension |
| `runner.tf` | Ubuntu 22.04 VM + NIC + Entra ID SSH extension + Custom Script Extension (`setup-runner.sh`) |

### `phase1/env/` — Workspace-driven (dev/prod)

| File | Resources |
|------|-----------|
| `resource-groups.tf` | `rg-wkld-shared-<env>` + per-stamp RGs |
| `apim.tf` | APIM (Developer, internal VNet, custom domain cert, diagnostic settings) + Private DNS A record |
| `entra.tf` | `azuread_application` + `azuread_service_principal` per stamp (EasyAuth audience) |
| `workload.tf` | `modules/workload-stamp` (`for_each`, ASP SKU overridden to B1) |

### `phase2/env/` — Workspace-driven, self-hosted runner

| File | Resources |
|------|-----------|
| `secrets.tf` | KV writes: CA cert, client cert/key, deploy webhook URLs |
| `apim-config.tf` | APIM backends, API, operations (health + message), load-balancing policy with MI auth |
| `alerts.tf` | Metric alerts, KQL scheduled queries, availability web tests, action groups |

### `phase3/` — Deploy once, reads all env workspaces

| File | Resources |
|------|-----------|
| `network.tf` | App GW subnet + NSG + cross-cutting NSG rules on phase1 NSGs |
| `keyvault.tf` | `kv-appgw-core` + User-Assigned MI + RBAC + PE + self-signed server cert |
| `appgw.tf` | Application Gateway (Standard_v2, autoscale, mTLS SSL profile, URL path routing per env) |

---

## Module Interaction

```
phase1/core/ ─────────────────────────────────────────────────
├── modules/private-dns → zone IDs
├── modules/vnet ← zone IDs, NAT GW ID → subnet_ids, nsg_ids
├── modules/workload-stamp-subnet [for_each] ← vnet outputs → pe/asp subnet IDs
├── ACR (inline) ← PE subnet, ACR zone ID
├── LAW (inline)
├── Jumpbox + Runner (inline)
└── outputs → consumed by phase1/env, phase2/env, phase3

phase1/env/ [workspace: dev|prod] ← core remote state
├── APIM (inline) ← APIM subnet
├── Entra ID app registrations [for_each stamps]
└── modules/workload-stamp [for_each stamps] ← subnet IDs, ACR, LAW, DNS zones, APIM MI
    └── outputs → consumed by phase2/env

phase2/env/ [workspace: dev|prod] ← core + env remote state
├── KV secrets (data-plane via VNet runner)
├── APIM config (backends, API, policies)
└── Alerts + web tests

phase3/ ← core + all env workspace remote states
├── App GW subnet + NSG
├── kv-appgw-core + server cert
└── Application Gateway (routes /api/<env>/* per environment)
```

---

## Directory Structure

```
terraform/
  modules/
    private-dns/     # 8 DNS zones, named outputs
    vnet/            # VNet, subnets, NSGs, DNS links, NAT GW
    workload-stamp-subnet/  # PE+ASP subnets, NSGs, cross-cutting rules
    workload-stamp/  # ASP, Function App, Storage, KV, App Insights, PEs, roles
  phase1/
    core/            # Deployed once — VNet, ACR, LAW, DNS, certs, VMs
    env/             # Workspace-driven — APIM, Entra, workload stamps
  phase2/
    env/             # Workspace-driven — secrets, APIM config, alerts (VNet runner)
  phase3/            # Deployed once — Application Gateway
```
