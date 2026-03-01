# APIM Planning — API Layer & Authentication

Configuration and design for the APIM API layer, mTLS termination, and APIM → Function App authentication.

> See [Application Planning](Application-Planning) for the Function App application design.
> See [Infrastructure Solution Design](Infrastructure-Solution-Design) for APIM infrastructure (Developer tier, internal VNet mode).

---

## 1. Authentication — APIM → Function App

The Function App has `public_network_access_enabled = false` and is only reachable via its Private Endpoint. Network isolation (NSG rules restrict the PE subnet to APIM-sourced traffic on port 443) provides the first layer of protection. However, network isolation alone is not authentication — a compromised resource in the APIM subnet could call the Function App without proving its identity. Defence in depth requires identity-based authentication **on top of** network controls.

### 1.1 Authentication Model: Managed Identity + Entra ID (EasyAuth)

APIM already has a system-assigned Managed Identity (configured in `phase1/env/apim.tf`). The Function App will use Azure's built-in authentication middleware ("EasyAuth") to validate that incoming requests carry a valid Entra ID token issued to APIM's identity.

```
Client ──mTLS──► APIM ──MI token──► Function App PE
                  │                       │
                  │ 1. APIM policy calls   │ 3. EasyAuth middleware
                  │    authentication-     │    validates JWT:
                  │    managed-identity    │    - issuer = Entra ID
                  │    to get a JWT for    │    - audience = Function App's
                  │    the Function App's  │      app registration client ID
                  │    app registration    │    - token is not expired
                  │                       │
                  │ 2. Attaches token as   │ 4. Valid → request reaches
                  │    Authorization:      │    function code
                  │    Bearer <jwt>        │    Invalid → 401 before code runs
                  └───────────────────────►│
```

### 1.2 Components Required

| Component | What | Where Configured |
|-----------|------|-----------------|
| **Entra ID App Registration** | Represents the Function App as a resource that can receive tokens. Created per-environment (e.g., `app-func-wkld-api-dev`). Has an Application ID URI (e.g., `api://func-wkld-1-api-dev`). No client secret — it is a token *audience*, not a token *requester*. | Terraform: `phase1/env/` or `phase3/` — `azuread_application` + `azuread_service_principal`. |
| **Function App EasyAuth (v2)** | Built-in authentication on the Function App. Configured to require Entra ID tokens. Rejects unauthenticated requests with 401 before they reach function code. | Terraform: `azurerm_linux_function_app` → `auth_settings_v2` block. |
| **APIM Managed Identity** | APIM's system-assigned MI requests a token scoped to the Function App's app registration. | Already exists in `phase1/env/apim.tf`. |
| **APIM Inbound Policy** | `<authentication-managed-identity>` policy element in the APIM API/operation policy. Acquires and attaches the Bearer token on every backend call. | Terraform: `phase3/apim-config.tf` — `azurerm_api_management_api_policy`. |

### 1.3 Entra ID App Registration

One `azuread_application` + `azuread_service_principal` per Function App, per environment. No client secret or certificate is created on this registration — it exists purely as a token audience.

- **Display name** follows the pattern `app-func-{workload}-{stamp}-api-{env}` (e.g., `app-func-wkld-1-api-dev`).
- **Identifier URI** follows `api://func-{workload}-{stamp}-api-{env}` — this is the **audience** that APIM requests a token for, and that EasyAuth validates in the incoming JWT.
- No `required_resource_access` — this app registration receives tokens, it doesn't call other APIs.
- Created in `phase1/env/` or `phase3/`, iterated per stamp.

### 1.4 Function App EasyAuth Configuration

EasyAuth v2 is configured via the `auth_settings_v2` block on the `azurerm_linux_function_app` resource in the `workload-stamp` module. It validates Entra ID tokens without any application code changes.

Key behaviours:

| Setting | Value | Effect |
|---------|-------|--------|
| `auth_enabled` | `true` | Enables the EasyAuth middleware. |
| `require_authentication` | `true` | Every request must carry a valid token. No anonymous access. |
| `unauthenticated_action` | `Return401` | Unauthenticated requests get a 401 immediately — no redirect to a login page. |
| `allowed_audiences` | `api://func-{workload}-{stamp}-api-{env}` | The JWT's `aud` claim must match the Function App's identifier URI. Tokens scoped to other resources are rejected. |
| `token_store_enabled` | `false` | No token caching needed — each request is independently validated. |

EasyAuth runs as platform middleware — the function code never sees unauthenticated requests. The `active_directory_v2` block points at the app registration's client ID and the tenant's v2.0 auth endpoint.

### 1.5 APIM Policy — `authentication-managed-identity`

APIM's inbound policy (defined in `phase3/apim-config.tf`) performs two steps on every request before forwarding to the Function App backend:

1. **`validate-client-certificate`** — validates the client's mTLS certificate against the CA cert in Key Vault (trust, not-before, not-after; revocation check disabled).
2. **`authentication-managed-identity`** — acquires a token from Entra ID using APIM's system-assigned MI, scoped to the Function App's app registration identifier URI (e.g., `api://func-wkld-1-api-dev`). The token is then attached as an `Authorization: Bearer` header via `set-header`.

The `resource` attribute must match the `identifier_uri` of the Function App's app registration. Entra ID issues the token because APIM's service principal is implicitly authorized to request tokens for any app registration in the same tenant (no explicit API permission grant is needed for first-party MI token requests).

### 1.6 Health Endpoint — Authentication Exception

The `/api/health` endpoint is used by App Insights availability tests and APIM health probes. These callers do not carry Entra ID tokens.

**Decision:** Exclude `/api/health` from EasyAuth via `excluded_paths = ["/api/health"]` in the `auth_settings_v2` block. The endpoint returns no sensitive data, and network isolation (only APIM subnet can reach the PE) limits the blast radius.

In the APIM policy, the health operation can skip the `authentication-managed-identity` element by using a separate operation-level policy without the MI auth block.

---

## 2. Authentication Flow — End to End

```
1. External client presents client certificate (mTLS)
     │
2. APIM validates cert against CA in Key Vault (validate-client-certificate policy)
     │  ✗ Invalid cert → 403 Forbidden (APIM)
     │  ✓ Valid cert ↓
     │
3. APIM's MI requests token: POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
     scope = api://func-wkld-1-api-dev/.default
     client_assertion = MI federated credential
     │
4. APIM attaches token: Authorization: Bearer <jwt>
     │
5. APIM forwards request to Function App Private Endpoint
     │
6. Function App EasyAuth validates JWT:
     ├── Issuer matches Entra ID
     ├── Audience matches api://func-wkld-1-api-dev
     ├── Token is not expired
     └── Signature is valid (keys from Entra ID JWKS endpoint)
     │  ✗ Invalid token → 401 Unauthorized (EasyAuth, before function code)
     │  ✓ Valid token ↓
     │
7. Request reaches function code
     │
8. Function processes request, returns response through APIM to client
```

Three layers of defence:
1. **Network** — NSGs only allow APIM subnet → Function App PE subnet on port 443.
2. **mTLS** — Client must present a valid CA-signed certificate to APIM.
3. **Entra ID** — APIM must prove its identity to the Function App via a signed JWT.

---

## 3. Terraform Changes Required

| Module / Root | Change | Details |
|---------------|--------|---------|
| `modules/workload-stamp/variables.tf` | Add `entra_app_client_id` and `tenant_id` variables | Passed from the app registration created in the calling root. |
| `modules/workload-stamp/main.tf` | Add `auth_settings_v2` block to `azurerm_linux_function_app` | EasyAuth config as per Section 1.4. |
| `phase1/env/` (or `phase3/`) | Add `azuread_application` + `azuread_service_principal` | One per Function App per environment. |
| `phase1/env/workload.tf` | Pass `entra_app_client_id` to the stamp module | From the app registration output. |
| `phase3/apim-config.tf` | Add `<authentication-managed-identity>` to APIM policy | As per Section 1.5. Resource URI per stamp. |
| `phase1/env/main.tf` | Add `azuread` provider | Required for app registration resources. |

---

## 4. Why Not Function Keys?

Azure Functions support host-level and function-level access keys as a simpler authentication mechanism. APIM could send the key in the `x-functions-key` header. This was **rejected** for the following reasons:

| Concern | Function Keys | Managed Identity + EasyAuth |
|---------|--------------|----------------------------|
| **Secret management** | Key must be extracted from the Function App and stored in APIM (or Key Vault). It is a shared secret that can leak. | No shared secret. APIM obtains short-lived tokens from Entra ID using its MI. Nothing to store or rotate. |
| **Rotation** | Manual or scripted key rotation. If the key changes, APIM must be updated. | Tokens expire automatically (typically 1 hour). MI credentials are platform-managed. |
| **Auditability** | Any caller with the key is indistinguishable. | The JWT contains the caller's identity — Entra ID audit logs record every token issuance. |
| **Alignment with FR-9.1** | Violates "eliminate shared secrets between Azure resources". | Fully aligned — Managed Identity, no shared secrets. |
| **Defence in depth** | Single factor — possession of the key. | Identity-based — cryptographically verifiable, logged, and short-lived. |

Function keys are appropriate for low-security or dev-only scenarios. For this design, Managed Identity + EasyAuth is the correct choice and aligns with the stretch goal (FR-9.1 / NFR-1.7) that we are implementing as standard.
