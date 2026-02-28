# Application Planning — Azure Function App (Containerised)

Design and implementation plan for the Python Azure Function App, packaged as a Docker container, deployed to the infrastructure defined in Phase 1.

> See [2_apim_planning.md](2_apim_planning.md) for APIM configuration, mTLS, and APIM → Function App authentication.

---

## 1. Overview

The application is a Python HTTP-triggered Azure Function App that:

1. Accepts HTTP POST requests with a JSON payload containing a `message` field.
2. Validates the payload, rejecting invalid requests with structured error responses.
3. Returns a JSON response with the original `message`, a `timestamp`, and the `request_id`.
4. Exposes a health-check endpoint for availability monitoring.
5. Emits telemetry to Application Insights.

The Function App is packaged as a Docker container, pushed to ACR (`acrcore`), and pulled by the Function App's system-assigned Managed Identity at startup.

---

## 2. Technology Choices

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Language** | Python 3.11 | Constraint TC-6 allows any language. Python is well-supported for Azure Functions, has a mature v2 programming model, and keeps the codebase lightweight. |
| **Programming model** | Azure Functions Python v2 (decorator-based) | Cleaner than v1 `function.json` model — routes, bindings, and triggers are defined inline with decorators. Single `function_app.py` entry point. |
| **Runtime version** | Azure Functions v4 (`FUNCTIONS_EXTENSION_VERSION=~4`) | Current LTS runtime. Already set in the Terraform `app_settings`. |
| **Containerisation** | Docker (multi-stage build) | Required by design — ACR hosts the image, Function App pulls via Managed Identity. Multi-stage build keeps the final image small. |
| **Base image** | `mcr.microsoft.com/azure-functions/python:4-python3.11` | Official Microsoft image with Functions runtime pre-installed. Ensures compatibility with the hosting platform. |
| **HTTP framework** | Built-in Azure Functions HTTP trigger | No need for Flask/FastAPI — the Functions runtime handles HTTP routing natively. |
| **Observability** | Native App Insights integration | The Function App's `site_config` already wires `application_insights_connection_string` and the agent extension. No additional SDK needed. |

---

## 3. Project Structure

This is a tiny app — two HTTP endpoints, basic validation, structured error responses. A single `function_app.py` keeps things simple. No need for a multi-package layout.

```
app/
├── Dockerfile
├── .dockerignore
├── host.json
├── requirements.txt
├── function_app.py          # All code — triggers, validation, error handling
└── tests/
    ├── __init__.py
    └── test_function_app.py
```

### File Responsibilities

| File | Purpose |
|------|---------|
| `function_app.py` | Everything — Pydantic models, validation, error helpers, the `echo` and `health` HTTP triggers. ~150 lines. |
| `host.json` | Functions runtime configuration — logging, route prefix, timeout. |
| `requirements.txt` | `azure-functions` + `pydantic`. |
| `tests/test_function_app.py` | Unit tests using `pytest`. Mock `func.HttpRequest` objects to test validation, happy path, and error cases. |

---

## 4. API Design

### 4.1 POST `/api/echo`

The primary endpoint. Satisfies FR-2.2 through FR-2.5.

**Request:**

```json
POST /api/echo
Content-Type: application/json

{
  "message": "Hello, world!"
}
```

**Success Response (200):**

```json
{
  "message": "Hello, world!",
  "timestamp": "2026-02-27T14:30:00.000000Z",
  "request_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

**Validation Error (400) — missing or invalid `message`:**

```json
{
  "error": {
    "code": "INVALID_REQUEST",
    "message": "Field 'message' is required and must be a non-empty string.",
    "request_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  }
}
```

**Malformed JSON (400):**

```json
{
  "error": {
    "code": "MALFORMED_JSON",
    "message": "Request body is not valid JSON.",
    "request_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  }
}
```

**Unexpected Error (500):**

```json
{
  "error": {
    "code": "INTERNAL_ERROR",
    "message": "An unexpected error occurred.",
    "request_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  }
}
```

### 4.2 GET `/api/health`

Health-check endpoint for App Insights availability tests and APIM health probes. Satisfies FR-7.1.

**Response (200):**

```json
{
  "status": "healthy",
  "timestamp": "2026-02-27T14:30:00.000000Z"
}
```

No authentication required on the health endpoint — it returns no sensitive data and is used for infrastructure probing (excluded from EasyAuth — see [2_apim_planning.md](2_apim_planning.md)).

---

## 5. Application Design

The single `function_app.py` file contains four logical sections:

1. **Pydantic model** — `EchoRequest` with a `message: str` field and a validator that rejects empty/whitespace-only strings.
2. **Request ID helper** — Extracts a request ID from `x-ms-request-id` (Azure), falls back to `x-request-id` (APIM correlation), or generates a UUID4.
3. **Error response helper** — Builds structured JSON error bodies (code, message, request_id) for any error case.
4. **Two HTTP triggers** — `echo` (POST) and `health` (GET), registered via `@app.route` decorators.

### Validation Edge Cases

| Input | Response |
|-------|----------|
| Empty body | 400 `MALFORMED_JSON` |
| Valid JSON, missing `message` key | 400 `INVALID_REQUEST` |
| `message` is null, empty, or whitespace-only | 400 `INVALID_REQUEST` |
| `message` is wrong type (int, array, etc.) | 400 `INVALID_REQUEST` |
| Extra fields | Silently ignored (Pydantic default) |
| Unhandled exception | 500 `INTERNAL_ERROR` |

### Error Handling

All errors return structured JSON — no plain-text bodies, no stack traces in responses. A top-level try/except wraps each trigger so that unhandled exceptions produce a generic 500 with the request ID for correlation.

### Request ID Strategy

| Source | Header | Behaviour |
|--------|--------|-----------|
| Azure infrastructure | `x-ms-request-id` | Primary — populated by the Functions runtime. |
| APIM | `x-request-id` | Fallback — APIM correlation ID. |
| Neither present | — | Generate a UUID4. |

---

## 6. Observability

### Structured Logging

All log entries include the `request_id` for correlation. Python's built-in `logging` module ships logs to App Insights automatically via the connection string in `app_settings`.

### App Insights Telemetry

The Terraform infrastructure already configures:
- `APPLICATIONINSIGHTS_CONNECTION_STRING` — auto-collected telemetry (requests, dependencies, exceptions).
- `ApplicationInsightsAgent_EXTENSION_VERSION = "~3"` — enables the App Insights agent for deeper telemetry.

No additional SDK or packages needed. Native telemetry covers requests, exceptions, and dependency tracking out of the box.

### Audit Logging (FR-5.4)

Every API request is logged with the request ID. App Insights auto-collects HTTP method, path, status code, and duration for every request. Requests are excluded from sampling in `host.json` so every call is captured.

---

## 7. Docker Container

### Dockerfile Approach

Multi-stage build using the official `mcr.microsoft.com/azure-functions/python:4-python3.11` base image:

- **Build stage** — installs Python dependencies from `requirements.txt` into the Functions package path.
- **Runtime stage** — copies installed packages and application code into `/home/site/wwwroot`. Sets `AzureWebJobsScriptRoot` and enables console logging.

The same base image is used for both stages to ensure runtime compatibility.

### Dependencies

Only two packages beyond the standard library:

- `azure-functions` (≥1.17.0) — Functions SDK and HTTP trigger bindings.
- `pydantic` (≥2.0, <3.0) — Request validation.

### `host.json` Key Settings

| Setting | Value | Rationale |
|---------|-------|----------|
| Sampling | Enabled, but `Request` type excluded | Every request captured for audit (NFR-2.1). |
| Log level | `Information` | Sufficient for this app. |
| Route prefix | `api` | Endpoints at `/api/echo` and `/api/health`. |
| Function timeout | 5 minutes | Generous for an echo function; prevents runaway executions. |

### `.dockerignore`

Excludes `tests/`, `__pycache__/`, `.pytest_cache/`, `*.pyc`, and `.git/` from the container image.

---

## 8. Build & Deployment Pipeline

### 8.1 Build Flow

The container image is built and pushed to ACR by the GitHub Actions CI/CD pipeline. This happens from the **VNet-injected runner** because ACR has `public_network_access_enabled = false`.

1. Developer pushes to `dev` → GitHub Actions on VNet runner → build and push `acrcore.azurecr.io/wkld-api:dev`.
2. PR merged to `main` → GitHub Actions on VNet runner → build and push `acrcore.azurecr.io/wkld-api:latest`.

All builds run on the VNet-injected runner (`snet-runner`) because ACR has `public_network_access_enabled = false`.

### 8.2 Image Tagging Strategy

Images are tagged by branch — no SHA-pinned or semver tags for this demo.

| Tag | Branch | Environment | Purpose |
|-----|--------|-------------|---------|
| `dev` | `dev` | Dev | Every push to `dev` rebuilds and pushes `wkld-api:dev`. Dev Function App stamps are configured with `image_tag = "dev"`. |
| `latest` | `main` | Prod | Every merge to `main` rebuilds and pushes `wkld-api:latest`. Prod Function App stamps are configured with `image_tag = "latest"`. |

> **Test environment** is unused for this demo. If needed later, a `test` tag following the same pattern can be added.

The Terraform `stamps` variable in `dev.tfvars` / `prod.tfvars` specifies the `image_tag` per stamp — `"dev"` for dev stamps, `"latest"` for prod stamps.

### 8.3 Deployment Flow

Since the `image_tag` is fixed per environment (`dev` or `latest`) and does not change between deploys, the Function App just needs to pull the updated image behind the same tag:

1. **CI pushes the image** — The pipeline builds and pushes `wkld-api:dev` (on dev branch) or `wkld-api:latest` (on main).
2. **Restart the Function App** — `az functionapp restart` triggers a fresh image pull. The tag in Terraform doesn't change, so no `terraform apply` is needed for routine deployments.

Promotion from dev to prod is *merging the PR to main* — the main-branch pipeline builds and pushes `:latest`, then restarts the prod Function App.

---

## 9. Local Development

- **Run locally** — `func start` from the `app/` directory serves both endpoints on `http://localhost:7071`. No Docker required for local dev.
- **Tests** — `pytest` with `pytest-cov` for coverage. Target ≥90% coverage on `function_app.py`.
- **Container locally** — `docker build` + `docker run` on port 8080 with `AzureWebJobsStorage=UseDevelopmentStorage=true` for local validation of the container image.

---

## 10. Security Considerations

| Concern | Mitigation |
|---------|------------|
| **No public access** | `public_network_access_enabled = false` on the Function App. Only reachable via its Private Endpoint in `snet-stamp-<env>-<N>-pe`. |
| **APIM → Function App auth** | APIM authenticates via Managed Identity + Entra ID tokens. Function App validates via EasyAuth. No shared secrets. See [2_apim_planning.md](2_apim_planning.md). |
| **mTLS enforcement** | Handled at the APIM layer. APIM policy validates client certs against the CA in Key Vault. |
| **No secrets in code** | All secrets and certificates live in Key Vault. Function App accesses them via Managed Identity. |
| **Managed Identity auth** | Function App uses its system-assigned MI for ACR pull, Storage access, and Key Vault reads. No connection strings or account keys. |
| **Input validation** | Pydantic enforces strict schema validation. No raw user input is reflected without sanitisation. |
| **Error responses** | No stack traces, internal paths, or implementation details in error bodies. |

---

## 11. Function App Configuration (Terraform ↔ App)

Settings already configured by the `workload-stamp` module in Terraform:

| Setting | Value | Source |
|---------|-------|--------|
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | App Insights connection string | `azurerm_application_insights.this.connection_string` |
| `ApplicationInsightsAgent_EXTENSION_VERSION` | `~3` | Hardcoded in module |
| `FUNCTIONS_EXTENSION_VERSION` | `~4` | Hardcoded in module |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | `false` | Hardcoded in module |
| `DOCKER_REGISTRY_SERVER_URL` | ACR login server | Via `container_registry_use_managed_identity` |

Additional settings that may be needed (passed via `function_apps[].app_settings`):

| Setting | Purpose |
|---------|---------|
| `SCM_DO_BUILD_DURING_DEPLOYMENT` | Set to `false` — build happens in Docker, not on the platform. |

---

## 12. Implementation Plan

| Step | Task | Acceptance Criteria |
|------|------|-------------------|
| 1 | Create `app/` directory, `requirements.txt`, `host.json` | Files match Section 7. |
| 2 | Implement `function_app.py` | Both endpoints work: POST `/api/echo` + GET `/api/health`. All validation edge cases handled. |
| 3 | Write unit tests (`tests/test_function_app.py`) | All edge cases covered. ≥90% coverage. |
| 4 | Create `Dockerfile` + `.dockerignore` | Multi-stage build. Image builds and runs correctly. |
| 5 | Add CI job: lint + test | `pytest` with coverage gate. |
| 6 | Add CI job: Docker build + push | Tags with `dev` (dev branch) or `latest` (main branch), pushes to ACR. Runs on VNet runner. |
| 7 | Add deployment step | `az functionapp restart` on the target environment's Function App(s). |

---

## 13. Requirements Traceability

| Requirement | Implementation |
|-------------|---------------|
| FR-2.1 — Deploy Azure Function App | Terraform `workload-stamp` module + Docker container in ACR. |
| FR-2.2 — Accept HTTP POST with `message` | POST `/api/echo` endpoint with Pydantic validation. |
| FR-2.3 — Validate payload, reject invalid | Pydantic `EchoRequest` model — 400 responses with structured error bodies. |
| FR-2.4 — Return message + timestamp + request_id | Echo response in `function_app.py`. |
| FR-2.5 — Graceful error handling | Try/except wrapper, structured error responses for all cases. |
| FR-2.6 — VNet integration | Terraform `virtual_network_subnet_id` on Function App. |
| FR-5.1 — App Insights telemetry | `APPLICATIONINSIGHTS_CONNECTION_STRING` + agent extension. |
| FR-5.4 — Audit logging | Structured logging with request_id. Requests excluded from sampling. |
| FR-7.1 — Health monitoring | GET `/api/health` endpoint. |
| NFR-1.3 — No secrets in code | Managed Identity for all service auth. No connection strings. |
| FR-9.1 / NFR-1.7 — Managed Identities for service-to-service | See [2_apim_planning.md](2_apim_planning.md). |
| NFR-2.1 — Log all API requests | App Insights auto-collection (requests excluded from sampling). |
