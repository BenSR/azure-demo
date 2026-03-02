# Gap Analysis — Requirements vs. Delivered Solution

Assessment of every requirement against the implemented solution.

> **Assessment date:** 2 March 2026

---

## Summary

| Category | Total | Met | Partially Met | Not Met |
|----------|-------|-----|---------------|---------|
| Functional Requirements (Core) | 22 | 22 | 0 | 0 |
| Functional Requirements (Stretch) | 7 | 7 | 0 | 0 |
| Nonfunctional Requirements (Core) | 15 | 15 | 0 | 0 |
| Nonfunctional Requirements (Stretch) | 5 | 5 | 0 | 0 |
| Technology Constraints | 6 | 6 | 0 | 0 |
| Infrastructure Constraints | 2 | 2 | 0 | 0 |
| Delivery Constraints | 10 | 10 | 0 | 0 |

**Overall:** 67 / 67 fully met.

---

## 1. Functional Requirements

### Networking (FR-1)

| ID | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| FR-1.1 | VNet with at least two subnets | **Met** | Shared VNet with 9+ subnets (4 fixed + per-stamp pairs + App GW). |
| FR-1.2 | NSG per subnet with least-privilege rules | **Met** | One NSG per subnet, deny-all baseline, explicit allow rules. |
| FR-1.3 | Private Endpoints for all consumed services | **Met** | PEs for ACR, Function App, Storage (×4), Key Vault — all with DNS zone groups. |
| FR-1.4 | API access restricted to VNet only | **Met** | APIM internal VNet mode. Function App, Storage, KV: public access disabled. |
| FR-1.5 | Application Gateway for ingress | **Met** | Standard_v2 App GW with mTLS SSL profile, URL path routing per env, public IP. |

### Compute (FR-2)

| ID | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| FR-2.1 | Deploy Azure Function App | **Met** | Containerised Python app in `modules/workload-stamp`. |
| FR-2.2 | Accept HTTP POST with JSON `message` | **Met** | POST `/api/message` with Pydantic validation. |
| FR-2.3 | Validate payload; reject invalid | **Met** | Structured 400 errors for all validation edge cases. 15+ test cases. |
| FR-2.4 | Return message + timestamp + request_id | **Met** | ISO 8601 UTC timestamp, request ID from Azure/APIM headers or UUID4. |
| FR-2.5 | Graceful error handling | **Met** | Try/except wrapper, structured JSON errors, no stack traces exposed. |
| FR-2.6 | VNet integration | **Met** | `virtual_network_subnet_id` on Function App, `vnet_image_pull_enabled = true`. |

### API Layer (FR-3)

| ID | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| FR-3.1 | Expose Function through APIM or PE | **Met** | Both — APIM API layer + Function App PE for direct VNet access. |
| FR-3.2 | API layer internal-only | **Met** | APIM internal VNet mode, no public APIM endpoint. Public ingress via App GW. |

### Certificates & mTLS (FR-4)

| ID | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| FR-4.1 | Self-signed CA | **Met** | RSA 4096-bit CA via `tls` provider. |
| FR-4.2 | Client cert signed by CA | **Met** | RSA 2048-bit, `client_auth` extended key usage. |
| FR-4.3 | Certs in Key Vault | **Met** | Phase 2 writes CA cert, client cert/key to each stamp's KV. |
| FR-4.4 | mTLS on API layer | **Met** | App GW SSL profile enforces mTLS with CA as trusted root. APIM validates thumbprint. |
| FR-4.5 | Require valid cert for API calls | **Met** | E2E test from jumpbox confirms 403 without client cert. |

### Observability (FR-5)

| ID | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| FR-5.1 | App Insights on Function App | **Met** | Per-stamp App Insights, OpenTelemetry SDK, connection string in app settings. |
| FR-5.2 | Log Analytics for aggregation | **Met** | Shared `law-core`, workspace-based App Insights. |
| FR-5.3 | At least one alert rule | **Met** | Three alert types per stamp: request failures, 5xx KQL query, availability. |
| FR-5.4 | Log all API requests | **Met** | Requests excluded from sampling. APIM GatewayLogs to LAW. Structured logging with request ID. |
| FR-5.5 | Diagnostic settings on all resources | **Met** | Function App, KV, APIM, ACR, LAW, Storage (all 4 services). |

### Supporting Infrastructure (FR-6)

| ID | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| FR-6.1 | Storage with VNet-restricted access | **Met** | No public access, deny-all network rules, Azure Services bypass, 4 PEs. |
| FR-6.2 | Key Vault for secrets/certs | **Met** | Per-stamp KV, RBAC auth, no public access, PE. |

### Health (FR-7) / CI/CD (FR-8) / Identity (FR-9) / Testing (FR-10) / Env Separation (FR-11) / Modules (FR-12)

| ID | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| FR-7.1 | Health monitoring | **Met** | Health endpoint + availability web test (disabled by default, enabled once App GW provides public path). |
| FR-8.1–8.4 | CI/CD (fmt, validate, plan, OIDC) | **Met** | 8 workflow files, OIDC federated credentials, plan output in job summaries. |
| FR-9.1 | Managed Identities, no shared secrets | **Met** | System MI on Function App + APIM, User MI on App GW. RBAC everywhere. |
| FR-10.1 | Automated infrastructure tests | **Met** | `terraform test` with mock providers for all 4 modules. Runs in CI. |
| FR-11.1 | Environment separation | **Met** | Workspaces (dev/prod) + per-env `.tfvars`. |
| FR-12.1 | Reusable modules | **Met** | 4 modules, all parameterised, instantiated via `for_each`. |

---

## 2. Nonfunctional Requirements

| ID | Area | Status | Summary |
|----|------|--------|---------|
| NFR-1.1–1.7 | Security | **All Met** | No public PaaS exposure, least-privilege NSGs, certs in KV, mTLS enforced, Storage VNet-restricted, OIDC CI/CD, MI for all service-to-service. |
| NFR-2.1–2.4 | Auditability | **All Met** | All API requests logged, centralised in LAW, diagnostic settings everywhere. |
| NFR-3.1–3.2 | Reliability | **All Met** | Health endpoint operational, 3 alert types with action group. |
| NFR-4.1–4.5 | Maintainability | **All Met** | Logical file organisation, consistent naming, variables/locals, fmt + validate in CI. |
| NFR-5.1–5.2 | Modularity | **All Met** | 4 reusable modules, workspace-based env separation. |
| NFR-6.1 | Testability | **Met** | `terraform test` with mock providers across all modules. |

---

## 3. Constraints

| ID | Constraint | Status |
|----|------------|--------|
| TC-1 | Terraform for all infra | **Met** — 3 Terraform roots + phase3. Only `rg-core-deploy` and SP are pre-Terraform. |
| TC-2 | Certs via Terraform `tls` provider | **Met** |
| TC-3 | Self-signed certs acceptable | **Met** |
| TC-4 | GitHub Actions CI/CD | **Met** — 8 workflows. |
| TC-5 | APIM Developer or Consumption tier | **Met** — Developer_1. |
| TC-6 | Any supported language | **Met** — Python 3.11. |
| IC-1 | Remote state | **Met** — Azure Blob Storage backend, workspace-namespaced. |
| IC-2 | Free Tier / credits | **Met** — B1 ASP, Standard_B2s VMs, Developer APIM, Standard_v2 App GW. |
| DC-1–DC-6,8–10 | Delivery (README, setup, teardown, OIDC, etc.) | **All Met** |
| DC-7 | AI critique | **Met** — General patterns table, 7 critique categories, and 4 detailed prompt-level examples with specific observations. |

---

## 4. Resolved Gaps

### Gap 1: Availability Web Test (FR-7.1)

Added `azurerm_application_insights_standard_web_test` per stamp in `phase2/env/alerts.tf`. Disabled by default because APIM is internal — probes can't reach it. Fully wired; enable via `web_test_enabled = true` once public ingress is available.

### Gap 2: Diagnostic Settings Coverage (FR-5.5 / NFR-2.4)

Added diagnostic settings for ACR, LAW (self-diagnostic), and Storage (blob/file/table/queue per-service). All resources now stream to `law-core`.

### Gap 3: Infrastructure Testing (FR-10.1 / NFR-6.1)

Added `.tftest.hcl` files for all 4 modules using `mock_provider` — no Azure credentials needed, runs in seconds. 30+ assertions covering naming, security hardening, NSG priorities, EasyAuth config.

### Gap 4: Application Gateway (FR-1.5) — Now Resolved

Previously listed as not implemented. Phase 3 (`terraform/phase3/`) now deploys an Application Gateway (Standard_v2) with:
- Public IP for external ingress
- mTLS SSL profile with the project CA as trusted client cert root
- URL path-based routing (`/api/<env>/*`) with rewrite rules
- Dedicated KV, User-Assigned MI, subnet, NSG
- Cross-cutting NSG rules allowing App GW → APIM traffic

### Gap 5: AI Critique (DC-7) — Now Resolved

The README "AI Usage & Critique" section now contains a usage-by-phase table, a 7-row critique table covering patterns (over-modularisation, permissive defaults, stale provider knowledge, missing cross-cutting concerns, hallucinated resources, doc drift, naming inconsistency), and 4 detailed prompt examples with specific observations and mitigations.

### Gap 6: README ACR Cost Estimate — Now Resolved

The README cost table now correctly lists ACR as Premium tier (~£42/month), matching the Terraform configuration.

---

## 5. Remaining Gaps

No remaining gaps. All 67 requirements and constraints are fully met.
