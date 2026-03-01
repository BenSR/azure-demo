# Solution Design

Design notes and decisions as I go.

---
## Workload

### Multi-instance capability

The spec asks for a single deployment, however we should structure things in advance of a multi-region/multi-instance ask. This can be accommodated by making the core workload components - App Service Plans, Function Apps, and supporting infra - a terraform module. This makes additional instance deployments far easier, and is a low-effort design decision to make now.

We will refer to each instance of the workload as a "stamp" - so we will have "workload-stamp-1" for example. Each stamp will have its own ASP, Function App, Storage Account, App Insights, and **Key Vault**. The stamp is designed as a self-contained regional unit — if a region fails, only that stamp is affected; a shared KV would propagate the failure to all stamps. The shared infrastructure (APIM, ACR, VNet, observability) will be outside the stamp module. I am deliberately *NOT* going to make the ASP a shared component between stamps. This would make network isolation much harder and make multi-region impossible — so this is a design choice I am making.

### Resource Group Model

Four resource groups per environment, each reflecting a different lifecycle and sharing boundary:

| Resource Group | Naming | What lives here |
|----------------|--------|----------------|
| `rg-core-deploy` | No env | **Manually created** before first `terraform init`. Holds the state storage account for all Terraform roots (`phase1/core`, `phase1/env`, `phase3`). Not managed by Terraform. |
| `rg-core` | No env, no workload prefix | **Cross-environment core platform**: ACR, Log Analytics, VNet, NSGs, NAT GW, Private DNS zones, Jump box. Deployed **once**, shared across all environments — resources here carry no env suffix. |
| `rg-wkld-shared-<env>` | Per-env | **Per-environment shared**: APIM only (Key Vault has moved into each stamp). Shared front door, differs by environment. |
| `rg-wkld-stamp-<N>-<env>` | Per-stamp, per-env | **Per-stamp compute**: ASP, Function App(s), Storage Account, App Insights, Key Vault, stamp-scoped Private Endpoints. One RG per stamp × per environment. |

The `phase1/env` workspace (`dev`, `prod`) owns its own complete set of per-environment resources. Core resources in `rg-core` are shared and workspace-independent.

### Environment Strategy — Terraform Workspaces

**Terraform workspaces apply to `phase1/env/` and `phase3/` only.** The `phase1/core/` root is deployed once without workspace selection — it is environment-agnostic. Core outputs (subnet IDs, ACR details, LAW ID, DNS zone IDs) are consumed by `phase1/env/` and `phase3/` via remote state.

```
# phase1/env — workspace-driven
terraform workspace select dev   → deploys dev APIM + stamp layer
terraform workspace select prod  → deploys prod APIM + stamp layer
```

Environment-specific stamp definitions live in per-workspace `.tfvars` files (`dev.tfvars`, `prod.tfvars`). Shared configuration (subscription ID, location, APIM publisher) remains in `terraform.tfvars`.

The built-in `default` workspace maps to `dev` as a safety net — an unconfigured workspace never silently targets production.

`phase1/core/` uses a single `terraform.tfvars` with all environments' stamp subnet CIDRs declared together. This is what allows a single shared VNet to host subnets for all environments simultaneously.

### Multi-Stamp Support

Stamp definitions are split across two root modules:

**`phase1/core/terraform.tfvars`** — declares all environments' subnet CIDRs in a single flat list. Adding a stamp requires an entry here so the VNet module creates the subnet pair:

```hcl
stamp_subnets = [
  { environment = "dev",  stamp_name = "1", subnet_pe_cidr = "10.100.0.0/24", subnet_asp_cidr = "10.100.1.0/24" },
  { environment = "dev",  stamp_name = "2", subnet_pe_cidr = "10.100.2.0/24", subnet_asp_cidr = "10.100.3.0/24" },
  { environment = "prod", stamp_name = "1", subnet_pe_cidr = "10.100.6.0/24", subnet_asp_cidr = "10.100.7.0/24" },
]
```

**`phase1/env/dev.tfvars`** — declares the workload stamps for that env (image, location). These reference the subnet pairs created above by name convention (`snet-stamp-dev-<N>-pe/asp`):

```hcl
stamps = [
  { stamp_name = "1", location = "northeurope", image_name = "wkld-api", image_tag = "latest" },
  { stamp_name = "2", location = "northeurope", image_name = "wkld-api", image_tag = "latest" },
]
```

NSG rules for stamp subnets and cross-cutting rules (on APIM, shared-PE, runner, jumpbox NSGs) are generated dynamically using `for_each` inside the `modules/workload-stamp-subnet` module, so adding a stamp automatically produces the correct firewall rules.

### Function App / App Service Plan

Python HTTP-triggered app, packaged as a Docker container, hosted on a Linux App Service Plan. Module takes a map of container definitions — can run multiple functions on one plan. Cheaper, and networking is simpler since the whole plan shares one VNet integration.

Input validation, error handling, response shape (message, timestamp, request ID) — all straightforward. The real challenge is making sure the Function App can talk to its dependencies (Storage, Key Vault, ACR) over private networking. Managed Identity + Private Endpoints should handle that.

Health monitoring: App Insights availability test against a health endpoint. Alert rules off that plus 5xx error rate.


## API Management (APIM)

APIM lives outside the workload module — shared component, not per-instance. Multiple Function App instances? Balance across them via APIM. One APIM, many backends. Also a clean place to terminate mTLS, enforce policies, centralise request logging. Developer tier for this assessment; pattern stays the same at higher tiers.

Own subnet, delegated to `Microsoft.ApiManagement/service`, internal mode only. No public endpoint. VNet clients → APIM → Function App backends.


## Container Registry (ACR)

I need an ACR to host the Function App build image. It will be a Python-based app, built into a Docker container. The ACR will need to be behind a Private Endpoint — so a self-hosted runner VM inside the VNet will be needed to connect to it. I'll also need to make sure the Service Principal used by GitHub Actions and the Function App Managed Identity have the relevant permissions. The ACR name uses an 8-character hex prefix derived from the subscription ID for global uniqueness (e.g. `acrcore09d0073b`).


## Networking

Networking is going to be a key feature of this design. The requirement for Private Endpoints also brings a requirement to do private DNS etc. I will keep all the networking componentry outside of the core workload components as they are separate concerns.

### VNet Design

A single shared VNet (`vnet-core`, `10.100.0.0/16`) hosts all environments. This avoids per-environment VNet management complexity and enables a simple, auditable egress model. Subnets for different environments co-exist in the same VNet, distinguished by environment in the subnet name (`snet-stamp-<env>-<N>-pe`).

The `/16` (65,536 IPs) provides ample room for many stamps across all environments. Fixed shared subnets occupy the upper range (`10.100.128.0+`); stamp subnets occupy the lower range sequentially.

Two categories of subnets:

**Fixed shared subnets** (one per VNet, created by `modules/vnet`):
- **`snet-apim`** — delegated to `Microsoft.ApiManagement/service` for the internal-mode APIM.
- **`snet-shared-pe`** — Private Endpoints for shared resources (ACR). No delegation.
- **`snet-runner`** — self-hosted runner VM (`vm-runner-core`). No delegation. NAT Gateway attached for internet egress.
- **`snet-jumpbox`** — Windows 11 jump box VM. No delegation.

**Per-stamp subnets** (one pair per stamp per env, created by `modules/workload-stamp-subnet`):
- **`snet-stamp-<env>-<N>-pe`** — Private Endpoints for stamp resources (Function App, Storage, Key Vault). PE network policies enabled.
- **`snet-stamp-<env>-<N>-asp`** — delegated to `Microsoft.Web/serverFarms` for Function App VNet integration.

VNet module takes an array of subnet objects. Stamp subnets are created by a separate `workload-stamp-subnet` module which also manages their NSGs and all NSG rules.

### Private DNS

Every PaaS service behind a Private Endpoint needs a Private DNS Zone linked to the VNet — Key Vault (`privatelink.vaultcore.azure.net`), Storage (`privatelink.blob.core.windows.net`, etc.), ACR (`privatelink.azurecr.io`). Stand these up in Phase 1.

### NSGs

One NSG per subnet. Deny all inbound by default, open only what's needed (HTTPS between subnets, outbound to Azure services). Log denied flows to Log Analytics.


## Developer Connectivity — Jump Box

To debug and validate the deployed environment, I need a way to connect into the VNet and reach private resources (APIM, Private Endpoints, etc.). The two main options are:

1. **VPN Gateway** — Azure Point-to-Site VPN. Clean solution, but requires a Private DNS Resolver or a DNS server VM to resolve the Azure Private DNS Zones from the VPN client. This adds significant complexity and cost (VPN Gateway + DNS Resolver) that is outside the scope of this assessment.
2. **Jump Box VM** — A small Windows 11 VM with a public IP, sitting in its own subnet inside the VNet. Because it is *inside* the VNet, it automatically resolves Private DNS Zone records via Azure DNS (`168.63.129.16`) with no additional infrastructure. Connect via RDP, authenticated through Entra ID (AADLoginForWindows extension).

I am choosing the **jump box** approach. It is simpler, cheaper, and avoids the DNS resolver dependency entirely. In a production environment, Azure Bastion would replace the public IP + RDP pattern — but Bastion is outside scope here.

The VM will be:
- **OS:** Windows 11, small SKU (e.g., `Standard_B2s`).
- **Authentication:** Entra ID login via the `AADLoginForWindows` VM extension. Random local admin password (retrievable via `scripts/get-jumpbox-creds.sh`).
- **Public IP:** Static Standard SKU, used for RDP access.
- **Subnet:** Dedicated `snet-jumpbox` subnet with an NSG allowing inbound RDP (3389) from the internet and outbound HTTPS to the VNet's PE subnets.
- **No NAT Gateway** — the jump box does not need general internet egress; it is a diagnostic tool for reaching internal resources.


## Certificate Management & mTLS

Use Terraform `tls` provider to generate a self-signed CA + client cert signed by it. Store both in Key Vault. Configure APIM to trust only my CA as the client cert truststore — clients need a cert I've signed. Makes sense since APIM is already the front door; mTLS terminates there, Function App backends don't need to know about client certs. No external dependencies, demonstrates the pattern without buying a real CA.


## Observability

- **App Insights** on the Function App — tracing, dependency tracking, live metrics.
- **Log Analytics Workspace** — central sink, everything goes here.
- **Diagnostic settings** on every resource, streaming to Log Analytics. Technically a stretch goal but it's a few lines of TF per resource, just doing it.
- **NSG flow logs** — disabled. Azure blocked new NSG flow log creation from June 2025; the `flow_logs_enabled` flag is set to `false`.
- **Alert rule** on 5xx error rate — practical, easy to demo.


## Identity & Permissions

- **Service Principal** federated via OIDC — GitHub Actions auth to Azure for Terraform.
- **Managed Identities** on Function App — ACR pull, Key Vault access, Storage. No shared secrets.


## Two-stage (really three-stage) deployment

Can't do everything in one `terraform apply` — networking chicken-and-egg.

### Phase 1 — Bootstrap (GitHub-hosted runner)

Split into two independent root modules within `phase1/`:

**`phase1/core/`** — foundational infra (rarely changes):
- Resource Groups (core only)
- VNet + subnets + NSGs
- Private DNS Zones
- ACR (with Private Endpoint)
- Log Analytics
- NAT Gateway + Jump Box
- CI/CD Identity (SP + OIDC federation)
- TLS cert generation (CA + client cert)

**`phase1/env/`** — workload layer (changes more often, reads `core/` via remote state):
- Resource Groups (shared + stamp)
- APIM (internal mode, in its own subnet)
- Module call: `modules/workload-stamp` per stamp — ASP, Function App(s), Storage Account, **Key Vault**, App Insights, all PEs

### Phase 2 — Runner Registration (Automated via Custom Script Extension)

The runner VM (`vm-runner-core`) is provisioned by Terraform in Phase 1 and automatically configured via a Custom Script Extension that runs `setup-runner.sh`. This script installs Docker, Azure CLI, Node.js 20, downloads the GitHub Actions runner agent, exchanges a `RUNNER_MANAGEMENT_PAT` for a short-lived registration token, and registers the runner with the `self-hosted,linux` label set. The runner agent runs as a systemd service.

### Phase 3 — Private data-plane ops (self-hosted runner)

Phase 3 lives at `terraform/phase3/env/`, is workspace-driven (like `phase1/env/`), and reads remote state from both `phase1/core/` and `phase1/env/`:

| File | Purpose |
|------|---------|
| `main.tf` | Provider config (`azurerm` + `azuread`), backend, remote state for both `core` and `env`. Environment derived from workspace. |
| `secrets.tf` | Writes the CA certificate and client certificate (generated by `phase1/core/certificates.tf`) into each stamp's Key Vault. Requires data-plane access — only possible from inside the VNet. |
| `apim-config.tf` | Creates APIM backends (one per stamp's Function App PE), API definition, operations, and the mTLS client-certificate validation policy using the CA cert from Key Vault. Includes load-balancing policy that uses `Random.Next()` to select a stamp and acquires per-stamp Entra MI tokens. |
| `alerts.tf` | Monitor metric alerts (5xx rate, availability test failures), App Insights standard web tests against the Function App health endpoint via APIM, and the shared Action Group (email/webhook). Alert thresholds are environment-specific (dev: 10 failures / 95% availability; prod: 3 failures / 99.9% availability). |
| `variables.tf` | Shared variables: subscription, tenant, location, state account name, per-env tuning (alert thresholds, test probe frequency). |
| `outputs.tf` | APIM gateway URL, alert rule IDs, web test IDs. |

#### Why not one apply?

Terraform tries to `ListKeys` / list blob containers on Storage Accounts during `plan`. Network rules locked down + runner outside VNet = 403 — Terraform stops planning. So: Phase 1 sets up networking + runner, Phase 3 only runs from inside the VNet where those calls work. Certificate data-plane writes to Key Vault also require VNet access.


## Repo Layout

The phased + workspace approach informs the directory structure:

```
terraform/
  modules/
    private-dns/           # 7 Private DNS zones + named ID outputs
    vnet/                  # VNet + fixed subnets + NSGs + DNS links + flow logs
    workload-stamp/        # ASP + Function App + Storage + Key Vault + App Insights + PEs + role assignments
    workload-stamp-subnet/ # Per-stamp subnet pair (PE + ASP) + NSGs + all NSG rules (stamp + cross-cutting)
  phase1/
    core/          # Foundational infra — deployed ONCE, not workspace-driven
                   # Shared across all environments; runs on GitHub-hosted runner
      terraform.tfvars    # All values: subscription, location, jump box, ALL stamp_subnets across all envs
    env/           # Workload layer (APIM, stamps) — workspace-driven (dev/prod)
                   # Reads core/ outputs via remote_state; runs on GitHub-hosted runner
      terraform.tfvars    # Shared values (subscription, location, APIM publisher)
      dev.tfvars          # dev stamps: stamp_name, image, location
      prod.tfvars         # prod stamps
  phase3/
    env/             # Private data-plane ops — workspace-driven (dev/prod)
                     # Runs on self-hosted runner VM
      main.tf             # Provider config + remote state (reads core + env outputs)
      secrets.tf          # CA + client cert writes to per-stamp Key Vaults
      apim-config.tf      # APIM backends, API, operations, mTLS policy
      alerts.tf           # Monitor alerts, web tests, action groups
      variables.tf
      outputs.tf
      terraform.tfvars    # Shared values (subscription, location, state account)
      dev.tfvars
      prod.tfvars
```

**State topology:** All three roots store state in the same `rg-core-deploy` storage account (container: `tfstate`). Keys: `phase1-core.tfstate` (single, no workspace), `env:/dev/phase1-env.tfstate` (per workspace), `env:/dev/phase3-env.tfstate` (per workspace). `phase1/env/` and `phase3/env/` read `phase1/core/` outputs via `terraform_remote_state`; `phase3/env/` additionally reads `phase1/env/` outputs.


## CI/CD Pipeline

Eight GitHub Actions workflows (`infra-validate`, `infra-core-dev`, `infra-core-prod`, `infra-workload-dev`, `infra-workload-prod`, `app-pr`, `app-dev`, `app-prod`) mirror the phased deployment:

1. **Validate** (`infra-validate.yml`) — `fmt -check` + `tflint` + `validate` on all phases. Triggers on feature branch pushes and PRs.
2. **Core infra** — plan-only on dev merge (`infra-core-dev`), plan → approval → apply on main merge (`infra-core-prod`).
3. **Workload infra** — sequential phase1/env then phase3/env. Auto-apply on dev (`infra-workload-dev`), TWO separate approval gates on prod (`infra-workload-prod`).
4. **App** — test + build-check on PRs (`app-pr`), test + build + push + webhook deploy on dev (`app-dev`), test + build + push → approval → webhook deploy on prod (`app-prod`).

Deployment uses Kudu container deployment webhooks (stored in Key Vault) rather than `az functionapp restart`, which ensures the Function App actually pulls the latest image digest.

OIDC federation = no stored secrets in GitHub. SP trusts tokens from repo branch/environment. Additional secret: `RUNNER_MANAGEMENT_PAT` (GitHub PAT for runner registration).

---

*Updated to reflect actual implementation.*
