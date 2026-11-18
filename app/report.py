from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PROMETHEUS_URL = os.getenv(
    "PROMETHEUS_URL",
    "http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090",
)

QUERIES = {
    "requests_24h": 'sum(increase(app_http_requests_total[24h]))',
    "p95_latency_seconds": (
        "histogram_quantile(0.95, "
        "sum by (le) (rate(app_http_request_duration_seconds_bucket[24h])))"
    ),
    "http_5xx_ratio": (
        "sum(rate(app_http_requests_total{status_code=~\"5..\"}[24h])) "
        "/ clamp_min(sum(rate(app_http_requests_total[24h])), 1e-12)"
    ),
    "cpu_cores": (
        'avg_over_time((sum(rate(container_cpu_usage_seconds_total{namespace="sample-app",'
        'pod=~"sample-web-.*",container="sample-web"}[5m])))[24h:5m])'
    ),
    "memory_bytes": (
        'avg_over_time((sum(container_memory_working_set_bytes{namespace="sample-app",'
        'pod=~"sample-web-.*",container="sample-web"}))[24h:5m])'
    ),
}


def query_prometheus(query: str) -> float | None:
    url = f"{PROMETHEUS_URL.rstrip('/')}/api/v1/query?{urllib.parse.urlencode({'query': query})}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Prometheus query failed: {exc}") from exc
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus returned an unsuccessful query: {payload}")
    results = payload.get("data", {}).get("result", [])
    if not results:
        return None
    try:
        return float(results[0]["value"][1])
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        raise RuntimeError("Prometheus returned an invalid result shape") from exc


def main() -> int:
    report = {name: query_prometheus(query) for name, query in QUERIES.items()}
    report["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
