import json
import logging
import os
import uuid
from datetime import datetime, timezone

import azure.functions as func
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from opentelemetry.trace import StatusCode
from pydantic import BaseModel, field_validator

# Configure Azure Monitor when running in Azure (not during unit tests).
if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    configure_azure_monitor()

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
logger = logging.getLogger(__name__)


# ─── Exceptions ───────────────────────────────────────────────────────────────


class DeliberateServerError(RuntimeError):
    """Raised intentionally to generate App Insights failure and exception telemetry."""


# ─── Models ───────────────────────────────────────────────────────────────────


class EchoRequest(BaseModel):
    message: str
    trip_server_side_error: bool = False

    @field_validator("message")
    @classmethod
    def must_be_non_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("must be a non-empty string")
        return v


# ─── Helpers ──────────────────────────────────────────────────────────────────


def get_request_id(req: func.HttpRequest) -> str:
    """Extract request ID from Azure/APIM headers, or generate a UUID4."""
    return (
        req.headers.get("x-ms-request-id")
        or req.headers.get("x-request-id")
        or str(uuid.uuid4())
    )


def error_response(
    status_code: int, code: str, message: str, request_id: str
) -> func.HttpResponse:
    """Build a structured JSON error response."""
    return func.HttpResponse(
        body=json.dumps(
            {
                "error": {
                    "code": code,
                    "message": message,
                    "request_id": request_id,
                }
            }
        ),
        status_code=status_code,
        mimetype="application/json",
    )


# ─── Triggers ─────────────────────────────────────────────────────────────────


@app.route(route="message", methods=["POST"])
def message(req: func.HttpRequest) -> func.HttpResponse:
    """POST /api/message — validates payload and returns message with metadata."""
    request_id = get_request_id(req)
    logger.info("message request %s", request_id)

    try:
        body = req.get_json()
    except ValueError:
        return error_response(
            400, "MALFORMED_JSON", "Request body is not valid JSON.", request_id
        )

    try:
        payload = EchoRequest(**body)
    except Exception:
        return error_response(
            400,
            "INVALID_REQUEST",
            "Field 'message' is required and must be a non-empty string.",
            request_id,
        )

    # Deliberate 500 facility — raises a real exception so App Insights records
    # a failure (success=false) and exception telemetry, while still returning
    # a structured JSON response so callers see a consistent error envelope.
    if payload.trip_server_side_error:
        try:
            raise DeliberateServerError(
                "Server-side error deliberately triggered via trip_server_side_error flag."
            )
        except DeliberateServerError as exc:
            span = trace.get_current_span()
            span.record_exception(exc)
            span.set_status(StatusCode.ERROR, "DELIBERATE_ERROR")
            logger.exception("Deliberate server-side error for request %s", request_id)
            return error_response(500, "DELIBERATE_ERROR", str(exc), request_id)

    try:
        return func.HttpResponse(
            body=json.dumps(
                {
                    "message": payload.message,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "request_id": request_id,
                }
            ),
            status_code=200,
            mimetype="application/json",
        )
    except Exception:
        logger.exception("Unhandled exception for request %s", request_id)
        return error_response(
            500, "INTERNAL_ERROR", "An unexpected error occurred.", request_id
        )


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    """GET /api/health — returns status for availability probes."""
    return func.HttpResponse(
        body=json.dumps(
            {
                "status": "healthy",
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
        ),
        status_code=200,
        mimetype="application/json",
    )
