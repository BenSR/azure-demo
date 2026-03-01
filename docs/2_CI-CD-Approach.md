# CI/CD Approach

Three path-scoped pipelines — core infrastructure, workload infrastructure, and application code — sharing the same branch model and approval gate.

---

## 1. Branch → Environment Model

Terraform workspaces are the source of truth for environments. Branches map to workspaces:

| Branch | Terraform workspace | Image tag | Stamps targeted |
|--------|--------------------|-----------|-----------------|
| `dev`  | `dev`              | `:dev`    | dev stamps      |
| `main` | `prod`             | `:latest` | prod stamps     |

Development happens on short-lived feature branches. A feature PR merges to `dev` first (integration, auto-deploy), then a promotion PR merges `dev` into `main` (prod, gated).

```
feature/xyz ──PR──► dev ──PR──► main
                     │             │
                  workspace:dev  workspace:prod
                  auto-deploy    gated deploy
```

---

## 2. Runner Requirements

Two runner types are used. GitHub-hosted runners handle everything that only needs Azure ARM API access (Terraform control plane, tests, linting). The self-hosted runner — a small Ubuntu VM (`vm-runner-core`) in `snet-runner` inside `vnet-core` — is used for any job that needs to reach private data-plane endpoints.

| Job | Runner | Why |
|-----|--------|-----|
| Lint / validate / test | GitHub-hosted (`ubuntu-latest`) | No Azure network access needed |
| `phase1/core` plan + apply | GitHub-hosted | Terraform ARM API only (no private endpoints) |
| `phase1/env` plan + apply | GitHub-hosted | Terraform ARM API only; KV data plane not accessed |
| `phase3` plan + apply | **Self-hosted** (`[self-hosted, linux]`) | Must reach private KV and APIM endpoints inside VNet |
| Docker build + push to ACR | **Self-hosted** | ACR has `public_network_access_enabled = false` |
| Webhook deploy | **Self-hosted** | Kudu SCM endpoint only reachable from inside VNet |

The runner VM is registered with GitHub manually after Terraform provisioning (see [Infrastructure Implementation Planning](Infrastructure-Implementation-Planning)). It uses the label set `self-hosted,linux` by convention; update the workflow `runs-on` labels if you configure different labels during registration.

---

## Pipeline 1: Core Infrastructure

_Triggered on changes to `terraform/phase1/core/`_

Core infrastructure (VNet, ACR, Log Analytics, NAT Gateway, Jump Box) is deployed once — no workspace, no dev/prod split. Changes here are infrequent and high-impact. A plan runs on dev merges so the effect is visible before it reaches main; the apply is always gated.

### Feature Branch — Lint & Validate

Runs on the public runner. No Azure credentials required.

```
Push to any branch
  → (public runner)
    → terraform fmt -check -recursive
    → tflint --recursive
    → terraform validate   # phase1/core
```

Failures block the PR from merging.

### Merge to `dev` — CI + Plan

Produces a plan against the live core state. No apply — core has no dev workspace and is not auto-deployed.

```
Merge to dev
  → (public runner)
    → terraform fmt -check -recursive
    → tflint --recursive
    → terraform -chdir=phase1/core plan -out=/tmp/tfplan-core
    → Plan summary posted to Actions job summary
```

### Merge to `main` — Plan, Approve, Apply

```
Merge to main
  │
  ├── PLAN (public runner)
  │     → terraform -chdir=phase1/core plan \
  │           -out=/tmp/tfplan-core
  │     → az storage blob upload \
  │           --container-name tfplans \
  │           --name "core-${GITHUB_RUN_ID}.tfplan" \
  │           --file /tmp/tfplan-core
  │     → Plan summary posted to Actions job summary
  │
  ├── APPROVAL (GitHub Actions `prod` environment)
  │     → Workflow pauses — reviewer inspects plan
  │     → Approves or rejects
  │
  └── APPLY (public runner)
        → az storage blob download "core-${GITHUB_RUN_ID}.tfplan"
        → terraform -chdir=phase1/core apply tfplan-core
```

---

## Pipeline 2: Workload Infrastructure

_Triggered on changes to `terraform/phase1/env/` or `terraform/phase3/`_

Workspace-driven (`dev` / `prod`). `phase1/env` and `phase3` are deployed sequentially — phase3 reads phase1/env remote state, so it cannot run until phase1/env apply completes. Dev auto-applies; prod is gated.

### Feature Branch — Lint & Validate

```
Push to any branch
  → (public runner)
    → terraform fmt -check -recursive
    → tflint --recursive
    → terraform validate   # phase1/env
    → terraform validate   # phase3
```

Validates all workspace-driven roots. A change to the `workload-stamp` module is caught against both consumers.

### Merge to `dev` — Plan + Auto-Apply

Low-friction: plan and apply happen automatically. Failures here are caught before they can affect prod.

```
Merge to dev
  ├── phase1/env (public runner)
  │     → terraform workspace select dev
  │     → terraform plan -var-file=terraform.tfvars -var-file=dev.tfvars -out=tfplan
  │     → terraform apply tfplan
  │
  └── phase3 (self-hosted runner — runs after phase1/env apply succeeds)
        → terraform workspace select dev
        → terraform plan -var-file=terraform.tfvars -var-file=dev.tfvars -out=tfplan
        → terraform apply tfplan
```

If phase1/env apply fails, phase3 is skipped.

### Merge to `main` — Plan, Store, Approve, Apply

Prod changes require a reviewer to inspect the plan before anything is applied. Plan files are uploaded to blob storage so the apply step uses the exact plan that was reviewed — no drift risk from state changes between plan and apply.

```
Merge to main
  │
  ├── PLAN (GitHub-hosted for phase1/env, self-hosted for phase3)
  │     → terraform workspace select prod
  │     → terraform -chdir=phase1/env plan \
  │           -var-file=terraform.tfvars -var-file=prod.tfvars \
  │           -out=/tmp/tfplan-env-prod
  │     → az storage blob upload \
  │           --container-name tfplans \
  │           --name "env-prod-${GITHUB_RUN_ID}.tfplan" \
  │           --file /tmp/tfplan-env-prod
  │
  │     → terraform -chdir=phase3 plan \
  │           -var-file=terraform.tfvars -var-file=prod.tfvars \
  │           -out=/tmp/tfplan-phase3-prod
  │     → az storage blob upload \
  │           --container-name tfplans \
  │           --name "phase3-prod-${GITHUB_RUN_ID}.tfplan" \
  │           --file /tmp/tfplan-phase3-prod
  │
  │     → Plan summaries posted to Actions job summary
  │
  ├── APPROVAL (GitHub Actions `prod` environment)
  │     → Workflow pauses — reviewer inspects plan
  │     → Approves or rejects
  │
  └── APPLY (GitHub-hosted for phase1/env, self-hosted for phase3)
        → az storage blob download "env-prod-${GITHUB_RUN_ID}.tfplan"
        → terraform -chdir=phase1/env apply tfplan-env-prod
        → (wait for phase1/env to complete)
        → az storage blob download "phase3-prod-${GITHUB_RUN_ID}.tfplan"
        → terraform -chdir=phase3 apply tfplan-phase3-prod
```

Plans are stored in the `tfplans` container of the state storage account (`rg-core-deploy`). Blobs are keyed by `GITHUB_RUN_ID` so each run has its own plan pair. A retention policy on the container cleans up blobs older than 30 days.

The approval gate is implemented as a [GitHub Actions environment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) named `prod` with required reviewers configured. The same environment is reused by the code pipeline.

---

## Pipeline 3: Application Code

_Triggered on changes to application source (everything outside `terraform/`)_

### Feature Branch — Test & Build

Catches failures on every branch before anything reaches dev or prod.

```
Push to any branch
  ├── (GitHub-hosted) Test
  │     → pip install -r requirements.txt
  │     → pytest tests/ -v --cov=core --cov=functions
  │     → (fail if coverage < 90%)
  │
  └── (self-hosted) Build
        → docker build -t wkld-api:ci .
        → (image discarded — push step not run)
```

The Docker build runs on the self-hosted runner because it will need ACR access in the push step; using the same runner for both avoids environment differences between validate and real builds.

### Merge to `dev` — Test, Build, Push, Deploy

```
Merge to dev
  → (GitHub-hosted) Test
      → pytest tests/ --cov ... (fail fast)

  → (self-hosted) Build + push + deploy
      → az acr login --name acrcore
      → docker build -t acrcore.azurecr.io/wkld-api:dev .
      → docker push acrcore.azurecr.io/wkld-api:dev
      → WEBHOOK=$(az keyvault secret show \
            --vault-name kv-wkld-1-dev \
            --name deploy-webhook-url \
            --query value -o tsv)
      → curl -s -X POST "$WEBHOOK"
```

### Merge to `main` — Test, Build, Push, Approve, Deploy

The image is pushed to ACR before the approval gate so the reviewer can inspect it (`az acr repository show-tags`) as part of the approval decision. The deploy step is then fast — no build time after approval. If approval is rejected, the image sits in ACR unused; the running prod environment is unaffected (the Function App only pulls when the webhook is called).

```
Merge to main
  │
  ├── (GitHub-hosted) Test
  │     → pytest tests/ --cov ... (fail fast)
  │
  ├── (self-hosted) Build + push
  │     → az acr login --name acrcore
  │     → docker build -t acrcore.azurecr.io/wkld-api:latest .
  │     → docker push acrcore.azurecr.io/wkld-api:latest
  │
  ├── APPROVAL (GitHub Actions `prod` environment — same gate as infra)
  │     → Workflow pauses
  │     → Reviewer confirms image is ready to deploy
  │     → Approves or rejects
  │
  └── (self-hosted) Deploy
        → WEBHOOK=$(az keyvault secret show \
              --vault-name kv-wkld-1-prod \
              --name deploy-webhook-url \
              --query value -o tsv)
        → curl -s -X POST "$WEBHOOK"
```

### Webhook Mechanism

The Kudu container deployment webhook (`/api/registry/webhook`) instructs the Function App platform to pull the latest image digest behind the configured tag and restart atomically. It is used instead of `az functionapp restart` (which does not force a pull) and instead of ACR native webhooks (which originate from the public internet and cannot reach the private SCM endpoint).

The webhook URL embeds publishing credentials and is stored as `deploy-webhook-url` in each stamp's Key Vault. It is written there by Phase 3 Terraform (VNet runner), which is the only runner that can reach the private KV data plane.

---

## 3. Promotion Flow — Dev to Prod

```
feature/xyz
    │
    ▼  PR review + merge
   dev ─────────────────────────── auto-deploy → dev stamps
    │
    ▼  PR review + merge (promotion PR: dev → main)
  main ────── plan → approval ──── apply infra → prod stamps
         └─── test → push ──────── approval → deploy → prod stamps
```

Promotion to prod is a deliberate act — a PR from `dev` to `main`, reviewed and merged by a team member, triggering the gated pipelines. There is no automatic promotion.
