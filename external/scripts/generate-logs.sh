#!/usr/bin/env bash
# generate-logs.sh — Continuously generates sample application logs and OTLP JSON
# log records with embedded PII for demonstrating the RHBO collector pipeline.
# Designed for RHEL 9 / UBI minimal (avoids 'set -u' which breaks array indexing).
set -eo pipefail

INTERVAL="${INTERVAL:-3}"
LOG_DIR="${LOG_DIR:-/var/log/demo}"
mkdir -p "${LOG_DIR}"

# ---------------------------------------------------------------------------
# Data pools — the script rotates through these to produce varied output.
# ---------------------------------------------------------------------------
NAMES=("Alice Johnson" "Bob Smith" "Carol White" "David Brown" "Eve Martinez"
       "Frank Garcia" "Grace Lee" "Hank Wilson" "Iris Chen" "Jack Taylor")

EMAILS=("alice.johnson@example.com" "bob.smith@example.com" "carol.white@example.com"
        "david.brown@example.com" "eve.martinez@example.com" "frank.garcia@example.com"
        "grace.lee@example.com" "hank.wilson@example.com" "iris.chen@example.com"
        "jack.taylor@example.com")

CREDIT_CARDS=("4111-1111-1111-1111" "5500-0000-0000-0004" "4222-2222-2222-2222"
              "3782-822463-10005" "6011-1111-1111-1117" "3056-9309-0259-04")

SSNS=("123-45-6789" "987-65-4321" "234-56-7890" "345-67-8901"
      "456-78-9012" "567-89-0123" "678-90-1234" "789-01-2345")

API_KEYS=("sk-prod-abc123xyz789" "sk-prod-def456uvw012" "sk-prod-ghi789rst345"
          "sk-prod-jkl012mno678" "sk-prod-pqr345stu901")

SERVICES=("payment-service" "user-service" "order-service" "inventory-service"
          "auth-service" "notification-service" "audit-service" "api-gateway")

SEVERITIES=("INFO" "DEBUG" "WARN" "ERROR")
OTLP_SEV_NUMBERS=(9 5 13 17)
OTLP_SEV_TEXTS=("INFO" "DEBUG" "WARN" "ERROR")

# ---------------------------------------------------------------------------
# Helper — pick random element from an array.
# Usage: pick ARRAY_NAME  (prints the chosen value)
# ---------------------------------------------------------------------------
pick() {
    local -n arr=$1
    local len=${#arr[@]}
    echo "${arr[$((RANDOM % len))]}"
}

counter=0

echo ">>> generate-logs.sh starting — writing to ${LOG_DIR} every ${INTERVAL}s"

while true; do
    TS=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    TS_NANO=$(( $(date +%s) * 1000000000 ))

    svc=$(pick SERVICES)
    name=$(pick NAMES)
    email=$(pick EMAILS)
    card=$(pick CREDIT_CARDS)
    ssn=$(pick SSNS)
    apikey=$(pick API_KEYS)
    sev_idx=$((RANDOM % 4))
    sev="${SEVERITIES[$sev_idx]}"
    otlp_sev_num="${OTLP_SEV_NUMBERS[$sev_idx]}"
    otlp_sev_text="${OTLP_SEV_TEXTS[$sev_idx]}"

    pattern=$((counter % 6))

    # --- app.log line ---
    case $pattern in
        0)
            line="${TS} INFO [api-gateway] GET /healthz 200 OK — latency $((RANDOM % 5 + 1))ms"
            ;;
        1)
            line="${TS} INFO [api-gateway] GET /ready 200 OK — latency $((RANDOM % 3 + 1))ms"
            ;;
        2)
            amount="$((RANDOM % 500 + 10)).$((RANDOM % 100))"
            line="${TS} ${sev} [payment-service] Processing payment for ${name} — card ${card} amount \$${amount} email=${email}"
            ;;
        3)
            line="${TS} DEBUG [user-service] Fetching profile for ${name} email=${email} ssn=${ssn} api_key=${apikey}"
            ;;
        4)
            order_id=$((RANDOM % 90000 + 10000))
            line="${TS} WARN [order-service] Order #ORD-${order_id} flagged — customer ssn=${ssn} card=${card} email=${email}"
            ;;
        5)
            line="${TS} ERROR [${svc}] Unhandled exception processing request for ${email} — ssn=${ssn} key=${apikey}"
            ;;
    esac

    echo "${line}" >> "${LOG_DIR}/app.log"

    # --- otlp-logs.jsonl line ---
    case $pattern in
        0|1)
            route="/healthz"
            body="GET ${route} 200 OK latency=$((RANDOM % 5 + 1))ms"
            otlp_line="{\"resourceLogs\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"api-gateway\"}},{\"key\":\"deployment.environment\",\"value\":{\"stringValue\":\"production\"}}]},\"scopeLogs\":[{\"scope\":{\"name\":\"com.example.gateway\"},\"logRecords\":[{\"timeUnixNano\":\"${TS_NANO}\",\"severityNumber\":9,\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"${body}\"},\"attributes\":[{\"key\":\"http.method\",\"value\":{\"stringValue\":\"GET\"}},{\"key\":\"http.route\",\"value\":{\"stringValue\":\"${route}\"}},{\"key\":\"http.status_code\",\"value\":{\"intValue\":\"200\"}}]}]}]}]}"
            ;;
        *)
            body="Request processed for ${name} email=${email} card=${card} ssn=${ssn} api_key=${apikey}"
            otlp_line="{\"resourceLogs\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"${svc}\"}},{\"key\":\"deployment.environment\",\"value\":{\"stringValue\":\"production\"}}]},\"scopeLogs\":[{\"scope\":{\"name\":\"com.example.${svc}\"},\"logRecords\":[{\"timeUnixNano\":\"${TS_NANO}\",\"severityNumber\":${otlp_sev_num},\"severityText\":\"${otlp_sev_text}\",\"body\":{\"stringValue\":\"${body}\"},\"attributes\":[{\"key\":\"user.email\",\"value\":{\"stringValue\":\"${email}\"}},{\"key\":\"user.credit_card\",\"value\":{\"stringValue\":\"${card}\"}},{\"key\":\"user.ssn\",\"value\":{\"stringValue\":\"${ssn}\"}},{\"key\":\"api.key\",\"value\":{\"stringValue\":\"${apikey}\"}}]}]}]}]}"
            ;;
    esac

    echo "${otlp_line}" >> "${LOG_DIR}/otlp-logs.jsonl"

    counter=$((counter + 1))
    sleep "${INTERVAL}"
done
