# APIM Planning — API Layer & Authentication

APIM configuration, mTLS termination, and the APIM → Function App authentication model.

---

## 1. Authentication Model

The Function App has public access disabled and is only reachable via its Private Endpoint. Network isolation (NSG rules) provides the first layer, but defence in depth requires identity-based authentication on top.

### Flow

```
Client ──mTLS──► App GW ──mTLS──► APIM ──MI token──► Function App PE
                                    │                       │
                                    │ 1. Policy acquires    │ 3. EasyAuth validates JWT:
                                    │    MI token for the   │    - issuer = Entra ID
                                    │    Function App's     │    - audience = app registration
                                    │    app registration   │    - token not expired
                                    │                       │
                                    │ 2. Attaches Bearer    │ 4. Valid → function code runs
                                    │    header             │    Invalid → 401 before code
```

### Components

| Component | Purpose | Where |
|-----------|---------|-------|
| **Entra ID App Registration** | Token audience for the Function App. One per stamp per env. No client secret — it only receives tokens. | `phase1/env/entra.tf` |
| **EasyAuth v2** | Built-in auth middleware on Function App. Validates Entra ID tokens, rejects unauthenticated requests with 401. | `modules/workload-stamp/main.tf` (auth_settings_v2) |
| **APIM System-Assigned MI** | Requests tokens scoped to the Function App's app registration. | `phase1/env/apim.tf` |
| **APIM Inbound Policy** | `<authentication-managed-identity>` acquires and attaches the Bearer token per request. | `phase2/env/apim-config.tf` |

### EasyAuth Configuration

| Setting | Value | Effect |
|---------|-------|--------|
| `require_authentication` | `true` | Every request must carry a valid token |
| `unauthenticated_action` | `Return401` | No redirect — immediate 401 |
| `allowed_audiences` | `api://<tenant>/func-wkld-<N>-api-<env>` | JWT `aud` must match |
| `excluded_paths` | `/api/health` | Health probes bypass auth |
| `token_store_enabled` | `false` | Each request independently validated |

### Health Endpoint Exception

`/api/health` is excluded from EasyAuth — it returns no sensitive data and is used by App Insights probes and APIM health checks. In the APIM policy, the health operation has a separate policy that **omits `<base />`** in the inbound section, bypassing mTLS and MI auth entirely. Health probes always target the primary stamp.

---

## 2. APIM Policy Design

The API-level policy in `phase2/env/apim-config.tf` performs two steps on every request:

1. **Load-balance across stamps** — `set-variable` with `Random.Next(N)` selects a stamp index. A `choose/when` block per stamp acquires the MI token scoped to that stamp's app registration and routes to that stamp's backend.

2. **Client certificate validation** — `<validate-client-certificate>` matches the CA thumbprint stored as a Named Value. For the assessment (self-signed CA): `validate-trust="false"`, `validate-revocation="false"`. `validate-not-before` and `validate-not-after` are `true`.

> When the Application Gateway is in the path, mTLS is already terminated at that layer. The APIM policy provides a second validation layer (useful for internal jumpbox testing where App GW is bypassed).

---

## 3. End-to-End Auth Flow

```
1. Client presents client certificate
   │
2. App GW validates cert against CA (SSL profile mTLS)
   │  ✗ → 403
   │  ✓ ↓
3. App GW forwards to APIM backend (URL rewrite strips /api/<env>/)
   │
4. APIM policy validates cert thumbprint (Named Value)
   │  ✗ → 403
   │  ✓ ↓
5. APIM MI requests Entra ID token for Function App's app registration
   │
6. APIM attaches Bearer token, forwards to Function App PE
   │
7. EasyAuth validates JWT (issuer, audience, expiry, signature)
   │  ✗ → 401
   │  ✓ ↓
8. Request reaches function code → response flows back
```

Four layers of defence:
1. **Network** — NSGs restrict Function App PE to APIM subnet traffic only
2. **App GW mTLS** — client must present a valid CA-signed certificate
3. **APIM cert validation** — thumbprint check (defence in depth)
4. **Entra ID** — APIM proves its identity via a signed, short-lived JWT

---

## 4. Why Not Function Keys?

| Concern | Function Keys | Managed Identity + EasyAuth |
|---------|--------------|----------------------------|
| Secret management | Shared secret that can leak | No shared secrets — short-lived MI tokens |
| Rotation | Manual | Automatic token expiry (~1 hour) |
| Auditability | Any caller with the key is indistinguishable | JWT contains caller identity; Entra ID logs every issuance |
| Alignment with FR-9.1 | Violates "no shared secrets" | Fully aligned |
| Defence in depth | Single factor (key possession) | Cryptographically verifiable, logged, short-lived |
