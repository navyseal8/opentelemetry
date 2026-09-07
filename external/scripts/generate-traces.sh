#!/usr/bin/env bash
# generate-traces.sh — Continuously generates OTLP JSON traces and POSTs them
# to the local RHBO collector's OTLP HTTP receiver. Includes PII in span
# attributes for demonstrating redaction/filtering pipelines.
# Designed for RHEL 9 / UBI minimal with curl installed.
set -eo pipefail

INTERVAL="${INTERVAL:-2}"
COLLECTOR_HOST="${COLLECTOR_HOST:-localhost}"
OTLP_ENDPOINT="http://${COLLECTOR_HOST}:4318/v1/traces"

# ---------------------------------------------------------------------------
# Data pools
# ---------------------------------------------------------------------------
EMAILS=("alice.johnson@example.com" "bob.smith@example.com" "carol.white@example.com"
        "david.brown@example.com" "eve.martinez@example.com" "frank.garcia@example.com")

CREDIT_CARDS=("4111-1111-1111-1111" "5500-0000-0000-0004" "4222-2222-2222-2222"
              "3782-822463-10005" "6011-1111-1111-1117")

SSNS=("123-45-6789" "987-65-4321" "234-56-7890" "345-67-8901" "456-78-9012")

SERVICE_NAMES=("payment-service" "order-service" "user-service" "inventory-service" "api-gateway")

ROUTES=("/api/v1/payments" "/api/v1/orders" "/api/v1/users" "/api/v1/inventory" "/api/v1/checkout")

METHODS=("GET" "POST" "PUT" "DELETE")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
pick() {
    local -n arr=$1
    local len=${#arr[@]}
    echo "${arr[$((RANDOM % len))]}"
}

rand_hex() {
    local length=$1
    head -c $((length / 2)) /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c "${length}"
}

counter=0

echo ">>> generate-traces.sh starting — posting to ${OTLP_ENDPOINT} every ${INTERVAL}s"

while true; do
    trace_id=$(rand_hex 32)
    email=$(pick EMAILS)
    card=$(pick CREDIT_CARDS)
    ssn=$(pick SSNS)
    svc=$(pick SERVICE_NAMES)
    route=$(pick ROUTES)
    method=$(pick METHODS)

    now_s=$(date +%s)
    start_nano=$(( now_s * 1000000000 ))

    # Determine trace type based on counter
    trace_type=$((counter % 5))

    case $trace_type in
        0|1|2)
            # Normal fast trace
            duration_ms=$(( RANDOM % 151 + 50 ))
            status_code=200
            span_status_code=1  # STATUS_CODE_OK
            span_status_message=""
            ;;
        3)
            # Slow trace
            duration_ms=$(( RANDOM % 3001 + 2000 ))
            status_code=200
            span_status_code=1
            span_status_message=""
            ;;
        4)
            # Error trace
            duration_ms=$(( RANDOM % 401 + 100 ))
            status_code=500
            span_status_code=2  # STATUS_CODE_ERROR
            span_status_message="Internal Server Error: database connection timeout"
            ;;
    esac

    duration_nano=$(( duration_ms * 1000000 ))
    end_nano=$(( start_nano + duration_nano ))

    # Generate 1-3 spans
    num_spans=$(( RANDOM % 3 + 1 ))
    spans=""

    for i in $(seq 0 $((num_spans - 1))); do
        span_id=$(rand_hex 16)
        span_start=$(( start_nano + i * (duration_nano / num_spans) ))
        span_end=$(( span_start + duration_nano / num_spans ))
        span_name="${method} ${route}"

        if [ $i -gt 0 ]; then
            span_name="${route}/internal-step-${i}"
        fi

        # Build events JSON (only for error traces)
        events=""
        if [ "$trace_type" -eq 4 ] && [ "$i" -eq 0 ]; then
            events=",\"events\":[{\"timeUnixNano\":\"${span_end}\",\"name\":\"exception\",\"attributes\":[{\"key\":\"exception.type\",\"value\":{\"stringValue\":\"DatabaseConnectionError\"}},{\"key\":\"exception.message\",\"value\":{\"stringValue\":\"Connection to primary DB timed out after 30s for user email=${email} ssn=${ssn}\"}}]}]"
        fi

        # Build status JSON
        if [ "$span_status_code" -eq 2 ]; then
            status="\"status\":{\"code\":${span_status_code},\"message\":\"${span_status_message}\"}"
        else
            status="\"status\":{\"code\":${span_status_code}}"
        fi

        span="{\"traceId\":\"${trace_id}\",\"spanId\":\"${span_id}\",\"name\":\"${span_name}\",\"kind\":2,\"startTimeUnixNano\":\"${span_start}\",\"endTimeUnixNano\":\"${span_end}\",\"attributes\":[{\"key\":\"http.method\",\"value\":{\"stringValue\":\"${method}\"}},{\"key\":\"http.route\",\"value\":{\"stringValue\":\"${route}\"}},{\"key\":\"http.status_code\",\"value\":{\"intValue\":\"${status_code}\"}},{\"key\":\"http.url\",\"value\":{\"stringValue\":\"https://api.example.com${route}\"}},{\"key\":\"user.email\",\"value\":{\"stringValue\":\"${email}\"}},{\"key\":\"user.credit_card\",\"value\":{\"stringValue\":\"${card}\"}},{\"key\":\"user.ssn\",\"value\":{\"stringValue\":\"${ssn}\"}}]${events},${status}}"

        if [ -n "$spans" ]; then
            spans="${spans},${span}"
        else
            spans="${span}"
        fi
    done

    # Assemble the full OTLP trace payload
    payload="{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"${svc}\"}},{\"key\":\"deployment.environment\",\"value\":{\"stringValue\":\"production\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"com.example.${svc}\"},\"spans\":[${spans}]}]}]}"

    # POST to the collector
    curl -s -o /dev/null -w "trace=%{http_code} " \
        -X POST "${OTLP_ENDPOINT}" \
        -H "Content-Type: application/json" \
        -d "${payload}" || echo "WARN: curl failed (collector may not be ready yet)"

    echo "sent trace_id=${trace_id} type=${trace_type} spans=${num_spans} svc=${svc}"

    counter=$((counter + 1))
    sleep "${INTERVAL}"
done
