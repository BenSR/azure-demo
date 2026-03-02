# Solution Design

Design decisions and rationale for the infrastructure architecture.

---

## Workload — Stamp-Based Model

The workload is structured as repeatable **stamps** — each stamp is a self-contained unit of compute (ASP, Function App, Storage, App Insights, Key Vault). Stamps are a Terraform module (`modules/workload-stamp`); adding a new instance is one `for_each` entry in `.tfvars`.

This supports multi-region scale-out without architecture changes. If a stamp fails, only that stamp is affected — a shared Key Vault was deliberately rejected to prevent cross-stamp failure propagation.

## Resource Group Model

Four resource groups per environment, each reflecting a different lifecycle:

| Resource Group | Scope | Contents |
|----------------|-------|----------|
| `rg-core-deploy` | Manual, pre-Terraform | State storage account |
| `rg-core` | Cross-environment | ACR, VNet, NSGs, NAT GW, DNS zones, Log Analytics, Jump box, Runner |
| `rg-wkld-shared-<env>` | Per-environment | APIM |
| `rg-wkld-stamp-<N>-<env>` | Per-stamp, per-env | ASP, Function App, Storage, App Insights, Key Vault, PEs |

## Environment Strategy

Terraform workspaces drive `phase1/env` and `phase2/env` only. `phase1/core` is deployed once and is environment-agnostic. `phase3` (Application Gateway) is also deployed once — it routes to all environments via URL path-based routing.

Core outputs (subnet IDs, ACR details, DNS zone IDs) are consumed downstream via `terraform_remote_state`. The `default` workspace maps to `dev` as a safety net.

## Multi-Stamp Support

Stamps are defined in two places:

- **`phase1/core/terraform.tfvars`** — subnet CIDRs for every stamp across all environments. The VNet module creates each subnet pair.
- **`phase1/env/<env>.tfvars`** — stamp runtime definitions (image, location). Subnet IDs are resolved from core remote state by naming convention.

NSG rules for stamp subnets are generated dynamically via `for_each` in the `workload-stamp-subnet` module — adding a stamp auto-generates all firewall rules with collision-safe priority offsets.

## Compute

Python HTTP-triggered Function App, packaged as a Docker container, hosted on a Linux App Service Plan (B1 SKU, overridden from the module default of P1v3 for cost efficiency). Each stamp can run multiple functions on one plan — cheaper, and networking is simpler since the whole plan shares one VNet integration.

Health monitoring via App Insights availability tests against a health endpoint, plus alert rules on 5xx error rate.

## API Management

APIM sits outside the stamp module — it's a shared front door, not per-instance. Internal VNet mode, Developer tier, in a delegated subnet. APIM uses a custom domain (`internal.contoso.com`) with a certificate signed by the project CA. A private DNS zone resolves the APIM hostname to its private IP within the VNet.

APIM authenticates to Function App backends using Managed Identity + Entra ID tokens. The API policy includes random stamp load-balancing and per-stamp backend routing.

## Application Gateway (Phase 3)

An Application Gateway (Standard_v2) provides **public ingress with mTLS termination**. It sits in its own subnet and routes `/api/<env>/*` to the appropriate environment's APIM instance using URL path-based routing with rewrite rules that strip the environment prefix.

The App GW enforces client certificate validation against the project CA. A self-signed server cert is stored in a dedicated Key Vault (`kv-appgw-core`), accessed by a User-Assigned Managed Identity.

## Container Registry

Premium SKU ACR (required for Private Endpoint support), behind a PE in the shared-PE subnet. A self-hosted runner VM inside the VNet handles image pushes. The ACR name uses a subscription-ID hex prefix for global uniqueness.

## Networking

### VNet Design

A single shared VNet (a `/16`) hosts all environments. Fixed shared subnets occupy the upper address range; stamp subnets are allocated sequentially in the lower range. This avoids per-environment VNet management complexity.

**Fixed subnets** (4, created by `modules/vnet`):

| Subnet | Delegation | Purpose |
|--------|-----------|---------|
| Runner | None | Self-hosted GitHub Actions runner. NAT GW for internet egress. |
| Jumpbox | None | Windows 11 diagnostic VM. |
| APIM | `Microsoft.ApiManagement/service` | Internal VNet mode API Management. |
| Shared PE | None | Private Endpoints for shared resources (ACR). |

**Per-stamp subnets** (2 per stamp per env, created by `modules/workload-stamp-subnet`):

| Subnet | Delegation | Purpose |
|--------|-----------|---------|
| PE | None | PEs for Function App, Storage (×4 services), Key Vault. PE network policies enabled. |
| ASP | `Microsoft.Web/serverFarms` | Function App VNet integration (outbound traffic). |

**Phase 3 subnet** (created directly by `phase3/network.tf`):

| Subnet | Purpose |
|--------|---------|
| App GW | Application Gateway with internet ingress and outbound to APIM. |

### Private DNS

Eight Private DNS Zones linked to the VNet — seven `privatelink.*` zones covering Key Vault, Storage (blob/file/table/queue), ACR, and Function App, plus `internal.contoso.com` for APIM custom domain resolution.

### NSGs

One NSG per subnet. Deny-all inbound by default, explicit allow rules per documented traffic flows. Only the runner and jumpbox subnets permit internet egress — all others deny it at the NSG level despite NAT Gateway being attached to all subnets.

## Developer Connectivity — Jump Box

A Windows 11 VM with a public IP for RDP, authenticated via Entra ID (`AADLoginForWindows` extension). It sits inside the VNet and automatically resolves private DNS records — no VPN Gateway or DNS Resolver needed.

A Custom Script Extension provisions Azure CLI, Git, and an end-to-end test script (`Test-Application-Jumpbox.ps1`) that validates mTLS, DNS resolution, and API responses from inside the VNet.

In production, Azure Bastion would replace the public IP + RDP pattern.

## Certificate Management & mTLS

Terraform's `tls` provider generates a self-signed CA and a client cert signed by it. Phase 2 writes both to each stamp's Key Vault via the VNet runner.

mTLS is enforced at two levels:

1. **Application Gateway** — validates client certificates against the CA as a trusted root. An SSL profile enforces mTLS on the HTTPS listener.
2. **APIM** — can additionally validate the client cert thumbprint via a Named Value (useful when App GW is bypassed for internal VNet testing via the jumpbox).

## Observability

- **App Insights** per stamp — workspace-based, backed by shared Log Analytics (`law-core`). OpenTelemetry integration via `azure-monitor-opentelemetry`.
- **Diagnostic settings** on all resources: Function App, Key Vault, APIM, ACR, Log Analytics, Storage (all 4 services).
- **NSG flow logs** — disabled (Azure blocked new creation from June 2025; flag retained for future re-enablement).
- **Alert rules** — 5xx error rate (metric + KQL scheduled query), availability percentage. Action group with email receivers. Thresholds are environment-specific.
- **Availability web tests** — per stamp against health endpoint via APIM. Disabled by default (APIM is internal-only); enabled once App GW provides a public path.

## Identity & Permissions

- **Service Principal** — OIDC federated credentials for GitHub Actions (no long-lived secrets).
- **Managed Identities** — System-assigned on Function App (ACR pull, KV read, Storage access) and APIM (KV cert read, Entra ID token acquisition). User-assigned on App GW (KV cert access).
- **Entra ID app registrations** — one per stamp per env, used as token audiences for EasyAuth.

## Three-Phase Deployment

### Phase 1 — Bootstrap (GitHub-hosted runner)

Split into two root modules:

**`phase1/core/`** — foundational infra (deployed once): Resource Groups, VNet + subnets + NSGs, Private DNS (8 zones), ACR + PE, Log Analytics, NAT Gateway, Jump Box, Self-Hosted Runner, TLS cert generation.

**`phase1/env/`** — workload layer (workspace-driven, reads core via remote state): Resource Groups, APIM (internal mode, custom domain), Entra ID app registrations, Workload stamps (ASP, Function App, Storage, Key Vault, App Insights, PEs, role assignments).

### Phase 2 — Private Data-Plane Ops (self-hosted runner)

`phase2/env/` is workspace-driven  and reads remote state from both `phase1/core` and `phase1/env`. Runs from the VNet runner to reach private endpoints.

| File | Purpose |
|------|---------|
| `secrets.tf` | Writes CA cert, client cert/key, and deploy webhook URLs into each stamp's Key Vault |
| `apim-config.tf` | APIM backends (per stamp), API definition, operations, load-balancing policy with MI auth |
| `alerts.tf` | Metric alerts, KQL scheduled queries, availability web tests, action groups |

### Phase 3 — Application Gateway (not workspace-driven)

`phase3/` is a flat root module that reads remote state from core and both env workspaces simultaneously. Deploys the Application Gateway (Standard_v2) with public IP, mTLS SSL profile, URL path-based routing per environment, dedicated subnet/NSG, dedicated Key Vault with server cert, and a User-Assigned Managed Identity.
