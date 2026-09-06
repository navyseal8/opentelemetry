#!/usr/bin/env bash
###############################################################################
# deploy.sh — Deploy the RHBO demo to OpenShift
#
# Usage:
#   ./deploy.sh                        # Full deploy: operator + sidecar demo
#   ./deploy.sh --operator-only        # Install just the RHBO operator
#   ./deploy.sh --skip-operator        # Skip operator install, deploy demo only
#   ./deploy.sh --journald             # Also deploy the journald DaemonSet
#   ./deploy.sh --use-cr               # Use OpenTelemetryCollector CR instead
#   ./deploy.sh --teardown             # Remove demo namespace (keeps operator)
#   ./deploy.sh --teardown-all         # Remove everything including operator
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="rhbo-demo"
OPERATOR_NS="openshift-opentelemetry-operator"

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

# ── Parse flags ─────────────────────────────────────────────────────────────
SKIP_OPERATOR=false
OPERATOR_ONLY=false
USE_CR=false
JOURNALD=false
TEARDOWN=false
TEARDOWN_ALL=false

for arg in "$@"; do
  case "$arg" in
    --skip-operator)  SKIP_OPERATOR=true ;;
    --operator-only)  OPERATOR_ONLY=true ;;
    --use-cr)         USE_CR=true ;;
    --journald)       JOURNALD=true ;;
    --teardown)       TEARDOWN=true ;;
    --teardown-all)   TEARDOWN_ALL=true ;;
    *) err "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Teardown ────────────────────────────────────────────────────────────────
if $TEARDOWN; then
  hdr "Tearing down RHBO demo"
  oc delete namespace "$NS" --ignore-not-found
  log "Namespace ${CYAN}${NS}${NC} removed. Operator left intact."
  exit 0
fi

if $TEARDOWN_ALL; then
  hdr "Tearing down everything (demo + operator)"
  oc delete namespace "$NS" --ignore-not-found
  log "Namespace ${CYAN}${NS}${NC} removed."
  oc delete subscription opentelemetry-product -n "$OPERATOR_NS" --ignore-not-found
  oc delete csv -l operators.coreos.com/opentelemetry-product."$OPERATOR_NS"="" -n "$OPERATOR_NS" --ignore-not-found 2>/dev/null || true
  oc delete operatorgroup openshift-opentelemetry-operator -n "$OPERATOR_NS" --ignore-not-found
  oc delete project "$OPERATOR_NS" --ignore-not-found
  log "Operator namespace ${CYAN}${OPERATOR_NS}${NC} removed."
  exit 0
fi

# ── Pre-flight checks ──────────────────────────────────────────────────────
if ! command -v oc &>/dev/null; then
  err "oc CLI not found. Install it from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  err "Not logged in to OpenShift. Run: oc login <cluster-url>"
  exit 1
fi

CLUSTER=$(oc whoami --show-server 2>/dev/null || echo "unknown")
USER=$(oc whoami 2>/dev/null || echo "unknown")
log "Cluster : ${CYAN}${CLUSTER}${NC}"
log "User    : ${CYAN}${USER}${NC}"

###############################################################################
# STEP 0 — Install the RHBO Operator
###############################################################################
install_operator() {
  hdr "Step 0: Installing RHBO Operator"

  # Check if already installed
  if oc get subscription opentelemetry-product -n "$OPERATOR_NS" &>/dev/null; then
    log "Subscription ${CYAN}opentelemetry-product${NC} already exists."
    CSV=$(oc get subscription opentelemetry-product -n "$OPERATOR_NS" \
          -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    if [[ -n "$CSV" ]]; then
      PHASE=$(oc get csv "$CSV" -n "$OPERATOR_NS" \
              -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
      log "Current CSV: ${CYAN}${CSV}${NC} — phase: ${CYAN}${PHASE}${NC}"
      if [[ "$PHASE" == "Succeeded" ]]; then
        log "Operator is already installed and healthy. Skipping."
        return 0
      fi
    fi
  fi

  log "Applying operator manifests (Project, OperatorGroup, Subscription)..."
  oc apply -f "$SCRIPT_DIR/00-operator-install.yaml"

  # Wait for the Subscription to get a CSV reference
  log "Waiting for OLM to assign a ClusterServiceVersion..."
  local attempts=0
  local max_attempts=60
  local csv=""

  while [[ -z "$csv" || "$csv" == "null" ]]; do
    attempts=$((attempts + 1))
    if [[ $attempts -gt $max_attempts ]]; then
      err "Timed out waiting for CSV assignment after $((max_attempts * 5))s."
      err "Check: oc get subscription opentelemetry-product -n $OPERATOR_NS -o yaml"
      exit 1
    fi
    sleep 5
    csv=$(oc get subscription opentelemetry-product -n "$OPERATOR_NS" \
          -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    if [[ $((attempts % 6)) -eq 0 ]]; then
      log "Still waiting... (${attempts}/${max_attempts})"
    fi
  done

  log "CSV assigned: ${CYAN}${csv}${NC}"

  # Wait for the CSV to reach Succeeded phase
  log "Waiting for operator to become ready..."
  attempts=0
  local phase=""

  while [[ "$phase" != "Succeeded" ]]; do
    attempts=$((attempts + 1))
    if [[ $attempts -gt $max_attempts ]]; then
      err "Timed out waiting for CSV ${csv} to succeed after $((max_attempts * 5))s."
      err "Current phase: $phase"
      err "Check: oc get csv $csv -n $OPERATOR_NS -o yaml"
      exit 1
    fi
    sleep 5
    phase=$(oc get csv "$csv" -n "$OPERATOR_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ $((attempts % 6)) -eq 0 ]]; then
      log "Phase: ${YELLOW}${phase:-Pending}${NC} (${attempts}/${max_attempts})"
    fi
  done

  log "Operator ${CYAN}${csv}${NC} installed successfully! ✓"
}

if ! $SKIP_OPERATOR; then
  install_operator
fi

if $OPERATOR_ONLY; then
  echo ""
  log "Operator installed. Run ${CYAN}$0${NC} (without --operator-only) to deploy the demo."
  exit 0
fi

###############################################################################
# STEP 1 — Create namespace + ConfigMaps
###############################################################################
hdr "Step 1: Namespace & ConfigMaps"

log "Creating namespace ${CYAN}${NS}${NC}..."
oc apply -f "$SCRIPT_DIR/01-namespace.yaml"

log "Creating ConfigMaps (sample data, log-generator script, collector config)..."
oc apply -f "$SCRIPT_DIR/02-configmap-sample-data.yaml"
oc apply -f "$SCRIPT_DIR/03-configmap-log-generator.yaml"
oc apply -f "$SCRIPT_DIR/04-configmap-collector.yaml"

###############################################################################
# STEP 2 — Deploy the collector
###############################################################################
hdr "Step 2: Deploy RHBO Collector"

if $USE_CR; then
  log "Deploying via OpenTelemetryCollector CR (operator-managed)..."
  oc apply -f "$SCRIPT_DIR/06-opentelemetrycollector-cr.yaml"
else
  log "Deploying sidecar Deployment (log-generator + collector)..."
  oc apply -f "$SCRIPT_DIR/05-deployment-demo.yaml"
fi

# Wait for rollout
log "Waiting for pods to become ready..."
if $USE_CR; then
  oc rollout status deployment/rhbo-demo-collector -n "$NS" --timeout=120s 2>/dev/null || \
    warn "CR-managed deployment may take longer. Check: oc get pods -n $NS"
else
  oc rollout status deployment/rhbo-demo -n "$NS" --timeout=120s
fi

###############################################################################
# STEP 3 (optional) — Journald DaemonSet
###############################################################################
if $JOURNALD; then
  hdr "Step 3: Journald DaemonSet"

  log "Creating ServiceAccount and granting privileged SCC..."
  oc apply -f "$SCRIPT_DIR/07-daemonset-journald.yaml"
  oc adm policy add-scc-to-user privileged -z rhbo-journald -n "$NS"

  log "Waiting for DaemonSet rollout..."
  oc rollout status daemonset/rhbo-journald-collector -n "$NS" --timeout=120s
fi

###############################################################################
# Done
###############################################################################
hdr "Deployment Complete"

echo ""
log "RHBO operator  : ${GREEN}installed${NC} in ${CYAN}${OPERATOR_NS}${NC}"
log "Demo workloads : ${GREEN}running${NC}  in ${CYAN}${NS}${NC}"
echo ""
echo -e "  ${BOLD}Watch processors in action:${NC}"
echo ""

if $USE_CR; then
  echo -e "  ${CYAN}# Collector logs (operator-managed)${NC}"
  echo "  oc logs -f deployment/rhbo-demo-collector -n $NS"
else
  echo -e "  ${CYAN}# Collector logs — see resource enrichment, filtering, and redaction${NC}"
  echo "  oc logs -f deployment/rhbo-demo -c otel-collector -n $NS"
  echo ""
  echo -e "  ${CYAN}# Raw log generator output — compare PII before/after${NC}"
  echo "  oc logs -f deployment/rhbo-demo -c log-generator -n $NS"
fi

if $JOURNALD; then
  echo ""
  echo -e "  ${CYAN}# Journald collector logs${NC}"
  echo "  oc logs -f daemonset/rhbo-journald-collector -n $NS"
fi

echo ""
echo -e "  ${BOLD}Teardown:${NC}"
echo -e "  ${CYAN}$0 --teardown${NC}          # remove demo, keep operator"
echo -e "  ${CYAN}$0 --teardown-all${NC}      # remove everything"
echo ""
