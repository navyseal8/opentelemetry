#!/usr/bin/env bash
###############################################################################
# deploy.sh — Deploy the RHBO observability backend to OpenShift
#
# Usage:
#   ./deploy.sh                     # Full deploy (operators + backend + collector + UI)
#   ./deploy.sh --operators-only    # Install just the 4 operators
#   ./deploy.sh --skip-operators    # Skip operator install
#   ./deploy.sh --teardown          # Remove demo namespaces (keeps operators)
#   ./deploy.sh --teardown-all      # Remove everything including operators
###############################################################################
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[RHBO]${NC} $*"; }
warn() { echo -e "${YELLOW}[RHBO]${NC} $*"; }
err()  { echo -e "${RED}[RHBO]${NC} $*" >&2; }
hdr()  { echo -e "\n${BOLD}═══ $* ═══${NC}"; }

SKIP_OPERATORS=false
OPERATORS_ONLY=false
TEARDOWN=false
TEARDOWN_ALL=false

for arg in "$@"; do
  case "$arg" in
    --skip-operators)  SKIP_OPERATORS=true ;;
    --operators-only)  OPERATORS_ONLY=true ;;
    --teardown)        TEARDOWN=true ;;
    --teardown-all)    TEARDOWN_ALL=true ;;
    *) err "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Teardown ────────────────────────────────────────────────────────────────
if $TEARDOWN; then
  hdr "Tearing down demo workloads"
  oc delete namespace rhbo-demo --ignore-not-found
  oc delete lokistack logging-loki -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete secret logging-loki-s3 -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete deployment minio -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete job minio-bucket-setup -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete service minio -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete uiplugin logging distributed-tracing --ignore-not-found 2>/dev/null || true
  log "Demo workloads removed. Operators left intact."
  exit 0
fi

if $TEARDOWN_ALL; then
  hdr "Tearing down everything (demo + operators)"
  oc delete namespace rhbo-demo --ignore-not-found
  oc delete lokistack logging-loki -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete secret logging-loki-s3 -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete deployment minio -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete job minio-bucket-setup -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete service minio -n openshift-logging --ignore-not-found 2>/dev/null || true
  oc delete uiplugin logging distributed-tracing --ignore-not-found 2>/dev/null || true
  for sub in opentelemetry-product loki-operator tempo-product cluster-observability-operator; do
    ns=$(oc get subscription "$sub" --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    if [[ -n "$ns" ]]; then
      oc delete subscription "$sub" -n "$ns" --ignore-not-found 2>/dev/null || true
      oc delete csv -l "operators.coreos.com/${sub}.${ns}=" -n "$ns" --ignore-not-found 2>/dev/null || true
    fi
  done
  oc delete project openshift-opentelemetry-operator --ignore-not-found 2>/dev/null || true
  oc delete project openshift-tempo-operator --ignore-not-found 2>/dev/null || true
  log "Everything removed."
  exit 0
fi

# ── Pre-flight ──────────────────────────────────────────────────────────────
if ! command -v oc &>/dev/null; then
  err "oc CLI not found."; exit 1
fi
if ! oc whoami &>/dev/null; then
  err "Not logged in. Run: oc login <cluster-url>"; exit 1
fi

CLUSTER=$(oc whoami --show-server 2>/dev/null || echo "unknown")
log "Cluster : ${CYAN}${CLUSTER}${NC}"
log "User    : ${CYAN}$(oc whoami)${NC}"

###############################################################################
# wait_for_csv — wait for a subscription's CSV to succeed
###############################################################################
wait_for_csv() {
  local sub_name="$1" sub_ns="$2" max_attempts="${3:-60}"
  local csv="" phase="" attempts=0

  log "Waiting for ${CYAN}${sub_name}${NC} CSV..."
  while [[ -z "$csv" || "$csv" == "null" ]]; do
    attempts=$((attempts + 1))
    if [[ $attempts -gt $max_attempts ]]; then
      err "Timed out waiting for CSV of $sub_name"; return 1
    fi
    sleep 5
    csv=$(oc get subscription "$sub_name" -n "$sub_ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    [[ $((attempts % 12)) -eq 0 ]] && log "  Still waiting for $sub_name CSV... (${attempts}/${max_attempts})"
  done

  attempts=0
  while [[ "$phase" != "Succeeded" ]]; do
    attempts=$((attempts + 1))
    if [[ $attempts -gt $max_attempts ]]; then
      err "CSV $csv did not reach Succeeded (phase=$phase)"; return 1
    fi
    sleep 5
    phase=$(oc get csv "$csv" -n "$sub_ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ $((attempts % 12)) -eq 0 ]] && log "  $sub_name phase: ${YELLOW}${phase:-Pending}${NC} (${attempts}/${max_attempts})"
  done
  log "${CYAN}${csv}${NC} -> ${GREEN}Succeeded${NC}"
}

###############################################################################
# PHASE 0 — Operators
###############################################################################
if ! $SKIP_OPERATORS; then
  hdr "Phase 0: Install Operators"

  log "Applying RHBO operator..."
  oc apply -f "$SCRIPT_DIR/operators/00-rhbo-operator.yaml"
  log "Applying Loki operator..."
  oc apply -f "$SCRIPT_DIR/operators/01-loki-operator.yaml"
  log "Applying Tempo operator..."
  oc apply -f "$SCRIPT_DIR/operators/02-tempo-operator.yaml"
  log "Applying COO operator..."
  oc apply -f "$SCRIPT_DIR/operators/03-coo-operator.yaml"

  wait_for_csv opentelemetry-product openshift-opentelemetry-operator
  wait_for_csv loki-operator openshift-operators-redhat
  wait_for_csv tempo-product openshift-tempo-operator
  wait_for_csv cluster-observability-operator openshift-cluster-observability-operator
fi

if $OPERATORS_ONLY; then
  log "Operators installed. Run without --operators-only to deploy the backend."
  exit 0
fi

###############################################################################
# PHASE 1 — Namespaces + MinIO
###############################################################################
hdr "Phase 1: Namespaces & Object Storage"

oc apply -f "$SCRIPT_DIR/backend/10-namespace.yaml"
oc apply -f "$SCRIPT_DIR/backend/11-minio.yaml"

log "Waiting for MinIO to be ready..."
oc rollout status deployment/minio -n openshift-logging --timeout=120s

log "Running bucket setup job..."
oc wait --for=condition=complete job/minio-bucket-setup -n openshift-logging --timeout=60s 2>/dev/null || \
  warn "Bucket setup job may still be running. Check: oc get jobs -n openshift-logging"

###############################################################################
# PHASE 2 — LokiStack + Tempo
###############################################################################
hdr "Phase 2: LokiStack & Tempo"

oc apply -f "$SCRIPT_DIR/backend/12-lokistack.yaml"
oc apply -f "$SCRIPT_DIR/backend/13-tempo-monolithic.yaml"

log "Waiting for LokiStack (this may take 2-5 minutes)..."
oc wait --for=condition=Ready lokistack/logging-loki -n openshift-logging --timeout=300s 2>/dev/null || \
  warn "LokiStack not yet ready. Check: oc get lokistack -n openshift-logging"

log "Waiting for TempoMonolithic..."
oc wait --for=condition=Ready tempomonolithic/rhbo-tempo -n rhbo-demo --timeout=300s 2>/dev/null || \
  warn "Tempo not yet ready. Check: oc get tempomonolithic -n rhbo-demo"

###############################################################################
# PHASE 3 — RHBO Collector Gateway + Route
###############################################################################
hdr "Phase 3: RHBO Collector Gateway"

oc apply -f "$SCRIPT_DIR/collector/20-collector-gateway.yaml"
oc apply -f "$SCRIPT_DIR/collector/21-route.yaml"

log "Waiting for collector gateway..."
oc rollout status deployment/rhbo-collector-gateway -n rhbo-demo --timeout=120s

ROUTE_HOST=$(oc get route rhbo-collector-otlp -n rhbo-demo -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

###############################################################################
# PHASE 4 — COO UI Plugins
###############################################################################
hdr "Phase 4: COO UI Plugins"

oc apply -f "$SCRIPT_DIR/ui/30-uiplugin-logging.yaml"
oc apply -f "$SCRIPT_DIR/ui/31-uiplugin-tracing.yaml"

###############################################################################
# Done
###############################################################################
hdr "Deployment Complete"

echo ""
log "OpenShift backend is ready!"
echo ""
echo -e "  ${BOLD}OTLP Route (for external agent):${NC}"
echo -e "  ${CYAN}https://${ROUTE_HOST}${NC}"
echo ""
echo -e "  ${BOLD}Configure the external RHEL agent:${NC}"
echo -e "  export OTEL_EXPORTER_OTLP_ENDPOINT=https://${ROUTE_HOST}"
echo ""
echo -e "  ${BOLD}Verify:${NC}"
echo -e "  ${CYAN}oc logs -f deployment/rhbo-collector-gateway -n rhbo-demo${NC}"
echo ""
echo -e "  ${BOLD}OpenShift Console:${NC}"
echo -e "  Observe > Logs    (filtered, PII-redacted logs from external sources)"
echo -e "  Observe > Traces  (tail-sampled traces: errors + slow requests)"
echo ""
echo -e "  ${BOLD}Teardown:${NC}"
echo -e "  $0 --teardown          # remove demo, keep operators"
echo -e "  $0 --teardown-all      # remove everything"
echo ""
