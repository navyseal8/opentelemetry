#!/usr/bin/env bash
###############################################################################
# generate-logs.sh — Continuously generates realistic demo logs with PII
#
# Appends to:
#   /var/log/demo/app.log        (plain text — consumed by filelogreceiver)
#   /var/log/demo/otlp-logs.jsonl (OTLP JSON — consumed by otlpjsonfilereceiver)
#
# Run this inside the log-generator container to simulate live traffic.
###############################################################################
set -eo pipefail

LOG_DIR="${LOG_DIR:-/var/log/demo}"
APP_LOG="$LOG_DIR/app.log"
OTLP_LOG="$LOG_DIR/otlp-logs.jsonl"
INTERVAL="${INTERVAL:-3}"

NAMES=("alice.johnson" "bob.smith" "carol.white" "dave.brown" "eve.garcia")
EMAILS=("alice@example.com" "bob@corp.net" "carol@bigco.io" "dave@startup.dev" "eve@shop.org")
CARDS=("4111-1111-1111-1111" "5500-0000-0000-0004" "3400-000000-00009" "6011-0000-0000-0004")
SSNS=("123-45-6789" "987-65-4321" "555-12-3456" "111-22-3333")
SERVICES=("order-service" "payment-service" "user-service" "inventory-service" "shipping-service")
API_KEYS=("sk-prod-abc123xyz789def" "sk-test-qwerty987654uio" "sk-live-mnb456vcx321poi")

counter=0

echo "[log-generator] Starting continuous log generation (interval=${INTERVAL}s)..."

while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  TS_NANO=$(date -u +"%s")000000000
  IDX=$((counter % ${#NAMES[@]}))
  SVC=${SERVICES[$((counter % ${#SERVICES[@]}))]}

  # ── Plain-text logs for filelogreceiver ──────────────────────────────
  case $((counter % 6)) in
    0)
      echo "$TS INFO  [$SVC] Order #$((RANDOM % 90000 + 10000)) placed by user ${EMAILS[$IDX]}, credit card ${CARDS[$((counter % ${#CARDS[@]}))]}, amount \$$(( RANDOM % 500 + 50)).$((RANDOM % 99))" >> "$APP_LOG"
      ;;
    1)
      echo "$TS DEBUG [$SVC] Health check passed, uptime=$((counter * 7))s" >> "$APP_LOG"
      ;;
    2)
      echo "$TS WARN  [$SVC] Slow query: SELECT * FROM users WHERE ssn='${SSNS[$IDX]}' took $((RANDOM % 5 + 1)).$((RANDOM % 9))s" >> "$APP_LOG"
      ;;
    3)
      echo "$TS ERROR [$SVC] Authentication failed for api_key=${API_KEYS[$((counter % ${#API_KEYS[@]}))]}, ip=10.0.$((RANDOM % 255)).$((RANDOM % 255))" >> "$APP_LOG"
      ;;
    4)
      echo "$TS DEBUG [$SVC] GET /healthz returned 200" >> "$APP_LOG"
      ;;
    5)
      echo "$TS INFO  [$SVC] User signup: name=${NAMES[$IDX]}, email=${EMAILS[$IDX]}, ssn=${SSNS[$IDX]}, phone=+1-555-$((RANDOM % 900 + 100))-$((RANDOM % 9000 + 1000))" >> "$APP_LOG"
      ;;
  esac

  # ── OTLP JSON logs for otlpjsonfilereceiver ─────────────────────────
  case $((counter % 3)) in
    0)
      cat >> "$OTLP_LOG" <<EOF
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"live-generator"}}]},"scopeLogs":[{"scope":{"name":"order-processor"},"logRecords":[{"timeUnixNano":"${TS_NANO}","severityNumber":9,"severityText":"INFO","body":{"stringValue":"Payment received: card=${CARDS[$((counter % ${#CARDS[@]}))]} email=${EMAILS[$IDX]} amount=\$$(( RANDOM % 500 + 50))"},"attributes":[{"key":"user.email","value":{"stringValue":"${EMAILS[$IDX]}"}},{"key":"order.id","value":{"stringValue":"ORD-$((RANDOM % 9000 + 1000))"}}]}]}]}]}
EOF
      ;;
    1)
      cat >> "$OTLP_LOG" <<EOF
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"live-generator"}}]},"scopeLogs":[{"scope":{"name":"health-monitor"},"logRecords":[{"timeUnixNano":"${TS_NANO}","severityNumber":5,"severityText":"DEBUG","body":{"stringValue":"Readiness probe: all dependencies healthy"},"attributes":[{"key":"http.route","value":{"stringValue":"/ready"}}]}]}]}]}
EOF
      ;;
    2)
      cat >> "$OTLP_LOG" <<EOF
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"live-generator"}}]},"scopeLogs":[{"scope":{"name":"auth-handler"},"logRecords":[{"timeUnixNano":"${TS_NANO}","severityNumber":13,"severityText":"WARN","body":{"stringValue":"Suspicious login attempt: user=${NAMES[$IDX]} ssn=${SSNS[$IDX]} api_key=${API_KEYS[$((counter % ${#API_KEYS[@]}))]}"},"attributes":[{"key":"user.id","value":{"stringValue":"USR-$((RANDOM % 9000 + 1000))"}},{"key":"threat.level","value":{"stringValue":"medium"}}]}]}]}]}
EOF
      ;;
  esac

  counter=$((counter + 1))
  sleep "$INTERVAL"
done
