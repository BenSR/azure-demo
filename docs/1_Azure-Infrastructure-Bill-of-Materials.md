# Azure Infrastructure — Bill of Materials

Inventory of Azure resources by category, with SKU, naming, and deployment phase.

> **Naming tiers:** Core (`<abbr>-core`), Shared env (`<abbr>-wkld-shared-<env>`), Stamp (`<abbr>-wkld-<N>-<env>`).
> Examples below use `dev` environment with 2 stamps.

---

## 1. Resource Groups

| Name | Phase | Purpose |
|------|-------|---------|
| `rg-core-deploy` | Manual | Terraform state storage. Not managed by Terraform. |
| `rg-core` | Phase 1 (core) | Cross-env platform: ACR, VNet, LAW, DNS, NAT GW, VMs. |
| `rg-wkld-shared-<env>` | Phase 1 (env) | Per-env APIM. |
| `rg-wkld-stamp-<N>-<env>` | Phase 1 (env) | Per-stamp compute: ASP, Function App, Storage, App Insights, KV. |

## 2. Networking

| Resource | Type | SKU | Purpose | Phase |
|----------|------|-----|---------|-------|
| `vnet-core` | Virtual Network | — | Single shared VNet, `/16` address space | Phase 1 (core) |
| 4 fixed subnets | Subnet | — | Runner, jumpbox, APIM (delegated), shared PE | Phase 1 (core) |
| 2 subnets per stamp | Subnet | — | PE subnet + ASP subnet (delegated) per stamp per env | Phase 1 (core) |
| `snet-appgw` | Subnet | — | Application Gateway | Phase 3 |
| 1 NSG per subnet | NSG | — | Least-privilege rules, deny-all baseline | Phase 1/3 |
| `nat-core` + `pip-nat-core` | NAT GW + Public IP | Standard | Egress for runner (and jumpbox). Attached to all subnets, NSG-controlled. | Phase 1 (core) |

## 3. Private DNS Zones

8 zones created by `modules/private-dns`, all linked to the VNet:

| Zone | Used By |
|------|---------|
| `privatelink.vaultcore.azure.net` | Key Vault |
| `privatelink.blob.core.windows.net` | Storage (blob) |
| `privatelink.file.core.windows.net` | Storage (file) |
| `privatelink.table.core.windows.net` | Storage (table) |
| `privatelink.queue.core.windows.net` | Storage (queue) |
| `privatelink.azurecr.io` | ACR |
| `privatelink.azurewebsites.net` | Function App |
| `internal.contoso.com` | APIM custom domain |

## 4. Shared PaaS Services

| Resource | SKU | Purpose | Phase |
|----------|-----|---------|-------|
| `acrcore<hex>` (ACR) | **Premium** | Container images. No public access. PE in shared-PE subnet. | Phase 1 (core) |
| `apim-wkld-shared-<env>` | **Developer** | Per-env API front door. Internal VNet mode, custom domain, system-assigned MI. | Phase 1 (env) |
| `law-core` | **PerGB2018** | Central log sink. 30-day retention. | Phase 1 (core) |

## 5. Workload Stamp Resources (per stamp)

| Resource | SKU | Purpose | Phase |
|----------|-----|---------|-------|
| `asp-wkld-<N>-<env>` | **B1** | Linux ASP hosting Function App (overridden from P1v3 default) | Phase 1 (env) |
| `func-wkld-<N>-api-<env>` | — | Containerised Python Function App. MI, no public access, EasyAuth, VNet integrated. | Phase 1 (env) |
| `stwkld<N><env>` | **Standard_LRS** | Function App backing storage. No public access. 4 PEs (blob/file/table/queue). | Phase 1 (env) |
| `kv-wkld-<N>-<env>` | **Standard** | Per-stamp Key Vault. RBAC auth, no public access, PE. Stores certs and webhook URLs. | Phase 1 (env) |
| `appi-wkld-<N>-<env>` | — | Application Insights (workspace-based, backed by LAW). | Phase 1 (env) |
| Function App PE | — | Inbound private connectivity (APIM → Function App). | Phase 1 (env) |
| Storage PEs (×4) | — | Blob, file, table, queue private endpoints. | Phase 1 (env) |
| Key Vault PE | — | Private connectivity to stamp KV. | Phase 1 (env) |

## 6. VMs

| Resource | SKU | Purpose | Phase |
|----------|-----|---------|-------|
| `vm-jumpbox-core` | **Standard_B2s** | Windows 11, Entra ID RDP, public IP. Custom Script Extension installs Azure CLI + Git. | Phase 1 (core) |
| `vm-runner-core` | **Standard_B2s** | Ubuntu 22.04, Entra ID SSH. Custom Script Extension installs Docker, Azure CLI, Node.js, GitHub runner agent. | Phase 1 (core) |

## 7. Application Gateway (Phase 3)

| Resource | SKU | Purpose | Phase |
|----------|-----|---------|-------|
| App Gateway + Public IP | **Standard_v2** (autoscale 1-2) | Public ingress with mTLS. URL path routing per env (`/api/<env>/*`). | Phase 3 |
| `kv-appgw-core` | **Standard** | Dedicated KV for App GW server cert. RBAC, PE. | Phase 3 |
| User-Assigned MI | — | App GW → KV cert access. | Phase 3 |

## 8. Certificates

| Artefact | Type | Purpose | Phase |
|----------|------|---------|-------|
| Self-signed CA | `tls_self_signed_cert` | mTLS truststore (APIM + App GW) | Phase 1 (generated) → Phase 2 (KV write) |
| Client cert (CA-signed) | `tls_locally_signed_cert` | Client-side mTLS cert for API consumers | Phase 1 (generated) → Phase 2 (KV write) |
| App GW server cert | KV-generated (Self issuer) | TLS server cert for App GW listener | Phase 3 |

## 9. Identity & Role Assignments

| Principal | Scope | Roles | Phase |
|-----------|-------|-------|-------|
| Function App MI | ACR | AcrPull | Phase 1 (env) |
| Function App MI | Stamp KV | Key Vault Secrets User | Phase 1 (env) |
| Function App MI | Stamp Storage | Blob Data Owner, Queue/Table Data Contributor | Phase 1 (env) |
| APIM MI | Stamp KV | Certificate User + Secrets User | Phase 1 (env) |
| CI/CD SP | Stamp KV | Key Vault Administrator | Phase 1 (env) |
| Admin user | Stamp KV | Key Vault Secrets Officer | Phase 1 (env) |
| App GW MI | `kv-appgw-core` | Key Vault Secrets User | Phase 3 |
| Entra app registration | — | Token audience for EasyAuth (one per stamp per env) | Phase 1 (env) |

## 10. Diagnostic Settings

All resources stream to `law-core`:

| Resource | Log Categories |
|----------|---------------|
| Function App | FunctionAppLogs |
| Key Vault | AuditEvent |
| APIM | GatewayLogs, WebSocketConnectionLogs |
| ACR | LoginEvents, RepositoryEvents |
| LAW | Audit (self-diagnostic) |
| Storage (per service ×4) | StorageRead/Write/Delete + Transaction metrics |

NSG flow logs are disabled (Azure blocked new creation from June 2025).

## 11. Monitoring & Alerting (Phase 2)

| Resource | Purpose |
|----------|---------|
| Action Group | Email receivers for all alerts |
| Metric alert (per stamp) | Function App request failure count |
| Scheduled query alert (per stamp) | KQL query for HTTP 5xx status codes |
| Availability web test (per stamp) | Health endpoint probe (disabled by default — APIM is internal) |
| Availability metric alert (per stamp) | Fires when web test availability drops below threshold |

## 12. APIM Configuration (Phase 2)

| Resource | Purpose |
|----------|---------|
| Named Value | Client cert thumbprint for mTLS validation |
| Backends (per stamp) | Function App PE HTTPS endpoints |
| API + Operations | health-check (GET), post-message (POST) |
| API Policy | Random stamp load-balancing, MI token acquisition, client cert validation |

## Resource Count Summary (dev, 2 stamps)

| Category | Count |
|----------|-------|
| Resource Groups (TF-managed) | 4 |
| VNet / Subnets / NSGs | 1 / 9 / 9 |
| NAT GW + Public IPs | 1 + 3 (NAT, jumpbox, App GW) |
| Private DNS Zones + Links | 8 + 8 |
| Private Endpoints | 13 (ACR + 2×[func + storage×4 + KV] + App GW KV) |
| PaaS (ACR, APIM, LAW) | 3 |
| Per-stamp resources (×2) | ASP, Func, Storage, KV, App Insights |
| VMs | 2 (jumpbox + runner) |
| App Gateway + KV | 2 |
| Certificates | 3 (CA, client, server) |
| Entra app registrations | 2 |
| Role assignments | ~22 |
| Diagnostic settings | ~20 |
| Alerts + action group | ~7 |
| **Total (approximate)** | **~130** |

## SKU Summary

| Resource | SKU | Rationale |
|----------|-----|-----------|
| ACR | Premium | Required for Private Endpoint support |
| APIM | Developer | Assessment constraint. Not for production (no SLA). |
| ASP | B1 | Cost efficiency (overridden from P1v3 module default) |
| App GW | Standard_v2 | Autoscale L7 LB. Use WAF_v2 in production. |
| VMs | Standard_B2s | Burstable, minimal footprint |
| Storage | Standard_LRS | Sufficient for single-region assessment |
| Key Vault | Standard | No HSM needed |
| LAW | PerGB2018 | Pay-as-you-go |
