# Application Planning — Azure Function App (Containerised)

Design and implementation of the Python Azure Function App.

---

## 1. Overview

A Python HTTP-triggered Azure Function App that:
1. Accepts POST requests with a JSON `message` field
2. Validates input via Pydantic, returns structured errors
3. Returns the message, a UTC timestamp, and a request ID
4. Exposes a health endpoint for availability probes
5. Emits telemetry to Application Insights via OpenTelemetry

Packaged as a Docker container, pushed to ACR, pulled by the Function App's Managed Identity.

---

## 2. Technology Choices

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language | Python 3.11 | Mature Azure Functions v2 support, lightweight |
| Programming model | v2 (decorator-based) | Routes and triggers inline — single file entry point |
| Runtime | Functions v4 | Current LTS |
| Containerisation | Docker multi-stage build | ACR hosts the image; multi-stage keeps it small |
| Base image | `mcr.microsoft.com/azure-functions/python:4-python3.11` | Official MS image with runtime pre-installed |
| Observability | `azure-monitor-opentelemetry` | OpenTelemetry-based, integrates with App Insights connection string |

---

## 3. Project Structure

```
function_app/
├── Dockerfile           # Multi-stage build
├── host.json            # Runtime config (logging, route prefix, timeout)
├── requirements.txt     # azure-functions, pydantic, azure-monitor-opentelemetry
├── function_app.py      # All code — models, validation, triggers (~130 lines)
└── tests/
    ├── __init__.py
    └── test_function_app.py  # pytest unit tests, ~26 test functions
```

---

## 4. API Design

### POST `/api/message`

```json
// Request
{ "message": "Hello, world!" }

// Success (200)
{ "message": "Hello, world!", "timestamp": "2026-02-27T14:30:00Z", "request_id": "a1b2c3d4-..." }

// Validation error (400)
{ "error": { "code": "INVALID_REQUEST", "message": "Field 'message' is required...", "request_id": "..." } }

// Malformed JSON (400)
{ "error": { "code": "MALFORMED_JSON", "message": "Request body is not valid JSON.", "request_id": "..." } }

// Deliberate 500 (trip_server_side_error: true)
{ "error": { "code": "DELIBERATE_ERROR", "message": "Server-side error deliberately triggered...", "request_id": "..." } }
```

### GET `/api/health`

```json
{ "status": "healthy", "timestamp": "2026-02-27T14:30:00Z" }
```

No authentication required — returns no sensitive data, excluded from EasyAuth.

---

## 5. Application Design

Four sections in `function_app.py`:

1. **Pydantic model** (`EchoRequest`) — validates `message: str` (rejects empty/whitespace), optional `trip_server_side_error: bool = False`
2. **Request ID helper** — extracts from `x-ms-request-id` (Azure), `x-request-id` (APIM), or generates UUID4
3. **Error response helper** — structured JSON `{error: {code, message, request_id}}`
4. **Two HTTP triggers** — `message` (POST) and `health` (GET), both `ANONYMOUS` auth level (EasyAuth handles auth)

### Deliberate Error Facility

When `trip_server_side_error: true`, the function raises a `DeliberateServerError`, records it on the OpenTelemetry span (so App Insights sees a failure + exception), and returns a structured 500. This exists for testing alert rules.

### Validation Edge Cases

| Input | Response |
|-------|----------|
| Empty body | 400 `MALFORMED_JSON` |
| Missing `message` key | 400 `INVALID_REQUEST` |
| Null / empty / whitespace `message` | 400 `INVALID_REQUEST` |
| Wrong type (int, array) | 400 `INVALID_REQUEST` |
| `trip_server_side_error: true` | 500 `DELIBERATE_ERROR` |
| Extra fields | Silently ignored |
| Unhandled exception | 500 `INTERNAL_ERROR` |

All errors return structured JSON — no stack traces, no plain-text bodies.

---

## 6. Observability

- **OpenTelemetry** — `azure-monitor-opentelemetry` configured at startup when `APPLICATIONINSIGHTS_CONNECTION_STRING` is present. Auto-collects requests, dependencies, exceptions.
- **Structured logging** — all entries include `request_id` for correlation.
- **Sampling** — enabled in `host.json` but `Request` type excluded so every API call is captured for audit.
- **`host.json`** — log level `Information`, route prefix `api`, function timeout 5 minutes.

---

## 7. Docker Container

Multi-stage build on the official Functions Python 3.11 base image. Build stage installs dependencies; runtime stage copies packages + app code.

Dependencies: `azure-functions` (≥1.17.0), `pydantic` (≥2.0, <3.0), `azure-monitor-opentelemetry` (≥1.6.0).

---

## 8. Build & Deployment

### Image Tagging

| Tag | Branch | Environment |
|-----|--------|-------------|
| `dev` | `dev` | Dev stamps |
| `latest` | `main` | Prod stamps |

Tags are branch-based — no semver for this demo. The `image_tag` per stamp is fixed in its `.tfvars` file.

### Deployment Flow

1. CI builds and pushes the tagged image to ACR (via VNet runner — ACR has no public access)
2. Pipeline invokes the Kudu deployment webhook from each stamp's Key Vault
3. Function App pulls the updated image behind the same tag — no `terraform apply` needed

The webhook URL is stored as `deploy-webhook-url` in each stamp's Key Vault, written there by Phase 2 Terraform.

---

## 9. Security

| Concern | Mitigation |
|---------|------------|
| No public access | `public_network_access_enabled = false`. Only reachable via PE. |
| Auth | APIM → MI token → EasyAuth validates JWT. No shared secrets. |
| mTLS | Terminated at App GW (and optionally validated at APIM). |
| Secrets | All in Key Vault. Function App accesses via MI. |
| Input validation | Pydantic enforces strict schema. No raw input reflection. |
| Error responses | No stack traces or internal paths exposed. |
