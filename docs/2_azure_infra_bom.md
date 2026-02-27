# Azure Infrastructure — Bill of Materials

Complete inventory of every Azure resource expected to be created, including SKU, naming, purpose, and deployment phase.

> **Workload name:** `wkld` · **Naming convention:** `<abbr>-wkld-<stamp|shared>-<env>` · **Example environment:** `dev`

---

## 1. Resource Groups

| # | Resource Name | Type | Purpose | Phase |
|---|--------------|------|---------|-------|
| 1 | `rg-wkld-shared-dev` | `azurerm_resource_group` | Container for all shared and stamp infrastructure. | Phase 1 |

> Single resource group approach. Can be split (shared vs. per-stamp) at implementation time if needed — the implementation planning doc leaves this decision open.

---

## 2. Networking

### 2.1 Virtual Network

| # | Resource Name | Type | SKU / Tier | Address Space | Purpose | Phase |
|---|--------------|------|------------|---------------|---------|-------|
| 2 | `vnet-wkld-shared-dev` | `azurerm_virtual_network` | N/A (free) | `10.155.0.0/20` | Single VNet hosting all subnets for compute, PaaS endpoints, APIM, runner, and jump box. | Phase 1 |

### 2.2 Subnets

| # | Subnet Name | Type | CIDR | Usable IPs | Delegation | Purpose | Phase |
|---|------------|------|------|------------|------------|---------|-------|
| 3 | `snet-stamp-1-pe` | `azurerm_subnet` | `10.155.0.0/24` | 251 | None | Private Endpoints for stamp resources (Function App, Storage blob/file/table/queue). PE network policies enabled. | Phase 1 |
| 4 | `snet-stamp-1-asp` | `azurerm_subnet` | `10.155.1.0/24` | 251 | `Microsoft.Web/serverFarms` | App Service Plan VNet integration — Function App outbound traffic. | Phase 1 |
| 5 | `snet-apim` | `azurerm_subnet` | `10.155.2.0/27` | 27 | `Microsoft.ApiManagement/service` | API Management internal VNet mode. | Phase 1 |
| 6 | `snet-shared-pe` | `azurerm_subnet` | `10.155.3.0/24` | 251 | None | Private Endpoints for shared resources (ACR, Key Vault). PE network policies enabled. | Phase 1 |
| 7 | `snet-runner` | `azurerm_subnet` | `10.155.4.0/24` | 251 | `GitHub.Network/networkSettings` | GitHub Actions VNet-injected runner. NAT Gateway attached. | Phase 1 |
| 8 | `snet-jumpbox` | `azurerm_subnet` | `10.155.5.0/27` | 27 | None | Windows 11 jump box VM for developer connectivity. | Phase 1 |

### 2.3 Network Security Groups

One NSG per subnet, each with a default `DenyAll` at priority 4096 and only the minimum required allow rules. Detailed rule sets are documented in the network technical design.

| # | NSG Name | Type | Attached To | Phase |
|---|---------|------|-------------|-------|
| 9 | `nsg-wkld-shared-dev-stamp-1-pe` | `azurerm_network_security_group` | `snet-stamp-1-pe` | Phase 1 |
| 10 | `nsg-wkld-shared-dev-stamp-1-asp` | `azurerm_network_security_group` | `snet-stamp-1-asp` | Phase 1 |
| 11 | `nsg-wkld-shared-dev-apim` | `azurerm_network_security_group` | `snet-apim` | Phase 1 |
| 12 | `nsg-wkld-shared-dev-shared-pe` | `azurerm_network_security_group` | `snet-shared-pe` | Phase 1 |
| 13 | `nsg-wkld-shared-dev-runner` | `azurerm_network_security_group` | `snet-runner` | Phase 1 |
| 14 | `nsg-wkld-shared-dev-jumpbox` | `azurerm_network_security_group` | `snet-jumpbox` | Phase 1 |

### 2.4 NAT Gateway

| # | Resource Name | Type | SKU | Purpose | Associated Subnet | Phase |
|---|--------------|------|-----|---------|-------------------|-------|
| 15 | `natgw-wkld-shared-dev` | `azurerm_nat_gateway` | Standard | Deterministic egress for the GitHub Runner — the only resource requiring internet access. | `snet-runner` | Phase 1 |
| 16 | `pip-natgw-wkld-shared-dev` | `azurerm_public_ip` | Standard, Static | Static public IP for NAT Gateway egress. | — | Phase 1 |

---

## 3. Private DNS Zones

Each Private Endpoint–backed service requires a corresponding DNS zone linked to the VNet. Created by the `modules/private-dns` module.

| # | Zone Name | Type | Used By | Phase |
|---|----------|------|---------|-------|
| 17 | `privatelink.vaultcore.azure.net` | `azurerm_private_dns_zone` | Key Vault | Phase 1 |
| 18 | `privatelink.blob.core.windows.net` | `azurerm_private_dns_zone` | Storage Account (blob) | Phase 1 |
| 19 | `privatelink.file.core.windows.net` | `azurerm_private_dns_zone` | Storage Account (file share) | Phase 1 |
| 20 | `privatelink.table.core.windows.net` | `azurerm_private_dns_zone` | Storage Account (table) | Phase 1 |
| 21 | `privatelink.queue.core.windows.net` | `azurerm_private_dns_zone` | Storage Account (queue) | Phase 1 |
| 22 | `privatelink.azurecr.io` | `azurerm_private_dns_zone` | Azure Container Registry | Phase 1 |
| 23 | `privatelink.azurewebsites.net` | `azurerm_private_dns_zone` | Function App | Phase 1 |
| 24 | `privatelink.azure-api.net` | `azurerm_private_dns_zone` | API Management | Phase 1 |

### 3.1 Private DNS Zone VNet Links

One link resource per zone, binding it to the VNet so all subnets resolve Private Endpoint FQDNs via Azure DNS (`168.63.129.16`).

| # | Resource | Type | Purpose | Phase |
|---|---------|------|---------|-------|
| 25–32 | One `azurerm_private_dns_zone_virtual_network_link` per zone (×8) | `azurerm_private_dns_zone_virtual_network_link` | Enables in-VNet resolution of private endpoint DNS records. | Phase 1 |

---

## 4. Shared PaaS Services

### 4.1 Azure Container Registry

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 33 | `acrwkldshareddev` | `azurerm_container_registry` | **Premium** | Hosts Docker images for Function App(s). | Admin disabled. Managed Identity pull only. Premium SKU required for Private Endpoint support. `public_network_access_enabled = false`. | Phase 1 |
| 34 | PE for ACR | `azurerm_private_endpoint` | — | Private connectivity to ACR from VNet. | Subnet: `snet-shared-pe`. DNS zone group: `privatelink.azurecr.io`. | Phase 1 |

### 4.2 Azure Key Vault

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 35 | `kv-wkld-shared-dev` | `azurerm_key_vault` | **Standard** | Stores certificates (CA + client), secrets, and application credentials. | RBAC authorisation mode. Purge protection enabled. `public_network_access_enabled = false`. | Phase 1 |
| 36 | PE for Key Vault | `azurerm_private_endpoint` | — | Private connectivity to Key Vault from VNet. | Subnet: `snet-shared-pe`. DNS zone group: `privatelink.vaultcore.azure.net`. | Phase 1 |

### 4.3 API Management

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 37 | `apim-wkld-shared-dev` | `azurerm_api_management` | **Developer** | Shared API front door. Terminates mTLS, routes to Function App backends, centralises request logging and policy enforcement. | Internal VNet mode. Deployed into `snet-apim` (delegated). No public endpoint. | Phase 1 |

### 4.4 Log Analytics Workspace

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 38 | `log-wkld-shared-dev` | `azurerm_log_analytics_workspace` | **PerGB2018** (pay-as-you-go) | Central log sink for all diagnostic settings, NSG flow logs, and App Insights backend. | Retention period parameterised (30 days default). | Phase 1 |

---

## 5. Workload Stamp Resources (Stamp 1)

All resources below are created by the `modules/workload-stamp` module for stamp number **1**.

### 5.1 Compute

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 39 | `asp-wkld-1-dev` | `azurerm_service_plan` | **P1v3** | Linux App Service Plan hosting the Function App. | P1v3 is the minimum SKU supporting VNet integration + Linux containers. Shared across Function Apps within the stamp. | Phase 1 |
| 40 | `func-wkld-1-dev` | `azurerm_linux_function_app` | — (inherits ASP) | Python HTTP-triggered Function App, deployed as a Docker container from ACR. | System-assigned Managed Identity. `public_network_access_enabled = false`. HTTPS only. TLS 1.2 minimum. VNet integrated via `snet-stamp-1-asp`. | Phase 1 |

### 5.2 Storage

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 41 | `stwkld1dev` | `azurerm_storage_account` | **Standard_LRS** | Function App backing storage (triggers, state, logs). | `public_network_access_enabled = false`. TLS 1.2 minimum. Network rules deny all except VNet. | Phase 1 |
| 42 | PE — blob | `azurerm_private_endpoint` | — | Private connectivity for blob storage. | Subnet: `snet-stamp-1-pe`. DNS zone: `privatelink.blob.core.windows.net`. | Phase 1 |
| 43 | PE — file | `azurerm_private_endpoint` | — | Private connectivity for file share storage. | Subnet: `snet-stamp-1-pe`. DNS zone: `privatelink.file.core.windows.net`. | Phase 1 |
| 44 | PE — table | `azurerm_private_endpoint` | — | Private connectivity for table storage. | Subnet: `snet-stamp-1-pe`. DNS zone: `privatelink.table.core.windows.net`. | Phase 1 |
| 45 | PE — queue | `azurerm_private_endpoint` | — | Private connectivity for queue storage. | Subnet: `snet-stamp-1-pe`. DNS zone: `privatelink.queue.core.windows.net`. | Phase 1 |

### 5.3 Function App Private Endpoint

| # | Resource Name | Type | Purpose | Details | Phase |
|---|--------------|------|---------|---------|-------|
| 46 | PE — Function App | `azurerm_private_endpoint` | Inbound private connectivity to Function App (APIM → Function App). | Subnet: `snet-stamp-1-pe`. DNS zone: `privatelink.azurewebsites.net`. | Phase 1 |

### 5.4 Observability (per stamp)

| # | Resource Name | Type | SKU | Purpose | Details | Phase |
|---|--------------|------|-----|---------|---------|-------|
| 47 | `appi-wkld-1-dev` | `azurerm_application_insights` | — (consumption-based, backed by Log Analytics) | Telemetry, dependency tracking, and live metrics for the Function App. | Connected to the shared Log Analytics Workspace. | Phase 1 |

---

## 6. Jump Box (Developer Connectivity)

| # | Resource Name | Type | SKU / Size | Purpose | Details | Phase |
|---|--------------|------|-----------|---------|---------|-------|
| 48 | `vm-wkld-shared-dev-jumpbox` | `azurerm_windows_virtual_machine` | **Standard_B2s** (2 vCPU, 4 GiB RAM) | Windows 11 jump box for developer access to VNet-internal resources. | Entra ID authentication via `AADLoginForWindows` extension. No local admin password stored. | Phase 1 |
| 49 | `nic-vm-wkld-shared-dev-jumpbox` | `azurerm_network_interface` | — | NIC for jump box VM. | Attached to `snet-jumpbox`. | Phase 1 |
| 50 | `pip-vm-wkld-shared-dev-jumpbox` | `azurerm_public_ip` | Standard, Static | Public IP for RDP ingress to jump box. | In production, replace with Azure Bastion. | Phase 1 |
| 51 | OS Disk | `azurerm_managed_disk` (implicit) | **Standard_LRS** / 128 GiB (default) | Boot disk for Windows 11. | Created implicitly by the VM resource. | Phase 1 |
| 52 | `AADLoginForWindows` | `azurerm_virtual_machine_extension` | — | VM extension enabling Entra ID sign-in. | Eliminates need for local admin credentials. | Phase 1 |

---

## 7. Certificates (Terraform `tls` Provider → Key Vault)

These are not Azure resources per se but are logical artefacts created by Terraform and stored in Key Vault.

| # | Artefact | Type | Purpose | Phase |
|---|---------|------|---------|-------|
| 53 | Self-signed CA certificate | `tls_self_signed_cert` + `azurerm_key_vault_certificate` | Root CA used as the mTLS truststore in APIM. | Phase 1 (cert generation) / Phase 3 (KV write) |
| 54 | Client certificate (signed by CA) | `tls_locally_signed_cert` + `azurerm_key_vault_certificate` | Client-side mTLS certificate presented by API consumers. | Phase 1 (cert generation) / Phase 3 (KV write) |

---

## 8. Identity & Role Assignments

| # | Resource | Type | Scope | Purpose | Phase |
|---|---------|------|-------|---------|-------|
| 55 | Function App System-Assigned MI | Implicit (part of `func-wkld-1-dev`) | — | Identity used for all service-to-service calls from the Function App. | Phase 1 |
| 56 | Role: **AcrPull** | `azurerm_role_assignment` | ACR (`acrwkldshareddev`) | Function App MI → pull container images from ACR. | Phase 1 |
| 57 | Role: **Key Vault Secrets User** | `azurerm_role_assignment` | Key Vault (`kv-wkld-shared-dev`) | Function App MI → read secrets/certs from Key Vault. | Phase 1 |

---

## 9. Diagnostic Settings

Streaming logs and metrics from every resource to the shared Log Analytics Workspace. One `azurerm_monitor_diagnostic_setting` per resource.

| # | Target Resource | Log Categories (typical) | Phase |
|---|----------------|------------------------|-------|
| 58 | `func-wkld-1-dev` (Function App) | FunctionAppLogs, AppServiceHTTPLogs | Phase 1 |
| 59 | `asp-wkld-1-dev` (App Service Plan) | AppServicePlatformLogs | Phase 1 |
| 60 | `stwkld1dev` (Storage Account) | StorageRead, StorageWrite, StorageDelete | Phase 1 |
| 61 | `kv-wkld-shared-dev` (Key Vault) | AuditEvent | Phase 1 |
| 62 | `acrwkldshareddev` (ACR) | ContainerRegistryLoginEvents, ContainerRegistryRepositoryEvents | Phase 1 |
| 63 | `apim-wkld-shared-dev` (APIM) | GatewayLogs, WebSocketConnectionLogs | Phase 3 |
| 64 | NSG Flow Logs (×6 NSGs) | NetworkSecurityGroupFlowEvent | Phase 1 |

---

## 10. Monitoring & Alerting (Phase 3)

| # | Resource | Type | Purpose | Details | Phase |
|---|---------|------|---------|---------|-------|
| 65 | 5xx error rate alert | `azurerm_monitor_metric_alert` | Alert on Function App HTTP 5xx error rate exceeding threshold. | Action group with email/webhook notification. | Phase 3 |
| 66 | Availability test | `azurerm_application_insights_standard_web_test` | Synthetic health check against Function App health endpoint (via APIM or direct PE). | Tests API reachability and response correctness. | Phase 3 |
| 67 | Availability test failure alert | `azurerm_monitor_metric_alert` | Alert when availability test fails. | Tied to the availability test above. | Phase 3 |
| 68 | Action Group | `azurerm_monitor_action_group` | Notification target for all alert rules. | Email / webhook receiver(s). | Phase 3 |

---

## 11. APIM Configuration (Phase 3)

| # | Resource | Type | Purpose | Phase |
|---|---------|------|---------|-------|
| 69 | APIM Backend | `azurerm_api_management_backend` | Registers the Function App PE as an APIM backend endpoint. | Phase 3 |
| 70 | APIM API | `azurerm_api_management_api` | Defines the API surface exposed through APIM. | Phase 3 |
| 71 | APIM API Operation(s) | `azurerm_api_management_api_operation` | Individual API operation definitions (e.g., POST /message). | Phase 3 |
| 72 | mTLS Policy | `azurerm_api_management_api_policy` (inline XML) | Client certificate validation policy using the CA cert from Key Vault as truststore. | Phase 3 |

---

## 12. GitHub Runner Network Integration

Not a traditional Azure resource — provisioned via GitHub, but requires an Azure-side Network Settings resource.

| # | Resource | Type | Purpose | Phase |
|---|---------|------|---------|-------|
| 73 | GitHub Network Settings | `azurerm_network_settings` / GitHub API | Allows GitHub-managed runner to inject into `snet-runner` with the associated NSG and NAT Gateway. | Phase 1 (Azure side) / Phase 2 (GitHub side — manual) |

---

## Summary — Resource Count

| Category | Count |
|----------|-------|
| Resource Group | 1 |
| Virtual Network | 1 |
| Subnets | 6 |
| Network Security Groups | 6 |
| NAT Gateway + Public IP | 2 |
| Private DNS Zones | 8 |
| Private DNS Zone VNet Links | 8 |
| Private Endpoints | 7 |
| Container Registry (ACR) | 1 |
| Key Vault | 1 |
| API Management (APIM) | 1 |
| Log Analytics Workspace | 1 |
| App Service Plan | 1 |
| Function App | 1 |
| Storage Account | 1 |
| Application Insights | 1 |
| Jump Box (VM + NIC + PIP + Disk + Extension) | 5 |
| Certificates (CA + Client) | 2 |
| Role Assignments | 2 |
| Diagnostic Settings | ~10 |
| Monitor Alerts + Action Group | 4 |
| APIM Config (Backend + API + Operations + Policy) | 4 |
| GitHub Network Settings | 1 |
| **Total (approximate)** | **~75** |

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
| OS Disk (Jump Box) | **Standard_LRS** | Cost-effective for a diagnostics VM. |
