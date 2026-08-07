"""
Minimal test suite — deliberately kept small. The point in an interview
context is showing that the CI pipeline's "test" stage has something real
to run, not building exhaustive coverage for a demo service.
"""
from main import app


def test_hello_returns_200():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.get_json()["message"].startswith("hello")


def test_health_returns_ok():
    client = app.test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_metrics_endpoint_exposes_prometheus_format():
    client = app.test_client()
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"app_requests_total" in resp.data
