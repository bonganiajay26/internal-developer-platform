# Decision: multi-stage build so the final image has no build toolchain,
# and a non-root user so a container breakout doesn't hand the attacker
# root on the node. Both are checked by the Trivy scan stage in CI —
# this Dockerfile is written to actually pass that gate, not just exist.

FROM python:3.12-slim AS builder
WORKDIR /build
COPY src/requirements.txt .
RUN pip install --no-cache-dir --target=/build/deps -r requirements.txt

FROM python:3.12-slim
RUN addgroup --system app && adduser --system --ingroup app app
WORKDIR /app
COPY --from=builder /build/deps /usr/local/lib/python3.12/site-packages
COPY src/main.py .
USER app
EXPOSE 8080
ENTRYPOINT ["python", "main.py"]
