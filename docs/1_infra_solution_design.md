# Solution Design

Design notes and decisions as I go.

---
## Workload

### Multi-instance capability

The spec asks for a single deployment, however we should structure things in advance of a multi-region/multi-instance ask. This can be accommodated by making the core workload components - App Service Plans, Function Apps, and supporting infra - a terraform module. This makes additional instance deployments far easier, and is a low-effort design decision to make now.

We will refer to each instance of the workload as a "stamp" - so we will have "workload-stamp-1" for example. Each stamp will have its own ASP, Function App, Storage Account, Key Vault, App Insights etc. The shared infrastructure (ACR, APIM, Log Analytics Workspace) will be outside the stamp module and shared between them. I am deliberately *NOT* going to make the ASP a shared component between stamps. This would make network isolation much harder and make multi-region impossible - so this is a design choice I am making. 

### Function App / App Service Plan

Python HTTP-triggered app, packaged as a Docker container, hosted on a Linux App Service Plan. Module takes a map of container definitions — can run multiple functions on one plan. Cheaper, and networking is simpler since the whole plan shares one VNet integration.

Input validation, error handling, response shape (message, timestamp, request ID) — all straightforward. The real challenge is making sure the Function App can talk to its dependencies (Storage, Key Vault, ACR) over private networking. Managed Identity + Private Endpoints should handle that.

Health monitoring: App Insights availability test against a health endpoint. Alert rules off that plus 5xx error rate.


## API Management (APIM)

APIM lives outside the workload module — shared component, not per-instance. Multiple Function App instances? Balance across them via APIM. One APIM, many backends. Also a clean place to terminate mTLS, enforce policies, centralise request logging. Developer tier for this assessment; pattern stays the same at higher tiers.

Own subnet, delegated to `Microsoft.ApiManagement/service`, internal mode only. No public endpoint. VNet clients → APIM → Function App backends.


## Container Registry (ACR)

I need an ACR to host the Function App build image. It will be a Python-based app, built into a Docker container. The ACR will need to be behind a Private Endpoint — so a managed VNet GitHub runner will be needed to connect to it. I'll also need to make sure the Service Principal used by GitHub Actions and the Function App Managed Identity have the relevant permissions.


## Networking

Networking is going to be a key feature of this design. The requirement for Private Endpoints also brings a requirement to do private DNS etc. I will keep all the networking componentry outside of the core workload components as they are separate concerns.

### VNet Design

The solution will require a single VNet for the present time. A hub-spoke architecture would enable better multi-region, however this is not something that will be pursued for now.

The workload can be anticipated to need at least four subnets to begin with:

- **Stamp PE Subnet** — for Private Endpoints, internal load balancers, anything that doesn't need a specific delegation.
- **Stamp ASP Subnet** — delegated to `Microsoft.Web/serverFarms` for the Function App's VNet integration.
- **Shared APIM Subnet** — delegated to `Microsoft.ApiManagement/service` for the internal-mode APIM deployment.
- **Shared PE Subnet** — for shared resources like ACR, Key Vault, Log Analytics. No delegation, just Private Endpoints.
- **Shared GitHub Runner Subnet** — for the GitHub VNET-injected runner, which needs to be able to access all private resources and will be delegated to the github runner service.

VNet module takes an array of subnet objects — adding subnets later is just another list element. Each object: name, CIDR, delegation, service endpoints. No copy-paste.

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
- **Authentication:** Entra ID login via the `AADLoginForWindows` VM extension. No local admin password stored.
- **Public IP:** Static Standard SKU, used for RDP access.
- **Subnet:** Dedicated `snet-jumpbox` subnet with an NSG allowing inbound RDP (3389) from the internet and outbound HTTPS to the VNet's PE subnets.
- **No NAT Gateway** — the jump box does not need general internet egress; it is a diagnostic tool for reaching internal resources.


## Certificate Management & mTLS

Use Terraform `tls` provider to generate a self-signed CA + client cert signed by it. Store both in Key Vault. Configure APIM to trust only my CA as the client cert truststore — clients need a cert I've signed. Makes sense since APIM is already the front door; mTLS terminates there, Function App backends don't need to know about client certs. No external dependencies, demonstrates the pattern without buying a real CA.


## Observability

- **App Insights** on the Function App — tracing, dependency tracking, live metrics.
- **Log Analytics Workspace** — central sink, everything goes here.
- **Diagnostic settings** on every resource, streaming to Log Analytics. Technically a stretch goal but it's a few lines of TF per resource, just doing it.
- **Alert rule** on 5xx error rate — practical, easy to demo.


## Identity & Permissions

- **Service Principal** federated via OIDC — GitHub Actions auth to Azure for Terraform.
- **Managed Identities** on Function App — ACR pull, Key Vault access, Storage. No shared secrets.


## Two-stage (really three-stage) deployment

Can't do everything in one `terraform apply` — networking chicken-and-egg.

### Phase 1 — Bootstrap (GitHub-hosted runner)

Foundational infra, no private network access needed:

- Resource Groups
- VNet + subnets + NSGs
- Private DNS Zones
- ACR (with Private Endpoint)
- Key Vault (with Private Endpoint)
- Storage Account (with network rules — but no containers yet)
- APIM (internal mode, in its own subnet)
- Log Analytics / App Insights
- App Service Plan / Function App. 

### Phase 2 — Manual Github Setup

I will get GitHub setup to inject the managed runner into the subnet.

### Phase 3 — Private data-plane ops (self-hosted runner)

- Build and push the container image to ACR.
- Create Storage Account blob containers, file shares, etc.
- Write secrets/certificates into Key Vault.
- Wire up diagnostic settings, alert rules, mTLS config.

#### Why not one apply?

Terraform tries to `ListKeys` / list blob containers on Storage Accounts during `plan`. Network rules locked down + runner outside VNet = 403 - Terraform stops planning. So: Phase 1 sets up networking + runner, Phase 3 only runs from inside the VNet where those calls work. Additionally, the certificate operations will fail if the Key Vault is locked down behind a Private Endpoint and the runner is outside the VNet, so those also need to be in Phase 3.


## Repo Layout

This phased approach informs the directory structure:

```
terraform/
  modules/
    priv-dns/      # Private DNS creation
    vnet/          # VNet + subnets + NSGs + Private DNS VNET Linking
    function-app/  # App Service Plan + Function App + supporting infra
    ...            # other reusable modules
  phase1/          # bootstrap infra (runs on hosted runner)
    main.tf
    variables.tf
    ...
  phase3/          # private deploys (runs on self-hosted VNet runner)
    main.tf
    variables.tf
    ...
```

Each phase = own root module, own state file. Shared modules, planned/applied independently. Phase 2 reads Phase 1 outputs via `terraform_remote_state` (or pipe through CI/CD vars — either works).


## CI/CD Pipeline

GitHub Actions workflow mirrors the phases:

1. **Validate** — `fmt -check` + `validate` on both phases.
2. **Plan Phase 1** — hosted runner, OIDC auth, `terraform plan`.
3. **Apply Phase 1** — on merge to main.
4. **Plan/Apply Phase 2** — self-hosted runner from Phase 1, private-network work.

OIDC federation = no stored secrets in GitHub. SP trusts tokens from repo branch/environment. Document Entra ID app registration + federated credential setup in README.

---

*Next: module interfaces, then get Phase 1 standing up.*
