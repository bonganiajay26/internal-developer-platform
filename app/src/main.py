"""
Sample microservice for the Internal Developer Platform demo.

Decision: Flask + prometheus_client instead of a heavier framework.
The point of this service is to be a believable "golden path" example
any team could copy — it deliberately does the minimum: a business
endpoint, a /health endpoint for the Kubernetes liveness/readiness probes,
and a /metrics endpoint that Prometheus scrapes via a ServiceMonitor.
"""
from flask import Flask, jsonify
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST
import time
import os

app = Flask(__name__)

REQUEST_COUNT = Counter(
    "app_requests_total", "Total requests received", ["endpoint", "status"]
)

START_TIME = time.time()
VERSION = os.environ.get("APP_VERSION", "dev")


@app.route("/")
def hello():
    REQUEST_COUNT.labels(endpoint="/", status="200").inc()
    return jsonify(
        {
            "message": "hello from the internal developer platform",
            "version": VERSION,
        }
    )


@app.route("/health")
def health():
    # Decision: a real health check, not just "return 200". It reports
    # uptime so a flapping pod (crash-looping and restarting under 30s)
    # is visible in the response body during manual debugging, on top of
    # what Kubernetes already sees from the probe's HTTP status code alone.
    REQUEST_COUNT.labels(endpoint="/health", status="200").inc()
    return jsonify({"status": "ok", "uptime_seconds": round(time.time() - START_TIME, 1)})


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
