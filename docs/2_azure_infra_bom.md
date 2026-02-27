# Azure Infrastructure — Bill of Materials

Complete inventory of every Azure resource expected to be created, including SKU, naming, purpose, and deployment phase.

> **Workload name:** `wkld` · **Naming conventions:**
> - **Core** (deployed once, shared): `<abbr>-core` or `<abbr>core` (e.g. `rg-core`, `acrcore`, `law-core`). No workload prefix, no env suffix.
> - **Shared env** (per-environment): `<abbr>-wkld-shared-<env>` (e.g. `rg-wkld-shared-dev`, `apim-wkld-shared-dev`)
> - **Stamp** (per-stamp, per-environment): `<abbr>-wkld-<N>-<env>` (e.g. `rg-wkld-stamp-1-dev`, `asp-wkld-1-dev`, `kv-wkld-1-dev`)
>
> **Example environment:** `dev` · **VNet:** `vnet-core` (`10.100.0.0/16`)

---

## 1. Resource Groups

| # | Resource Name | Type | Naming tier | Purpose | Phase |
|---|--------------|------|-------------|---------|-------|
| — | `rg-core-deploy` | *(manually created)* | — | Holds all Terraform state storage accounts. Created once before any `terraform init`. Not managed by Terraform. | Pre-Phase 1 |
| 1 | `rg-core` | `azurerm_resource_group` | Core | Cross-environment platform resources: ACR, Log Analytics, VNet, NSGs, NAT GW, Private DNS, Jump box. Deployed once, shared. | Phase 1 (core) |
| 2 | `rg-wkld-shared-dev` | `azurerm_resource_group` | Shared env | Per-environment shared infra: APIM only (Key Vault moved per-stamp). | Phase 1 (env) |
| 3 | `rg-wkld-stamp-1-dev` | `azurerm_resource_group` | Stamp | Per-stamp compute: ASP, Function App, Storage, App Insights, Key Vault, stamp Private Endpoints. | Phase 1 (env) |

> **Three-layer model:** `rg-core` (shared cross-env), `rg-wkld-shared-<env>` (per-env APIM), `rg-wkld-stamp-<N>-<env>` (per-stamp compute). One manual `rg-core-deploy` holds all state.

---

## 2. Networking

### 2.1 Virtual Network

| # | Resource Name | Type | SKU / Tier | Address Space | Purpose | Phase |
|---|--------------|------|------------|---------------|---------|-------|
| 2 | `vnet-core` | `azurerm_virtual_network` | N/A (free) | `10.100.0.0/16` | Single shared VNet hosting all environments' subnets (stamp subnets named with env prefix to coexist). Deployed once. | Phase 1 (core) |

### 2.2 Subnets

**Fixed subnets** (created by `modules/vnet`, one per VNet):

| # | Subnet Name | Type | CIDR | Usable IPs | Delegation | Purpose | Phase |
|---|------------|------|------|------------|------------|---------|-------|
| 3 | `snet-runner` | `azurerm_subnet` | `10.100.128.0/24` | 251 | `GitHub.Network/networkSettings` | GitHub Actions VNet-injected runner. NAT Gateway attached. | Phase 1 (core) |
| 4 | `snet-jumpbox` | `azurerm_subnet` | `10.100.129.0/27` | 27 | None | Windows 11 jump box VM for developer connectivity. | Phase 1 (core) |
| 5 | `snet-apim` | `azurerm_subnet` | `10.100.129.32/27` | 27 | `Microsoft.ApiManagement/service` | API Management internal VNet mode. | Phase 1 (core) |
| 6 | `snet-shared-pe` | `azurerm_subnet` | `10.100.130.0/24` | 251 | None | Private Endpoints for ACR. PE network policies enabled. | Phase 1 (core) |

**Per-stamp subnets** (created by `modules/workload-stamp-subnet`, one pair per stamp per environment):

| # | Subnet Name | Type | CIDR | Usable IPs | Delegation | Purpose | Phase |
|---|------------|------|------|------------|------------|---------|-------|
| 7 | `snet-stamp-dev-1-pe` | `azurerm_subnet` | `10.100.0.0/24` | 251 | None | PEs: Function App, Storage × 4, Key Vault. PE network policies enabled. | Phase 1 (core) |
| 8 | `snet-stamp-dev-1-asp` | `azurerm_subnet` | `10.100.1.0/24` | 251 | `Microsoft.Web/serverFarms` | App Service Plan VNet integration — Function App outbound traffic. | Phase 1 (core) |
| — | `snet-stamp-dev-2-pe` | `azurerm_subnet` | `10.100.2.0/24` | 251 | None | Dev stamp 2 PE subnet. | Phase 1 (core) |
| — | `snet-stamp-dev-2-asp` | `azurerm_subnet` | `10.100.3.0/24` | 251 | `Microsoft.Web/serverFarms` | Dev stamp 2 ASP subnet. | Phase 1 (core) |
| — | `snet-stamp-test-1-pe` | `azurerm_subnet` | `10.100.4.0/24` | 251 | None | Test stamp 1 PE subnet. | Phase 1 (core) |
| — | `snet-stamp-prod-1-pe` | `azurerm_subnet` | `10.100.6.0/24` | 251 | None | Prod stamp 1 PE subnet. | Phase 1 (core) |

### 2.3 Network Security Groups

One NSG per subnet, each with a default `DenyAll` at priority 4096 and only the minimum required allow rules. Detailed rule sets are documented in the network technical design.

**Fixed subnet NSGs** (created by `modules/vnet`, names derived as `nsg-core-<subnet-minus-snet-prefix>`):

| # | NSG Name | Type | Attached To | Phase |
|---|---------|------|-------------|-------|
| 9 | `nsg-core-runner` | `azurerm_network_security_group` | `snet-runner` | Phase 1 (core) |
| 10 | `nsg-core-jumpbox` | `azurerm_network_security_group` | `snet-jumpbox` | Phase 1 (core) |
| 11 | `nsg-core-apim` | `azurerm_network_security_group` | `snet-apim` | Phase 1 (core) |
| 12 | `nsg-core-shared-pe` | `azurerm_network_security_group` | `snet-shared-pe` | Phase 1 (core) |

**Per-stamp NSGs** (created by `modules/workload-stamp-subnet`):

| # | NSG Name | Type | Attached To | Phase |
|---|---------|------|-------------|-------|
| 13 | `nsg-core-stamp-dev-1-pe` | `azurerm_network_security_group` | `snet-stamp-dev-1-pe` | Phase 1 (core) |
| 14 | `nsg-core-stamp-dev-1-asp` | `azurerm_network_security_group` | `snet-stamp-dev-1-asp` | Phase 1 (core) |

### 2.4 NAT Gateway

| # | Resource Name | Type | SKU | Purpose | Associated Subnet | Phase |
|---|--------------|------|-----|---------|-------------------|-------|
| 15 | `nat-core` | `azurerm_nat_gateway` | Standard | Deterministic egress for the GitHub Runner — the only resource requiring internet access. | `snet-runner` | Phase 1 (core) |
| 16 | `pip-nat-core` | `azurerm_public_ip` | Standard, Static | Static public IP for NAT Gateway egress. | — | Phase 1 (core) |

---

## 3. Private DNS Zones

Each Private Endpoint–backed service requires a corresponding DNS zone linked to the VNet. Created by the `modules/private-dns` module.

> **Note:** APIM in internal VNet mode does not use a Private Endpoint — it is injected directly into a delegated subnet. The APIM gateway FQDN resolves to its private IP automatically via Azure DNS in internal VNet mode; no `privatelink.azure-api.net` zone is required. That zone is a Premium-tier Private Endpoint feature and is not applicable here.

| # | Zone Name | Type | Used By | Phase |
|---|----------|------|---------|-------|
| 17 | `privatelink.vaultcore.azure.net` | `azurerm_private_dns_zone` | Key Vault | Phase 1 |
| 18 | `privatelink.blob.core.windows.net` | `azurerm_private_dns_zone` | Storage Account (blob) | Phase 1 |
| 19 | `privatelink.file.core.windows.net` | `azurerm_private_dns_zone` | Storage Account (file share) | Phase 1 |
| 20 | `privatelink.table.core.windows.net` | `azurerm_private_dns_zone` | Storage Account (table) | Phase 1 |
| 21 | `privatelink.queue.core.windows.net` | `azurerm_private_dns_zone` | Storage Account (queue) | Phase 1 |
| 22 | `privatelink.azurecr.io` | `azurerm_private_dns_zone` | Azure Container Registry | Phase 1 |
| 23 | `privatelink.azurewebsites.net` | `azurerm_private_dns_zone` | Function App | Phase 1 |

### 3.1 Private DNS Zone VNet Links

One link resource per zone, binding it to the VNet so all subnets resolve Private Endpoint FQDNs via Azure DNS (`168.63.129.16`).

| # | Resource | Type | Purpose | Phase |
|---|---------|------|---------|-------|
| 24–30 | One `azurerm_private_dns_zone_virtual_network_link` per zone (×7) | `azurerm_private_dns_zone_virtual_network_link` | Enables in-VNet resolution of private endpoint DNS records. | Phase 1 |

---

## 4. Shared PaaS Services

### 4.1 Azure Container Registry

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 31 | `acrcore` | `azurerm_container_registry` | **Premium** | Hosts Docker images for Function App(s). Shared across all environments. | Admin disabled. Managed Identity pull only. `public_network_access_enabled = false`. Resource group: `rg-core`. | Phase 1 (core) |
| 32 | `pe-acr-core` | `azurerm_private_endpoint` | — | Private connectivity to ACR from VNet. | Subnet: `snet-shared-pe`. DNS zone group: `privatelink.azurecr.io`. Resource group: `rg-core`. | Phase 1 (core) |

### 4.3 API Management

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 33 | `apim-wkld-shared-dev` | `azurerm_api_management` | **Developer** | Per-env API front door. Terminates mTLS, routes to Function App backends, centralises request logging and policy enforcement. | Internal VNet mode. Deployed into `snet-apim` (delegated). No public endpoint. System-assigned MI. | Phase 1 (env) |

### 4.4 Log Analytics Workspace + Diagnostic Storage

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 34 | `law-core` | `azurerm_log_analytics_workspace` | **PerGB2018** | Central log sink for all diagnostic settings, NSG flow logs, and App Insights backend. Shared across all environments. | 30 day retention. Resource group: `rg-core`. | Phase 1 (core) |
| 35 | `stdiagcore` | `azurerm_storage_account` | **Standard_LRS** | Raw blob storage for NSG flow logs (required by Network Watcher). | `public_network_access_enabled = true` (Network Watcher requires public write access). Resource group: `rg-core`. | Phase 1 (core) |

---

## 5. Workload Stamp Resources (Stamp 1)

All resources below are created by the `modules/workload-stamp` module for stamp number **1**.

### 5.1 Compute

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 36 | `asp-wkld-1-dev` | `azurerm_service_plan` | **P1v3** | Linux App Service Plan hosting the Function App. | P1v3 is the minimum SKU supporting VNet integration + Linux containers. Shared across Function Apps within the stamp. | Phase 1 (env) |
| 37 | `func-wkld-1-api-dev` | `azurerm_linux_function_app` | — (inherits ASP) | Python HTTP-triggered Function App, deployed as a Docker container from ACR. | System-assigned Managed Identity. `public_network_access_enabled = false`. HTTPS only. TLS 1.2 minimum. VNet integrated via `snet-stamp-dev-1-asp`. | Phase 1 (env) |

### 5.2 Storage

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 38 | `stwkld1dev` | `azurerm_storage_account` | **Standard_LRS** | Function App backing storage (triggers, state, logs). | `public_network_access_enabled = false`. TLS 1.2 minimum. Network rules deny all except VNet. | Phase 1 (env) |
| 39 | PE — blob | `azurerm_private_endpoint` | — | Private connectivity for blob storage. | Subnet: `snet-stamp-dev-1-pe`. DNS zone: `privatelink.blob.core.windows.net`. | Phase 1 (env) |
| 40 | PE — file | `azurerm_private_endpoint` | — | Private connectivity for file share storage. | Subnet: `snet-stamp-dev-1-pe`. DNS zone: `privatelink.file.core.windows.net`. | Phase 1 (env) |
| 41 | PE — table | `azurerm_private_endpoint` | — | Private connectivity for table storage. | Subnet: `snet-stamp-dev-1-pe`. DNS zone: `privatelink.table.core.windows.net`. | Phase 1 (env) |
| 42 | PE — queue | `azurerm_private_endpoint` | — | Private connectivity for queue storage. | Subnet: `snet-stamp-dev-1-pe`. DNS zone: `privatelink.queue.core.windows.net`. | Phase 1 (env) |

### 5.3 Function App Private Endpoint

| # | Resource Name | Type | Purpose | Details | Phase |
|---|--------------|------|---------|---------|-------|
| 43 | PE — Function App | `azurerm_private_endpoint` | Inbound private connectivity to Function App (APIM → Function App). | Subnet: `snet-stamp-dev-1-pe`. DNS zone: `privatelink.azurewebsites.net`. | Phase 1 (env) |

### 5.3b Key Vault (per stamp)

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 44 | `kv-wkld-1-dev` | `azurerm_key_vault` | **Standard** | Per-stamp Key Vault: stores CA cert, client cert, and app secrets. RBAC auth mode. Soft delete 7 days. `public_network_access_enabled = false`. | Resource group: `rg-wkld-stamp-1-dev`. | Phase 1 (env) |
| 45 | PE — Key Vault | `azurerm_private_endpoint` | — | Private connectivity to Key Vault. | Subnet: `snet-stamp-dev-1-pe`. DNS zone: `privatelink.vaultcore.azure.net`. | Phase 1 (env) |

### 5.4 Observability (per stamp)

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 46 | `appi-wkld-1-dev` | `azurerm_application_insights` | — (consumption-based, backed by Log Analytics) | Telemetry, dependency tracking, and live metrics for the Function App. | Connected to the shared Log Analytics Workspace (`law-core`). | Phase 1 (env) |

---

## 6. Jump Box (Developer Connectivity)

| # | Resource Name | Type | SKU / Size | Purpose | Details | Phase |
|---|--------------|------|-----------|---------|---------|-------|
| 47 | `vm-jumpbox-core` | `azurerm_windows_virtual_machine` | **Standard_B2s** (2 vCPU, 4 GiB RAM) | Windows 11 jump box for developer access to VNet-internal resources. Shared across all environments. | Entra ID auth via `AADLoginForWindows` extension. System-assigned MI. Resource group: `rg-core`. | Phase 1 (core) |
| 48 | `nic-jumpbox-core` | `azurerm_network_interface` | — | NIC for jump box VM. | Attached to `snet-jumpbox`. Resource group: `rg-core`. | Phase 1 (core) |
| 49 | `pip-jumpbox-core` | `azurerm_public_ip` | Standard, Static | Public IP for RDP ingress to jump box. | In production, replace with Azure Bastion. Resource group: `rg-core`. | Phase 1 (core) |
| 50 | OS Disk | `azurerm_managed_disk` (implicit) | **Premium_LRS** | Boot disk for Windows 11. | Created implicitly by the VM resource. | Phase 1 (core) |
| 51 | `AADLoginForWindows` | `azurerm_virtual_machine_extension` | — | VM extension enabling Entra ID sign-in. | Eliminates need for local admin credentials. | Phase 1 (core) |

---

## 7. Certificates (Terraform `tls` Provider → Key Vault)

These are not Azure resources per se but are logical artefacts created by Terraform and stored in Key Vault.

| # | Artefact | Type | Purpose | Phase |
|---|---------|------|---------|-------|
| 51 | Self-signed CA certificate | `tls_self_signed_cert` + `azurerm_key_vault_certificate` | Root CA used as the mTLS truststore in APIM. | Phase 1 (cert generation) / Phase 3 (KV write) |
| 52 | Client certificate (signed by CA) | `tls_locally_signed_cert` + `azurerm_key_vault_certificate` | Client-side mTLS certificate presented by API consumers. | Phase 1 (cert generation) / Phase 3 (KV write) |

---

## 8. Identity & Role Assignments

| # | Resource | Type | Scope | Purpose | Phase |
|---|---------|------|-------|---------|-------|
| 52 | Function App System-Assigned MI | Implicit (part of `func-wkld-1-api-dev`) | — | Identity used for all service-to-service calls from the Function App. | Phase 1 (env) |
| 53 | Role: **AcrPull** | `azurerm_role_assignment` | ACR (`acrcore`) | Function App MI → pull container images from ACR. | Phase 1 (env) |
| 54 | Role: **Key Vault Secrets User** | `azurerm_role_assignment` | Key Vault (`kv-wkld-1-dev`) | Function App MI → read secrets/certs from per-stamp Key Vault. | Phase 1 (env) |
| 55 | Role: **Key Vault Certificate User** | `azurerm_role_assignment` | Key Vault (`kv-wkld-1-dev`) | APIM system-assigned MI → read CA certificate from per-stamp Key Vault for mTLS policy. | Phase 1 (env) |
| 56 | Role: **Key Vault Secrets User** | `azurerm_role_assignment` | Key Vault (`kv-wkld-1-dev`) | APIM system-assigned MI → read secrets from per-stamp Key Vault. | Phase 1 (env) |
| 57 | Role: **Key Vault Administrator** | `azurerm_role_assignment` | Key Vault (`kv-wkld-1-dev`) | CI/CD SP → write certificates and secrets in Phase 3. | Phase 1 (env) |
| 58 | Role: **Storage Blob Data Owner** | `azurerm_role_assignment` | Storage (`stwkld1dev`) | Function App MI → manage blob storage. | Phase 1 (env) |
| 59 | Role: **Storage Queue Data Contributor** | `azurerm_role_assignment` | Storage (`stwkld1dev`) | Function App MI → manage queue storage. | Phase 1 (env) |
| 60 | Role: **Storage Table Data Contributor** | `azurerm_role_assignment` | Storage (`stwkld1dev`) | Function App MI → manage table storage. | Phase 1 (env) |

---

## 9. Diagnostic Settings

Streaming logs and metrics from every resource to the shared Log Analytics Workspace. One `azurerm_monitor_diagnostic_setting` per resource.

| # | Target Resource | Log Categories (typical) | Phase |
|---|----------------|------------------------|-------|
| 61 | `func-wkld-1-api-dev` (Function App) | FunctionAppLogs | Phase 1 (env) |
| 62 | `asp-wkld-1-dev` (App Service Plan) | Metrics only (no diagnostic logs for ASP) | Phase 1 (env) |
| 63 | `stwkld1dev` (Storage — blob/queue/table) | StorageRead, StorageWrite, StorageDelete + Transaction metrics | Phase 1 (env) |
| 64 | `kv-wkld-1-dev` (Key Vault) | AuditEvent, AzurePolicyEvaluationDetails | Phase 1 (env) |
| 65 | `acrcore` (ACR) | ContainerRegistryLoginEvents, ContainerRegistryRepositoryEvents | Phase 1 (core) |
| 66 | `apim-wkld-shared-dev` (APIM) | GatewayLogs, WebSocketConnectionLogs | Phase 1 (env) |
| 67 | `law-core` (Log Analytics Workspace) | Audit (self-diagnostic) | Phase 1 (core) |
| 68 | NSG Flow Logs (×4 fixed + 2 stamp NSGs) | NetworkSecurityGroupFlowEvent via Traffic Analytics | Phase 1 (core) |

---

## 10. Monitoring & Alerting (Phase 3)

| # | Resource | Type | Purpose | Details | Phase |
|---|---------|------|---------|---------|-------|
| 64 | 5xx error rate alert | `azurerm_monitor_metric_alert` | Alert on Function App HTTP 5xx error rate exceeding threshold. | Action group with email/webhook notification. | Phase 3 |
| 65 | Availability test | `azurerm_application_insights_standard_web_test` | Synthetic health check against Function App health endpoint (via APIM or direct PE). | Tests API reachability and response correctness. | Phase 3 |
| 66 | Availability test failure alert | `azurerm_monitor_metric_alert` | Alert when availability test fails. | Tied to the availability test above. | Phase 3 |
| 67 | Action Group | `azurerm_monitor_action_group` | Notification target for all alert rules. | Email / webhook receiver(s). | Phase 3 |

---

## 11. APIM Configuration (Phase 3)

| # | Resource | Type | Purpose | Phase |
|---|---------|------|---------|-------|
| 68 | APIM Backend | `azurerm_api_management_backend` | Registers the Function App PE as an APIM backend endpoint. | Phase 3 |
| 69 | APIM API | `azurerm_api_management_api` | Defines the API surface exposed through APIM. | Phase 3 |
| 70 | APIM API Operation(s) | `azurerm_api_management_api_operation` | Individual API operation definitions (e.g., POST /message). | Phase 3 |
| 71 | mTLS Policy | `azurerm_api_management_api_policy` (inline XML) | Client certificate validation policy using the CA cert from Key Vault as truststore. | Phase 3 |

---

## 12. GitHub Runner Network Integration

Not a traditional Azure resource — provisioned via GitHub, but requires an Azure-side Network Settings resource.

| # | Resource | Type | Purpose | Phase |
|---|---------|------|---------|-------|
| 72 | GitHub Network Settings | `azurerm_network_settings` / GitHub API | Allows GitHub-managed runner to inject into `snet-runner` with the associated NSG and NAT Gateway. | Phase 1 (Azure side) / Phase 2 (GitHub side — manual) |

---

## Summary — Resource Count

*Counts below are for dev environment with 2 stamps. Production counts will vary by stamp count.*

| Category | Count (dev, 2 stamps) |
|----------|----------------------|
| Resource Groups (TF-managed) | 4 (rg-core + rg-wkld-shared-dev + 2×rg-wkld-stamp) |
| Resource Groups (manually created) | 1 (rg-core-deploy) |
| Virtual Network | 1 (shared) |
| Subnets | 8 (4 fixed + 2 per stamp × 2 stamps) |
| Network Security Groups | 8 (4 fixed + 2 per stamp × 2 stamps) |
| NAT Gateway + Public IP (NAT) | 2 |
| Jump Box Public IP | 1 |
| Private DNS Zones | 7 |
| Private DNS Zone VNet Links | 7 |
| ACR Private Endpoint | 1 |
| Key Vault Private Endpoint | 2 (one per stamp) |
| Storage Private Endpoints | 8 (4 per stamp × 2 stamps) |
| Function App Private Endpoint | 2 (one per stamp) |
| Container Registry (ACR) | 1 (shared) |
| Key Vault | 2 (one per stamp) |
| API Management (APIM) | 1 |
| Log Analytics Workspace | 1 (shared) |
| Diagnostic Storage Account | 1 (shared) |
| App Service Plan | 2 (one per stamp) |
| Function App | 2 (one per stamp) |
| Storage Account | 2 (one per stamp) |
| Application Insights | 2 (one per stamp) |
| Jump Box (VM + NIC + PIP + Disk + Extension) | 5 (shared) |
| Certificates (CA + Client) | 2 |
| Role Assignments | ~9 per stamp (×2) = ~18 |
| Diagnostic Settings | ~8 per stamp + 4 shared = ~20 |
| Monitor Alerts + Action Group | 3 per env (Phase 3) |
| APIM Config (Backend + API + Operations + Policy) | 4 per env (Phase 3) |
| GitHub Network Settings | 1 |
| **Total (approximate)** | **~120** |

---

## SKU / Tier Summary

| Resource | SKU / Tier | Rationale |
|----------|-----------|-----------|
| ACR | **Premium** | Required for Private Endpoint support. |
| Key Vault | **Standard** | Sufficient for secrets and certificate storage. No HSM-backed keys needed. |
| APIM | **Developer** | Assessment constraint (TC-5). Supports internal VNet mode. Not for production (no SLA). |
| App Service Plan | **P1v3** | Minimum tier supporting VNet integration + Linux containers. |
| Log Analytics | **PerGB2018** | Pay-as-you-go; no commitment tier needed for assessment workload. |
| NAT Gateway | **Standard** | Only available SKU. |
| Public IPs (×2) | **Standard, Static** | Required for NAT Gateway and jump box RDP. |
| Jump Box VM | **Standard_B2s** | 2 vCPU / 4 GiB — minimal footprint for RDP diagnostics. Burstable. |
| Storage Account | **Standard_LRS** | Locally redundant; sufficient for Function App backing store in a single-region assessment. |
| OS Disk (Jump Box) | **Premium_LRS** | Default for Windows 11 VM in azurerm provider. |
