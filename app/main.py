from __future__ import annotations

import time
from collections.abc import Callable

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

app = FastAPI(title="AKS Sample Service", version="1.0.0")

REQUESTS = Counter(
    "app_http_requests_total",
    "HTTP requests served by the sample application.",
    ("method", "path", "status_code"),
)
LATENCY = Histogram(
    "app_http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ("method", "path"),
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
IN_PROGRESS = Gauge("app_http_requests_in_progress", "HTTP requests currently being served.")


@app.middleware("http")
async def instrument_requests(request: Request, call_next: Callable) -> Response:
    if request.url.path == "/metrics":
        return await call_next(request)
    started = time.perf_counter()
    IN_PROGRESS.inc()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        elapsed = time.perf_counter() - started
        REQUESTS.labels(request.method, request.url.path, str(status_code)).inc()
        LATENCY.labels(request.method, request.url.path).observe(elapsed)
        IN_PROGRESS.dec()


@app.get("/")
async def index() -> dict[str, str]:
    return {"service": "aks-sample-service", "status": "ok"}


@app.get("/work")
async def work() -> dict[str, str]:
    return {"result": "sample work completed"}


@app.get("/healthz")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
async def ready() -> dict[str, str]:
    return {"status": "ready"}


@app.get("/metrics", include_in_schema=False)
async def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
