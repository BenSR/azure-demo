# Network Technical Design

Detailed network topology, subnet layout, NAT Gateway configuration, and per-subnet NSG rule design for the solution.

---

## 1. Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Zero public internet exposure** | All PaaS services behind Private Endpoints. APIM in internal VNet mode. Function App `public_network_access_enabled = false`. |
| **Least-privilege NSG rules** | One NSG per subnet. Explicit deny-all as the final custom rule; allow only the minimum traffic each subnet requires. |
| **Deterministic egress** | NAT Gateway with a static Public IP attached **only** to the GitHub Runner subnet — the sole subnet that requires internet access. |
| **Private DNS resolution** | Azure Private DNS Zones linked to the VNet. All subnets resolve private endpoint FQDNs via Azure DNS (`168.63.129.16`). |
| **Private Endpoint Network Policies** | Enabled on PE subnets (`private_endpoint_network_policies = "Enabled"`) so that NSG rules apply to Private Endpoint traffic. |

---

## 2. VNet Design

A single VNet hosts all subnets. Hub-spoke is out of scope (single-region, single-workload deployment). The address space is sized to accommodate future stamps and additional shared subnets without re-addressing.

| Attribute | Value |
|-----------|-------|
| **Name** | `vnet-wkld-shared-<env>` |
| **Address Space** | `10.155.0.0/20` |
| **Region** | Single region (parameterised) |

---

## 3. Subnet Layout

Six subnets, each with a dedicated NSG. Delegations are applied where Azure requires them.

| Subnet Name | CIDR | Usable IPs | Delegation | Purpose | NAT Gateway |
|-------------|------|------------|------------|---------|-------------|
| `snet-stamp-1-pe` | `10.155.0.0/24` | 251 | None | Private Endpoints for stamp resources (Function App PE, Storage Account PEs: blob, file, table, queue) | No |
| `snet-stamp-1-asp` | `10.155.1.0/24` | 251 | `Microsoft.Web/serverFarms` | App Service Plan VNet integration — Function App outbound traffic egresses from this subnet | No |
| `snet-apim` | `10.155.2.0/27` | 27 | `Microsoft.ApiManagement/service` | API Management (internal VNet mode, Developer tier) | No |
| `snet-shared-pe` | `10.155.3.0/24` | 251 | None | Private Endpoints for shared resources (ACR PE, Key Vault PE) | No |
| `snet-runner` | `10.155.4.0/24` | 251 | `GitHub.Network/networkSettings` | GitHub Actions VNet-injected runner | **Yes** |
| `snet-jumpbox` | `10.155.5.0/27` | 27 | None | Windows 11 jump box for developer connectivity and diagnostics | No |

### Subnet Configuration Notes

- **PE subnets** (`snet-stamp-1-pe`, `snet-shared-pe`): `private_endpoint_network_policies = "Enabled"` to allow NSG enforcement on Private Endpoint NICs.
- **ASP subnet** (`snet-stamp-1-asp`): Delegation to `Microsoft.Web/serverFarms` is mandatory for App Service VNet integration. The Function App's **outbound** traffic originates from this subnet; **inbound** traffic arrives at the Function App's Private Endpoint in `snet-stamp-1-pe`.
- **APIM subnet** (`snet-apim`): Delegation to `Microsoft.ApiManagement/service` is mandatory. `/27` is the recommended minimum for Developer tier.
- **Runner subnet** (`snet-runner`): Delegation to `GitHub.Network/networkSettings` is required for GitHub-managed VNet-injected runners.
- **Jump box subnet** (`snet-jumpbox`): No delegation. Hosts a single Windows 11 VM with a public IP for RDP access. Entra ID authentication via the `AADLoginForWindows` VM extension. `/27` is sufficient — only one VM is expected.

---

## 4. NAT Gateway

The GitHub Runner is the **only** component that requires egress to the public internet (for GitHub Actions communication, package downloads, Azure Resource Manager API calls via Terraform, and `az acr login`). All other subnets have internet-bound outbound traffic denied at the NSG level.

| Attribute | Value |
|-----------|-------|
| **Name** | `natgw-wkld-shared-<env>` |
| **Public IP** | `pip-natgw-wkld-shared-<env>` (static Standard SKU) |
| **Associated Subnet** | `snet-runner` only |
| **Idle Timeout** | 4 minutes (default) |

### Why Only the Runner Subnet?

| Subnet | Internet Egress Required? | Reason |
|--------|--------------------------|--------|
| `snet-stamp-1-pe` | No | Private Endpoints are inbound-only listeners; they do not initiate connections. |
| `snet-stamp-1-asp` | No | Function App communicates exclusively with Private Endpoints (Storage, ACR, Key Vault) and Azure Monitor via service tag. No internet dependency. |
| `snet-apim` | No | APIM internal mode. Required outbound dependencies (Storage, SQL, Key Vault, Event Hub, Azure Monitor) are reached via Azure service tags, not internet routes. |
| `snet-shared-pe` | No | Private Endpoints are inbound-only listeners. |
| `snet-runner` | **Yes** | GitHub Actions orchestration, pulling packages (pip, apt), Azure ARM API (Terraform apply), Docker build tooling. |
| `snet-jumpbox` | No | Jump box connects to internal resources only. Inbound RDP from internet; outbound to PE subnets within the VNet. No general internet egress required. |

---

## 5. Traffic Flow Summary

Defines the legitimate traffic paths between subnets and external endpoints. All other traffic is denied.

```mermaid
graph LR
    subgraph VNet ["VNet: 10.155.0.0/20"]

        subgraph APIM ["snet-apim<br/>10.155.2.0/27"]
            apim[APIM]
        end

        subgraph StampPE ["snet-stamp-1-pe<br/>10.155.0.0/24"]
            funcpe[Function App PE]
            stpe[Storage PEs]
        end

        subgraph StampASP ["snet-stamp-1-asp<br/>10.155.1.0/24"]
            asp[Function App<br/>VNet Integration]
        end

        subgraph SharedPE ["snet-shared-pe<br/>10.155.3.0/24"]
            acrpe[ACR PE]
            kvpe[Key Vault PE]
        end

        subgraph Runner ["snet-runner<br/>10.155.4.0/24"]
            runner[GitHub Runner]
        end

        subgraph Jumpbox ["snet-jumpbox<br/>10.155.5.0/27"]
            jbox[Jump Box VM]
        end
    end

    AzMon([AzureMonitor])
    Internet([Internet<br/>via NAT GW])
    DNS([Azure DNS<br/>168.63.129.16])

    apim -- "443/TCP" --> funcpe
    apim -- "443/TCP" --> kvpe

    asp -- "443/TCP" --> stpe
    asp -- "443/TCP" --> acrpe
    asp -- "443/TCP" --> kvpe
    asp -- "443/TCP" --> AzMon

    runner -- "443/TCP" --> acrpe
    runner -- "443/TCP" --> kvpe
    runner -- "443/TCP" --> stpe
    runner -- "443,80/TCP" --> Internet

    jbox -- "443/TCP" --> acrpe
    jbox -- "443/TCP" --> kvpe
    jbox -- "443/TCP" --> stpe
    jbox -- "443/TCP" --> funcpe
    jbox -- "443/TCP" --> apim
    RDP([Internet<br/>RDP 3389]) -- "3389/TCP" --> jbox

    VNet -. "53/UDP+TCP" .-> DNS
```

### Flow Matrix

| # | Source | Destination | Port | Protocol | Path | Purpose |
|---|--------|-------------|------|----------|------|---------|
| 1 | `snet-apim` | `snet-stamp-1-pe` | 443 | TCP | VNet-internal | APIM → Function App PE (backend API call) |
| 2 | `snet-apim` | `snet-shared-pe` | 443 | TCP | VNet-internal | APIM → Key Vault PE (mTLS certificate retrieval) |
| 3 | `snet-stamp-1-asp` | `snet-stamp-1-pe` | 443 | TCP | VNet-internal | Function App → Storage Account PEs (blob, file, table, queue) |
| 4 | `snet-stamp-1-asp` | `snet-shared-pe` | 443 | TCP | VNet-internal | Function App → ACR PE (image pull), Key Vault PE (secret read) |
| 5 | `snet-stamp-1-asp` | AzureMonitor | 443 | TCP | Service tag | Function App → App Insights telemetry + diagnostics |
| 6 | `snet-runner` | `snet-shared-pe` | 443 | TCP | VNet-internal | Runner → ACR PE (image push), Key Vault PE (secret write) |
| 7 | `snet-runner` | `snet-stamp-1-pe` | 443 | TCP | VNet-internal | Runner → Storage PEs (Terraform data-plane ops in Phase 3) |
| 8 | `snet-runner` | Internet | 443, 80 | TCP | NAT Gateway | Runner → GitHub API, package repos, Azure ARM API |
| 9 | All subnets | `168.63.129.16` | 53 | TCP/UDP | Azure platform | DNS resolution (Private DNS Zones + public forwarding) |
| 10 | Internet | `snet-jumpbox` | 3389 | TCP | Public IP | RDP access to jump box (Entra ID authenticated) |
| 11 | `snet-jumpbox` | `snet-stamp-1-pe` | 443 | TCP | VNet-internal | Jump box → Function App PE, Storage PEs (diagnostics) |
| 12 | `snet-jumpbox` | `snet-shared-pe` | 443 | TCP | VNet-internal | Jump box → ACR PE, Key Vault PE (diagnostics) |
| 13 | `snet-jumpbox` | `snet-apim` | 443 | TCP | VNet-internal | Jump box → APIM gateway (API testing with mTLS client cert) |

---

## 6. NSG Design — Per-Subnet Rules

Each subnet has a dedicated NSG. Custom rules are numbered 100–4096. A `DenyAll` rule at priority 4096 catches any traffic not explicitly permitted. Azure default rules (65000+) exist but are superseded by the explicit deny.

> **Convention:** Rule names use the pattern `Allow<Source>To<Dest><Port>` or `Deny<Scope><Direction>`. Service tag names follow Azure conventions (e.g., `AzureMonitor`, `ApiManagement`, `Storage`).

---

### 6.1 NSG: `nsg-wkld-shared-<env>-stamp-1-pe`

**Attached to:** `snet-stamp-1-pe` (`10.155.0.0/24`)
**Hosted resources:** Function App Private Endpoint, Storage Account Private Endpoints (blob, file, table, queue)

#### Inbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowApimToFuncAppPE | `10.155.2.0/27` | `10.155.0.0/24` | 443 | TCP | **Allow** | APIM calls the Function App via its Private Endpoint. **This is the only path to invoke the Function App.** |
| 110 | AllowAspToStoragePEs | `10.155.1.0/24` | `10.155.0.0/24` | 443 | TCP | **Allow** | Function App (VNet-integrated in ASP subnet) accesses its Storage Account PEs. |
| 120 | AllowRunnerToStampPEs | `10.155.4.0/24` | `10.155.0.0/24` | 443 | TCP | **Allow** | GitHub Runner performs Terraform data-plane operations on Storage (Phase 3). |
| 130 | AllowJumpboxToStampPEs | `10.155.5.0/27` | `10.155.0.0/24` | 443 | TCP | **Allow** | Jump box → Function App PE, Storage PEs (diagnostics and validation). |
| 4096 | DenyAllInbound | `*` | `*` | `*` | `*` | **Deny** | Default deny — no other source may reach stamp Private Endpoints. |

#### Outbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 4096 | DenyAllOutbound | `*` | `*` | `*` | `*` | **Deny** | Private Endpoints do not initiate outbound connections. NSG statefulness handles return traffic for allowed inbound flows. |

---

### 6.2 NSG: `nsg-wkld-shared-<env>-stamp-1-asp`

**Attached to:** `snet-stamp-1-asp` (`10.155.1.0/24`)
**Hosted resources:** App Service Plan VNet integration (Function App outbound traffic originates here)

> **Key point:** The Function App is **not** reachable via this subnet. All inbound requests to the Function App arrive at its Private Endpoint in `snet-stamp-1-pe`. This subnet carries only the Function App's *outbound* traffic.

#### Inbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowAzureLBProbes | `AzureLoadBalancer` | `10.155.1.0/24` | `*` | `*` | **Allow** | Azure infrastructure health probes for App Service Plan. |
| 4096 | DenyAllInbound | `*` | `*` | `*` | `*` | **Deny** | No application traffic enters via the VNet integration subnet. |

#### Outbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowToStampPE | `10.155.1.0/24` | `10.155.0.0/24` | 443 | TCP | **Allow** | Function App → Storage Account PEs (blob, file, table, queue). |
| 110 | AllowToSharedPE | `10.155.1.0/24` | `10.155.3.0/24` | 443 | TCP | **Allow** | Function App → ACR PE (container image pull), Key Vault PE (secret retrieval). |
| 120 | AllowToAzureMonitor | `10.155.1.0/24` | `AzureMonitor` | 443 | TCP | **Allow** | App Insights telemetry ingestion and diagnostic data. |
| 130 | AllowDNS | `10.155.1.0/24` | `168.63.129.16/32` | 53 | Any | **Allow** | Azure DNS resolution for Private DNS Zones. |
| 4096 | DenyAllOutbound | `*` | `*` | `*` | `*` | **Deny** | **No internet egress.** Function App has no legitimate need to reach the public internet. |

---

### 6.3 NSG: `nsg-wkld-shared-<env>-apim`

**Attached to:** `snet-apim` (`10.155.2.0/27`)
**Hosted resources:** API Management (internal VNet mode, Developer tier)

APIM in internal VNet mode has **mandatory NSG requirements** documented by Microsoft. These rules are marked as **(Required)** below. Omitting them will cause APIM provisioning or runtime failures.

#### Inbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowVNetClientsToGateway | `VirtualNetwork` | `10.155.2.0/27` | 443 | TCP | **Allow** | VNet clients → APIM gateway endpoint (mTLS-protected API calls). |
| 110 | AllowManagementPlane | `ApiManagement` | `10.155.2.0/27` | 3443 | TCP | **Allow** | **(Required)** Azure management plane → APIM control plane. |
| 120 | AllowAzureLBHealth | `AzureLoadBalancer` | `10.155.2.0/27` | 6390 | TCP | **Allow** | **(Required)** Azure Load Balancer → APIM infrastructure health probe. |
| 130 | AllowJumpboxToApim | `10.155.5.0/27` | `10.155.2.0/27` | 443 | TCP | **Allow** | Jump box → APIM gateway for API testing with mTLS client certificate. |
| 4096 | DenyAllInbound | `*` | `*` | `*` | `*` | **Deny** | No other source may reach APIM. |

#### Outbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowToFuncAppPE | `10.155.2.0/27` | `10.155.0.0/24` | 443 | TCP | **Allow** | APIM → Function App Private Endpoint (backend API call). |
| 110 | AllowToSharedPE | `10.155.2.0/27` | `10.155.3.0/24` | 443 | TCP | **Allow** | APIM → Key Vault PE (retrieve mTLS CA certificate). |
| 120 | AllowToStorage | `10.155.2.0/27` | `Storage` | 443 | TCP | **Allow** | **(Required)** APIM dependency on Azure Storage. |
| 130 | AllowToSQL | `10.155.2.0/27` | `SQL` | 1433 | TCP | **Allow** | **(Required)** APIM dependency on Azure SQL for configuration store. |
| 140 | AllowToKeyVaultSvcTag | `10.155.2.0/27` | `AzureKeyVault` | 443 | TCP | **Allow** | **(Required)** APIM platform dependency on Key Vault (distinct from app-level KV PE access in rule 110). |
| 150 | AllowToEventHub | `10.155.2.0/27` | `EventHub` | 5671, 5672, 443 | TCP | **Allow** | **(Required)** APIM logging and diagnostics pipeline. |
| 160 | AllowToAzureMonitor | `10.155.2.0/27` | `AzureMonitor` | 443, 1886 | TCP | **Allow** | **(Required)** Metrics, diagnostics, and health telemetry. |
| 170 | AllowToAzureAD | `10.155.2.0/27` | `AzureActiveDirectory` | 443 | TCP | **Allow** | **(Required)** Azure AD authentication for APIM management and developer portal. |
| 180 | AllowDNS | `10.155.2.0/27` | `168.63.129.16/32` | 53 | Any | **Allow** | Azure DNS resolution for Private DNS Zones and platform services. |
| 4096 | DenyAllOutbound | `*` | `*` | `*` | `*` | **Deny** | **No internet egress.** All required APIM dependencies are addressed via service tags above. |

---

### 6.4 NSG: `nsg-wkld-shared-<env>-shared-pe`

**Attached to:** `snet-shared-pe` (`10.155.3.0/24`)
**Hosted resources:** ACR Private Endpoint, Key Vault Private Endpoint

#### Inbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowAspToSharedPEs | `10.155.1.0/24` | `10.155.3.0/24` | 443 | TCP | **Allow** | Function App → ACR PE (image pull), Key Vault PE (secret read). |
| 110 | AllowRunnerToSharedPEs | `10.155.4.0/24` | `10.155.3.0/24` | 443 | TCP | **Allow** | GitHub Runner → ACR PE (image push via `az acr login`), Key Vault PE (secret/cert writes). |
| 120 | AllowApimToKeyVaultPE | `10.155.2.0/27` | `10.155.3.0/24` | 443 | TCP | **Allow** | APIM → Key Vault PE (mTLS CA certificate retrieval). |
| 130 | AllowJumpboxToSharedPEs | `10.155.5.0/27` | `10.155.3.0/24` | 443 | TCP | **Allow** | Jump box → ACR PE, Key Vault PE (diagnostics and verification). |
| 4096 | DenyAllInbound | `*` | `*` | `*` | `*` | **Deny** | No other source may reach shared Private Endpoints. |

#### Outbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 4096 | DenyAllOutbound | `*` | `*` | `*` | `*` | **Deny** | Private Endpoints do not initiate outbound connections. |

---

### 6.5 NSG: `nsg-wkld-shared-<env>-runner`

**Attached to:** `snet-runner` (`10.155.4.0/24`)
**Hosted resources:** GitHub Actions VNet-injected runner

The runner is the **only** resource with internet egress. It requires outbound connectivity for GitHub Actions orchestration, package installation, Azure Resource Manager API (Terraform), and Docker image builds.

#### Inbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 4096 | DenyAllInbound | `*` | `*` | `*` | `*` | **Deny** | The runner initiates all connections; no inbound traffic is expected. |

#### Outbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowToSharedPE | `10.155.4.0/24` | `10.155.3.0/24` | 443 | TCP | **Allow** | Runner → ACR PE (image push), Key Vault PE (cert/secret writes). |
| 110 | AllowToStampPE | `10.155.4.0/24` | `10.155.0.0/24` | 443 | TCP | **Allow** | Runner → Storage Account PEs (Terraform data-plane operations in Phase 3). |
| 120 | AllowToInternetHTTPS | `10.155.4.0/24` | `Internet` | 443 | TCP | **Allow** | Runner → Internet via NAT GW: GitHub API, Azure ARM API (Terraform), pip/apt repos, Docker Hub. |
| 130 | AllowToInternetHTTP | `10.155.4.0/24` | `Internet` | 80 | TCP | **Allow** | Runner → Internet via NAT GW: package repository metadata (some repos serve over HTTP). |
| 140 | AllowDNS | `10.155.4.0/24` | `168.63.129.16/32` | 53 | Any | **Allow** | Azure DNS resolution for both Private DNS Zones and public DNS forwarding. |
| 4096 | DenyAllOutbound | `*` | `*` | `*` | `*` | **Deny** | Deny all other outbound (e.g., SSH, non-standard ports). |

---

### 6.6 NSG: `nsg-wkld-shared-<env>-jumpbox`

**Attached to:** `snet-jumpbox` (`10.155.5.0/27`)
**Hosted resources:** Windows 11 jump box VM (Entra ID–authenticated, `AADLoginForWindows` extension)

The jump box provides developer/operator connectivity into the VNet for diagnostics, API testing, and troubleshooting. It is the only resource with a public IP and inbound internet access.

#### Inbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowRDPFromInternet | `Internet` | `10.155.5.0/27` | 3389 | TCP | **Allow** | RDP access to jump box. Authentication enforced via Entra ID — no local passwords. In production, replace with Azure Bastion. |
| 4096 | DenyAllInbound | `*` | `*` | `*` | `*` | **Deny** | No other inbound traffic permitted. |

#### Outbound Rules

| Priority | Name | Source | Destination | Port | Protocol | Action | Justification |
|----------|------|--------|-------------|------|----------|--------|---------------|
| 100 | AllowToStampPE | `10.155.5.0/27` | `10.155.0.0/24` | 443 | TCP | **Allow** | Jump box → Function App PE, Storage PEs (diagnostics and validation). |
| 110 | AllowToSharedPE | `10.155.5.0/27` | `10.155.3.0/24` | 443 | TCP | **Allow** | Jump box → ACR PE, Key Vault PE (image verification, secret inspection). |
| 120 | AllowToApim | `10.155.5.0/27` | `10.155.2.0/27` | 443 | TCP | **Allow** | Jump box → APIM gateway (API testing with mTLS client certificate). |
| 130 | AllowToAzureAD | `10.155.5.0/27` | `AzureActiveDirectory` | 443 | TCP | **Allow** | Entra ID authentication for the AADLoginForWindows extension and user sign-in. |
| 140 | AllowDNS | `10.155.5.0/27` | `168.63.129.16/32` | 53 | Any | **Allow** | Azure DNS resolution for Private DNS Zones. |
| 4096 | DenyAllOutbound | `*` | `*` | `*` | `*` | **Deny** | **No internet egress.** The jump box is for internal diagnostics only, not general browsing. |

---

## 7. NSG Design Rationale — Key Constraints Enforced

The following table maps the user's stated network constraints to the specific NSG rules that enforce them.

| Constraint | How Enforced |
|------------|-------------|
| **Only the GitHub Runner gets internet egress** | NAT Gateway attached only to `snet-runner`. All other subnets have `DenyAllOutbound` at priority 4096 with no preceding internet-bound allow rules. The runner's NSG has explicit `AllowToInternetHTTPS` (120) and `AllowToInternetHTTP` (130). |
| **Function App callable only via APIM** | `snet-stamp-1-pe` inbound rule 100 allows only `10.155.2.0/27` (APIM subnet) on port 443 to reach the Function App PE. No other subnet has a rule permitting traffic to the Function App PE. The ASP and runner rules against `snet-stamp-1-pe` target Storage PEs, not the Function App PE — but since NSGs operate at subnet level, this is a pragmatic trade-off documented in section 8. |
| **ACR reachable from both Runner and Function App** | `snet-shared-pe` inbound rules 100 and 110 allow traffic from `snet-stamp-1-asp` (Function App) and `snet-runner` (GitHub Runner) respectively. Corresponding outbound rules on those source subnets permit egress to `10.155.3.0/24`. |
| **Jump box can reach all internal resources** | `snet-jumpbox` outbound rules 100–120 allow HTTPS to stamp PE, shared PE, and APIM subnets. Corresponding inbound rules on `snet-stamp-1-pe` (130), `snet-shared-pe` (130), and `snet-apim` allow traffic from `10.155.5.0/27`. Jump box has **no internet egress** — only inbound RDP and outbound to VNet resources. |

---

## 8. Design Notes & Trade-offs

### NSG Granularity vs. Subnet-Level Enforcement

Azure NSGs operate at the **subnet level**, not the individual Private Endpoint level. This means that an allow rule permitting `snet-stamp-1-asp → snet-stamp-1-pe:443` grants access to **all** PEs in `snet-stamp-1-pe` (Function App PE + Storage PEs), not just the Storage PEs. Similarly, `snet-runner → snet-stamp-1-pe:443` grants access to both Storage PEs and the Function App PE.

To enforce truly granular PE-level isolation (e.g., preventing the runner from reaching the Function App PE), you have two options:

1. **Separate subnets** — place the Function App PE and Storage PEs in different subnets, each with its own NSG. This increases subnet count but enables precise control.
2. **Application Security Groups (ASGs)** — assign ASGs to individual PE NICs and reference them in NSG rules. This avoids subnet proliferation.

For this design, the pragmatic decision is to **accept subnet-level granularity**. The runner and ASP subnets have no legitimate reason to call the Function App directly (only APIM does), and the Function App's `public_network_access_enabled = false` combined with its authentication model provides defence-in-depth beyond NSG rules alone. If stricter isolation is needed later, ASGs can be retrofitted without re-architecting the subnet layout.

### APIM Mandatory NSG Rules

APIM in internal VNet mode requires specific outbound connectivity to Azure platform services (Storage, SQL, Key Vault, Event Hub, Azure Monitor, Azure AD). These are handled via **service tags**, not internet egress. The APIM subnet's `DenyAllOutbound` rule at priority 4096 does **not** block these flows because the service tag rules at lower priority numbers (higher priority) match first.

### Private Endpoint Network Policies

NSG enforcement on Private Endpoints requires `private_endpoint_network_policies = "Enabled"` on the subnet. This is a subnet-level property set in Terraform via `azurerm_subnet`. Without this, NSG rules on PE subnets are **silently ignored** — a common misconfiguration.

### DNS Resolution

All subnets include an outbound allow rule to `168.63.129.16:53` (Azure DNS). This is the Azure platform DNS resolver that:
- Resolves Private DNS Zone records (e.g., `*.privatelink.azurecr.io` → PE private IP)
- Forwards non-private queries to public DNS (used by the runner for external name resolution)

Without this rule, private endpoint FQDN resolution fails and all private connectivity breaks.

### NSG Flow Logs

All NSGs should have flow logs enabled and streaming to the Log Analytics Workspace. This provides:
- Audit trail of all allowed and denied flows
- Troubleshooting data for connectivity issues during deployment
- Input for Network Watcher Traffic Analytics

This is configured in the `modules/vnet` module when a Log Analytics Workspace ID is supplied.

---

## 9. Resource Naming Summary

| Resource | Name Pattern | Example (dev) |
|----------|-------------|---------------|
| VNet | `vnet-wkld-shared-<env>` | `vnet-wkld-shared-dev` |
| Subnet | `snet-<scope>-<purpose>` | `snet-stamp-1-pe`, `snet-runner` |
| NSG | `nsg-wkld-shared-<env>-<subnet>` | `nsg-wkld-shared-dev-stamp-1-pe` |
| NAT Gateway | `natgw-wkld-shared-<env>` | `natgw-wkld-shared-dev` |
| Public IP (NAT GW) | `pip-natgw-wkld-shared-<env>` | `pip-natgw-wkld-shared-dev` |
| Jump Box VM | `vm-wkld-shared-<env>-jumpbox` | `vm-wkld-shared-dev-jumpbox` |
| Public IP (Jump Box) | `pip-vm-wkld-shared-<env>-jumpbox` | `pip-vm-wkld-shared-dev-jumpbox` |
| NIC (Jump Box) | `nic-vm-wkld-shared-<env>-jumpbox` | `nic-vm-wkld-shared-dev-jumpbox` |

---

## 10. Terraform Implementation Notes

### VNet Module Integration

The `modules/vnet` module already accepts a list of subnet objects. The NAT Gateway and its Public IP should be provisioned in the Phase 1 root config and the NAT Gateway ID passed into the subnet definition for `snet-runner`. 
### NSG Rules in the VNet Module

NSG rules can be defined as part of the subnet object passed to the VNet module, or as separate `azurerm_network_security_rule` resources in the root config. Given the complexity and per-subnet variation, defining rules in the root config (referencing NSG IDs from `module.vnet.nsg_ids`) is recommended for readability.

### Private Endpoint Network Policies

Ensure all PE subnets set this property:

```hcl
private_endpoint_network_policies = "Enabled"
```

This is set on the `azurerm_subnet` resource within the VNet module.
