"""${{ values.description }}

Generated from the golden-path-microservice template.
Owner: ${{ values.owner }}
"""
from flask import Flask, jsonify
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST
import time

app = Flask(__name__)
REQUEST_COUNT = Counter("app_requests_total", "Total requests received", ["endpoint", "status"])
START_TIME = time.time()


@app.route("/")
def hello():
    REQUEST_COUNT.labels(endpoint="/", status="200").inc()
    return jsonify({"service": "${{ values.serviceName }}"})


@app.route("/health")
def health():
    REQUEST_COUNT.labels(endpoint="/health", status="200").inc()
    return jsonify({"status": "ok", "uptime_seconds": round(time.time() - START_TIME, 1)})


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
