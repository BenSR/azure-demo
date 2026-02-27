import json
from unittest.mock import MagicMock

import azure.functions as func
import pytest

from function_app import echo, health, EchoRequest


# ─── Helpers ──────────────────────────────────────────────────────────────────


def build_request(
    method: str = "POST",
    body: bytes | None = None,
    headers: dict | None = None,
    route: str = "echo",
) -> func.HttpRequest:
    """Build a mock HttpRequest for testing."""
    return func.HttpRequest(
        method=method,
        url=f"http://localhost:7071/api/{route}",
        headers=headers or {},
        body=body or b"",
    )


def parse_body(resp: func.HttpResponse) -> dict:
    return json.loads(resp.get_body().decode())


# ─── EchoRequest model tests ─────────────────────────────────────────────────


class TestEchoRequestModel:
    def test_valid_message(self):
        req = EchoRequest(message="hello")
        assert req.message == "hello"

    def test_empty_string_rejected(self):
        with pytest.raises(Exception):
            EchoRequest(message="")

    def test_whitespace_only_rejected(self):
        with pytest.raises(Exception):
            EchoRequest(message="   ")

    def test_null_message_rejected(self):
        with pytest.raises(Exception):
            EchoRequest(message=None)

    def test_integer_message_rejected(self):
        with pytest.raises(Exception):
            EchoRequest(message=123)

    def test_extra_fields_ignored(self):
        req = EchoRequest(message="hello", extra="ignored")
        assert req.message == "hello"
        assert not hasattr(req, "extra")


# ─── POST /api/echo tests ────────────────────────────────────────────────────


class TestEchoEndpoint:
    def test_happy_path(self):
        body = json.dumps({"message": "Hello, world!"}).encode()
        req = build_request(body=body)
        resp = echo(req)

        assert resp.status_code == 200
        data = parse_body(resp)
        assert data["message"] == "Hello, world!"
        assert "timestamp" in data
        assert "request_id" in data

    def test_malformed_json(self):
        req = build_request(body=b"not json")
        resp = echo(req)

        assert resp.status_code == 400
        data = parse_body(resp)
        assert data["error"]["code"] == "MALFORMED_JSON"
        assert "request_id" in data["error"]

    def test_empty_body(self):
        req = build_request(body=b"")
        resp = echo(req)

        assert resp.status_code == 400
        data = parse_body(resp)
        assert data["error"]["code"] == "MALFORMED_JSON"

    def test_missing_message_key(self):
        body = json.dumps({"not_message": "oops"}).encode()
        req = build_request(body=body)
        resp = echo(req)

        assert resp.status_code == 400
        data = parse_body(resp)
        assert data["error"]["code"] == "INVALID_REQUEST"

    def test_null_message(self):
        body = json.dumps({"message": None}).encode()
        req = build_request(body=body)
        resp = echo(req)

        assert resp.status_code == 400
        data = parse_body(resp)
        assert data["error"]["code"] == "INVALID_REQUEST"

    def test_empty_message(self):
        body = json.dumps({"message": ""}).encode()
        req = build_request(body=body)
        resp = echo(req)

        assert resp.status_code == 400
        data = parse_body(resp)
        assert data["error"]["code"] == "INVALID_REQUEST"

    def test_whitespace_message(self):
        body = json.dumps({"message": "   "}).encode()
        req = build_request(body=body)
        resp = echo(req)

        assert resp.status_code == 400
        data = parse_body(resp)
        assert data["error"]["code"] == "INVALID_REQUEST"

    def test_integer_message(self):
        body = json.dumps({"message": 42}).encode()
        req = build_request(body=body)
        resp = echo(req)

        assert resp.status_code == 400
        data = parse_body(resp)
        assert data["error"]["code"] == "INVALID_REQUEST"

    def test_array_message(self):
        body = json.dumps({"message": ["a", "b"]}).encode()
        req = build_request(body=body)
        resp = echo(req)

        assert resp.status_code == 400
        data = parse_body(resp)
        assert data["error"]["code"] == "INVALID_REQUEST"

    def test_extra_fields_ignored(self):
        body = json.dumps({"message": "hello", "extra": "stuff"}).encode()
        req = build_request(body=body)
        resp = echo(req)

        assert resp.status_code == 200
        data = parse_body(resp)
        assert data["message"] == "hello"
        assert "extra" not in data

    def test_request_id_from_azure_header(self):
        body = json.dumps({"message": "hi"}).encode()
        req = build_request(body=body, headers={"x-ms-request-id": "azure-123"})
        resp = echo(req)

        data = parse_body(resp)
        assert data["request_id"] == "azure-123"

    def test_request_id_from_apim_header(self):
        body = json.dumps({"message": "hi"}).encode()
        req = build_request(body=body, headers={"x-request-id": "apim-456"})
        resp = echo(req)

        data = parse_body(resp)
        assert data["request_id"] == "apim-456"

    def test_request_id_azure_takes_precedence(self):
        body = json.dumps({"message": "hi"}).encode()
        req = build_request(
            body=body,
            headers={"x-ms-request-id": "azure-123", "x-request-id": "apim-456"},
        )
        resp = echo(req)

        data = parse_body(resp)
        assert data["request_id"] == "azure-123"

    def test_request_id_generated_when_no_headers(self):
        body = json.dumps({"message": "hi"}).encode()
        req = build_request(body=body)
        resp = echo(req)

        data = parse_body(resp)
        # Should be a valid UUID4
        assert len(data["request_id"]) == 36


# ─── GET /api/health tests ───────────────────────────────────────────────────


class TestHealthEndpoint:
    def test_healthy_response(self):
        req = build_request(method="GET", route="health")
        resp = health(req)

        assert resp.status_code == 200
        data = parse_body(resp)
        assert data["status"] == "healthy"
        assert "timestamp" in data

    def test_response_is_json(self):
        req = build_request(method="GET", route="health")
        resp = health(req)

        assert resp.mimetype == "application/json"
