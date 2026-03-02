# Azure Cloud Platform Engineering Demo

A fully private, mTLS-secured Azure Function API deployed via Terraform and GitHub Actions.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Setup & Deployment](#setup--deployment)
4. [OIDC Authentication](#oidc-authentication)
5. [Teardown](#teardown)
6. [Assumptions](#assumptions)
7. [Estimated Azure Costs](#estimated-azure-costs)
8. [AI Usage & Critique](#ai-usage--critique)

---

## Architecture

### Overview

The solution exposes an internal API (Python Azure Function) through APIM with mTLS enforcement, fronted by an Application Gateway for public ingress. All PaaS services are fully private — no public endpoints.

Infrastructure is organised into four resource group tiers, each with a distinct lifecycle:

| Tier | Resource group | Contents | Deployed by |
|------|----------------|----------|-------------|
| Bootstrap | `rg-core-deploy` | Terraform state storage, OIDC service principal | Manual (bootstrap script) |
| Core | `rg-core` | VNet, ACR, Log Analytics, NAT GW, DNS zones, VMs | Phase 1 (core) |
| Env-shared | `rg-wkld-shared-{env}` | APIM (per-environment) | Phase 1 (env) |
| Stamp | `rg-wkld-stamp-{N}-{env}` | Function App, Storage, Key Vault, App Insights | Phase 1 (env) |

Environments (`dev`, `prod`) are managed via Terraform workspaces. Stamps are repeatable workload instances within an environment — APIM load-balances across them.

### Architecture Diagram

<!-- TODO: Replace with architecture diagram -->

> *Placeholder — architecture diagram to be added.*

### Network Diagram

<!-- TODO: Replace with network diagram -->

> *Placeholder — network topology diagram to be added.*

### Request Flow

<!-- TODO: Replace with request flow diagram -->

> *Placeholder — request flow diagram showing: Client → App GW (mTLS) → APIM (internal) → Function App PE.*

---

## Prerequisites

| Requirement | Detail |
|-------------|--------|
| Azure subscription | Owner or Contributor + User Access Administrator |
| Azure CLI | v2.55+ (federated credential support) |
| Terraform | v1.6+ (for `terraform test` support) |
| GitHub repo | Public, with Actions enabled |
| `jq` | Used by the bootstrap script |
| Docker | On the self-hosted runner (auto-installed) |

---

## Setup & Deployment

### 1. Bootstrap (manual, one-time)

The bootstrap script creates the resources that must exist before Terraform runs:

```bash
bash scripts/prepare-azure-env.sh \
  --repo <owner/repo> \
  --location northeurope
```

This creates:
- `rg-core-deploy` resource group
- Terraform state storage account (+ `tfstate` and `tfplans` containers)
- App Registration + Service Principal with OIDC federated credentials
- Role assignments: Owner (subscription), Storage Blob Data Contributor (state SA), Application Developer + Directory Readers (Entra ID), Microsoft Graph `Application.ReadWrite.All`

The script prints the GitHub secrets and environments to configure (see [OIDC Authentication](#oidc-authentication)).

### 2. Configure GitHub

Add the following as GitHub Actions repository secrets:

| Secret | Value |
|--------|-------|
| `ARM_CLIENT_ID` | App Registration client ID (from bootstrap output) |
| `ARM_TENANT_ID` | Entra ID tenant ID |
| `ARM_SUBSCRIPTION_ID` | Target subscription ID |
| `TF_STATE_STORAGE_ACCOUNT` | State storage account name |
| `RUNNER_MANAGEMENT_PAT` | GitHub PAT with `manage_runners:repo` scope |

Create two GitHub environments:
- **`dev`** — no approval gates
- **`prod`** — add required reviewers

### 3. Core Infrastructure (`phase1/core`)

Deployed once, not workspace-driven. Creates the VNet, ACR, Log Analytics, Private DNS zones, NAT Gateway, certificates, jump box, and self-hosted runner.

```bash
terraform -chdir=terraform/phase1/core init \
  -backend-config="resource_group_name=rg-core-deploy" \
  -backend-config="storage_account_name=<SA_NAME>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=phase1-core.tfstate"

terraform -chdir=terraform/phase1/core apply
```

> **Note:** The self-hosted runner VM registers itself with GitHub Actions automatically via Custom Script Extension. Allow a few minutes after apply for registration to complete.

### 4. Environment Infrastructure (`phase1/env`)

Workspace-driven — deploys APIM, Entra ID app registrations, and workload stamps per environment.

```bash
terraform -chdir=terraform/phase1/env init \
  -backend-config="resource_group_name=rg-core-deploy" \
  -backend-config="storage_account_name=<SA_NAME>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=phase1-env.tfstate"

terraform -chdir=terraform/phase1/env workspace select -or-create dev
terraform -chdir=terraform/phase1/env apply \
  -var-file=terraform.tfvars -var-file=dev.tfvars
```

Repeat with `prod` workspace and `prod.tfvars` for production.

### 5. Configuration, Secrets & Alerts (`phase2/env`)

Workspace-driven. **Must run from the self-hosted runner** — it writes to private Key Vaults and configures private APIM endpoints.

```bash
terraform -chdir=terraform/phase2/env init \
  -backend-config="resource_group_name=rg-core-deploy" \
  -backend-config="storage_account_name=<SA_NAME>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=phase2-env.tfstate"

terraform -chdir=terraform/phase2/env workspace select dev
terraform -chdir=terraform/phase2/env apply \
  -var-file=terraform.tfvars -var-file=dev.tfvars
```

This deploys: APIM backends/API/policies, Key Vault secrets (CA cert, client cert, webhook URLs), alert rules, and availability tests.

### 6. Application Gateway (`phase3`)

Deployed once, not workspace-driven. Reads remote state from all environments to configure per-env URL path routing.

```bash
terraform -chdir=terraform/phase3 init \
  -backend-config="resource_group_name=rg-core-deploy" \
  -backend-config="storage_account_name=<SA_NAME>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=phase3.tfstate"

terraform -chdir=terraform/phase3 apply -var-file=terraform.tfvars
```

### 7. Application Deployment

The application is a containerised Python Azure Function. The CI/CD pipeline builds, pushes to ACR, and deploys via Kudu webhook — but for manual deployment:

```bash
# Build and push (from VNet runner or machine with ACR access)
az acr login --name <acr_name>
docker build -t <acr_name>.azurecr.io/wkld-api:dev function_app/
docker push <acr_name>.azurecr.io/wkld-api:dev

# Trigger deployment via webhook (URL stored in each stamp's Key Vault)
curl -X POST "<webhook_url>"
```

### CI/CD Pipelines

Eight GitHub Actions workflows handle the full lifecycle. See [docs/2_CI-CD-Approach.md](docs/2_CI-CD-Approach.md) for the complete pipeline design.

| Workflow | Trigger | Runner |
|----------|---------|--------|
| Validate (fmt, validate, test) | PR / push | GitHub-hosted |
| Core infra (plan/apply) | Changes to `phase1/core/` | GitHub-hosted |
| Env infra (3 tiers sequentially) | Changes to `phase1/env/`, `phase2/`, `phase3/` | Mixed |
| App build + deploy | Changes to `function_app/` | Mixed |

Branch model: `dev` auto-deploys, `main` is gated with approval.

---

## OIDC Authentication

GitHub Actions authenticates to Azure using OpenID Connect — no long-lived secrets.

### How it works

1. The bootstrap script creates an App Registration with federated credentials for each GitHub Actions context (branch push, environment, pull request).
2. Workflows use `azure/login@v2` with OIDC, exchanging a GitHub-issued JWT for an Azure access token.
3. The JWT subject claim (`repo:<owner>/<repo>:ref:refs/heads/<branch>` or `:environment:<env>`) is validated against the registered federated credentials.

### Federated Credentials

| Credential | Subject | Used by |
|------------|---------|---------|
| `github-push-main` | `repo:<owner/repo>:ref:refs/heads/main` | Infra plan on main push |
| `github-push-dev` | `repo:<owner/repo>:ref:refs/heads/dev` | Infra plan on dev push |
| `github-env-prod` | `repo:<owner/repo>:environment:prod` | Gated apply to prod |
| `github-env-dev` | `repo:<owner/repo>:environment:dev` | Auto-apply to dev |
| `github-pull-request` | `repo:<owner/repo>:pull_request` | PR validation |

### Service Principal Permissions

| Permission | Scope | Why |
|------------|-------|-----|
| Owner | Subscription | Create resources + assign RBAC roles |
| Storage Blob Data Contributor | State storage account | Read/write Terraform state + plan files |
| Application Developer | Entra ID directory | Create app registrations (EasyAuth) |
| Directory Readers | Entra ID directory | Resolve users/groups in Terraform |
| Application.ReadWrite.All | Microsoft Graph | Create service principals for app registrations |

---

## Teardown

### Automated (reverse order)

Destroy in reverse deployment order. Phase 2 and Phase 3 must be destroyed from the self-hosted runner (private endpoint access required).

```bash
# 1. Application Gateway
terraform -chdir=terraform/phase3 destroy -var-file=terraform.tfvars

# 2. Config, secrets, alerts (each workspace)
terraform -chdir=terraform/phase2/env workspace select prod
terraform -chdir=terraform/phase2/env destroy \
  -var-file=terraform.tfvars -var-file=prod.tfvars

terraform -chdir=terraform/phase2/env workspace select dev
terraform -chdir=terraform/phase2/env destroy \
  -var-file=terraform.tfvars -var-file=dev.tfvars

# 3. Environment infrastructure (each workspace)
terraform -chdir=terraform/phase1/env workspace select prod
terraform -chdir=terraform/phase1/env destroy \
  -var-file=terraform.tfvars -var-file=prod.tfvars

terraform -chdir=terraform/phase1/env workspace select dev
terraform -chdir=terraform/phase1/env destroy \
  -var-file=terraform.tfvars -var-file=dev.tfvars

# 4. Core infrastructure
terraform -chdir=terraform/phase1/core destroy
```

### Manual cleanup (after Terraform destroy)

These resources are created outside Terraform and must be removed manually:

| Resource | How to remove |
|----------|---------------|
| `rg-core-deploy` (state storage) | `az group delete --name rg-core-deploy` |
| App Registration + Service Principal | `az ad app delete --id <APP_ID>` |
| Entra ID role assignments | Removed automatically when the SP is deleted |
| GitHub Actions secrets | Remove from Repository → Settings → Secrets |
| GitHub environments (`dev`, `prod`) | Remove from Repository → Settings → Environments |
| Self-hosted runner registration | Auto-deregisters when VM is destroyed; or manually in GitHub Settings → Actions → Runners |

### Ordering constraints

- Phase 2 resources (APIM config, KV secrets) must be destroyed before Phase 1 (which owns the APIM and KV instances).
- Phase 3 (App GW) should be destroyed before Phase 1 core (which owns the VNet/subnets).
- The self-hosted runner (Phase 1 core) must remain available until Phase 2 and Phase 3 are destroyed.

---

## Assumptions

| ID | Assumption |
|----|------------|
| A-1 | A single Azure subscription and tenant are available for deployment. |
| A-2 | The implementer has Owner or Contributor access to the target Azure subscription. |
| A-3 | All resources are greenfield — no existing VNet, Key Vault, or shared infrastructure to reuse. |
| A-4 | DNS resolution for Private Endpoints uses Azure Private DNS Zones (no custom DNS server). |
| A-5 | The API is consumed only by clients within the same VNet or via the Application Gateway (no cross-VNet or on-premises peering). |
| A-6 | Single region deployment (North Europe). Multi-region is out of scope. |
| A-7 | No data residency or compliance requirements beyond what the spec states. |
| A-8 | GitHub repository secrets and environments are configured manually (documented, not automated). |
| A-9 | Global resource naming collisions (e.g. storage accounts) are accepted as unlikely — a clash at apply time is immediately obvious. |
| A-10 | A Windows jump box with Entra ID RDP is used instead of VPN Gateway or Bastion for VNet access — avoids the complexity of private DNS resolvers. |

---

## Estimated Azure Costs

Monthly cost estimate for a single environment (dev, 2 stamps). Prices are approximate (UK South / North Europe, pay-as-you-go).

| Resource | SKU | Approx. monthly cost |
|----------|-----|---------------------|
| APIM | Developer | ~£37 |
| ACR | Premium | ~£42 |
| App Service Plan (×2) | B1 | ~£24 (£12 each) |
| Application Gateway | Standard_v2 (1 unit) | ~£140 |
| Jump box VM | Standard_B2s | ~£27 |
| Runner VM | Standard_B2s | ~£27 |
| Log Analytics | PerGB2018 | ~£2 (low volume) |
| Storage Accounts (×2) | Standard_LRS | ~£2 |
| Key Vaults (×3) | Standard | ~£0 (pay-per-operation) |
| NAT Gateway + Public IPs (×3) | Standard | ~£30 + £10 |
| Private Endpoints (×13) | — | ~£10 |
| App Insights (×2) | — | ~£0 (included in LAW) |
| **Total (1 env)** | | **~£350/month** |

> **Cost-saving notes:**
> - Stop VMs when not in use (`az vm deallocate`) — saves ~£54/month.
> - The Application Gateway is the single largest cost. In a real assessment environment, deploy it last and destroy it first.
> - APIM Developer tier has no SLA and is not suitable for production.
> - Adding a `prod` environment roughly doubles stamp and APIM costs (~£130 more), but core resources (VNet, ACR, LAW, VMs, App GW, NAT GW) are shared.

---

## AI Usage & Critique

AI coding assistants (GitHub Copilot with Claude) were used extensively throughout this project. A full prompt log is maintained in [AI_Prompt_Log.md](AI_Prompt_Log.md).

### How AI was used

| Phase | Usage |
|-------|-------|
| Requirements extraction | Extracted and structured requirements from the specification |
| Solution design | Generated initial design docs, refined through iterative prompting |
| Implementation planning | Module structure, naming conventions, workspace strategy |
| Terraform code | Generated initial module and root code, heavily reviewed and refactored |
| Python Function App | Generated initial app code and tests |
| CI/CD workflows | Generated GitHub Actions workflow files |
| Documentation | Generated and updated documentation to reflect actual implementation |

### Critique of AI Output

| Pattern | Observation | Mitigation |
|---------|-------------|------------|
| Over-modularisation | AI tends to wrap everything in modules, even singletons (ACR, LAW). Adds indirection without reuse benefit. | Explicit instruction to only modularise where reuse is expected. |
| Permissive defaults | Generated NSG rules were too broad (e.g. `*` for source). Storage accounts defaulted to public access. | Manual review hardened all security posture. Deny-all baseline added. |
| Stale provider knowledge | Some generated code used deprecated attributes or old provider syntax. | Ran `terraform validate` and fixed issues. |
| Missing cross-cutting concerns | AI-generated modules didn't account for cross-subnet NSG rules (e.g. APIM → Function App). | Added `workload-stamp-subnet` module to handle cross-cutting rules. |
| Hallucinated resources | Occasionally referenced Azure resources or attributes that don't exist in the provider. | Caught by `terraform validate` and plan. |
| Doc drift | AI-generated docs described intended design, not actual implementation. Phase numbering, resource names, and feature completeness diverged. | Full doc refresh against actual codebase. |
| Naming inconsistency | Generated code didn't follow the stated naming convention consistently. | Manual pass to enforce `<abbr>-wkld-<N>-<env>` pattern. |

---

## Documentation

Detailed design and planning documents are in the [docs/](docs/) directory:

| Document | Content |
|----------|---------|
| [Functional Requirements](docs/0_Functional-Requirements.md) | What the system shall do |
| [Nonfunctional Requirements](docs/0_Nonfunctional-Requirements.md) | Security, reliability, maintainability |
| [Constraints & Assumptions](docs/0_Constraints-and-Assumptions.md) | Project boundaries and working assumptions |
| [Solution Design](docs/1_Infrastructure-Solution-Design.md) | Architecture decisions and design rationale |
| [Technical Design](docs/1_Infrastructure-Technical-Design.md) | Network topology, NSG rules, DNS |
| [Implementation Planning](docs/1_Infrastructure-Implementation-Planning.md) | Module structure, phases, workspace workflow |
| [Bill of Materials](docs/1_Azure-Infrastructure-Bill-of-Materials.md) | Complete Azure resource inventory |
| [APIM Planning](docs/2_APIM-Planning.md) | API Management configuration and auth flow |
| [Application Planning](docs/2_Application-Planning.md) | Function App design, API spec, observability |
| [CI/CD Approach](docs/2_CI-CD-Approach.md) | Pipeline design, runners, promotion model |
| [Gap Analysis](docs/3_Gap-Analysis.md) | Requirements vs. delivered solution |
