import json

from fastapi.testclient import TestClient

from main import app
import report


def test_health_and_sample_endpoint() -> None:
    client = TestClient(app)
    assert client.get("/healthz").json() == {"status": "ok"}
    assert client.get("/work").json() == {"result": "sample work completed"}


def test_metrics_export_contains_application_counters() -> None:
    client = TestClient(app)
    client.get("/")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "app_http_requests_total" in response.text


def test_daily_report_queries_all_required_metrics(monkeypatch, capsys) -> None:
    queried: list[str] = []

    def fake_query(query: str) -> float:
        queried.append(query)
        return 1.0

    monkeypatch.setattr(report, "query_prometheus", fake_query)
    assert report.main() == 0

    output = capsys.readouterr().out
    assert all(metric in output for metric in report.QUERIES)
    assert len(queried) == 5
    assert 'namespace="sample-app"' in report.QUERIES["cpu_cores"]
    assert 'namespace="sample-app"' in report.QUERIES["memory_bytes"]
    assert "generated_at_utc" in json.loads(output)
