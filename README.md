# RHBO Processor & Receiver Demo — OpenShift

A minimal, self-contained demo showcasing **Red Hat Build of OpenTelemetry (RHBO)** processor and receiver capabilities on **OpenShift**.

## What This Demo Shows

### Receivers (how telemetry gets in)

| Receiver | What it does | Data source in this demo |
|---|---|---|
| **filelogreceiver** | Tails plain-text log files | Simulated microservice logs in a shared `emptyDir` volume |
| **otlpjsonfilereceiver** | Reads OTLP JSON from files | Structured OTLP log records in a shared `emptyDir` volume |
| **journaldreceiver** | Reads systemd journal | Node journal via DaemonSet with host path mount |

### Processors (how telemetry gets transformed)

The processors run in this order on every pipeline:

```
receiver → resourceprocessor → attributesprocessor → transformprocessor → filterprocessor → debug exporter
```

| # | Processor | Demo behaviour | Why it matters |
|---|---|---|---|
| 1 | **resourceprocessor** | Adds `deployment.environment=staging`, `team.name=platform-engineering`, `k8s.cluster.name=ocp-demo` | Consistent metadata across all signals without app changes |
| 2 | **attributesprocessor** | Stamps `processed_by=rhbo-attributes-processor`, deletes temporary parsing attributes | Manipulate log-record attributes — insert, update, delete, hash |
| 3 | **transformprocessor** | Uppercases severity text, truncates long attributes, **redacts PII** (credit cards, SSNs, emails, API keys, JWTs) via OTTL `replace_pattern` | Reshape and sanitise telemetry in-flight using OTTL — no code changes needed |
| 4 | **filterprocessor** | Drops `DEBUG`-level logs and health-check probes (`/healthz`, `/ready`) | Reduce noise and storage costs |

---

## Quick Start

### Prerequisites

- OpenShift 4.x cluster with `oc` CLI authenticated (`oc login`)
- `cluster-admin` role (needed to install the operator and grant SCC)

### One-Command Deploy

```bash
cd openshift/
./deploy.sh
```

This will:

1. **Install the RHBO operator** — creates the `openshift-opentelemetry-operator` namespace, OperatorGroup, and Subscription, then waits for the CSV to reach `Succeeded`
2. **Create the demo namespace** (`rhbo-demo`) and ConfigMaps
3. **Deploy a sidecar Pod** with two containers sharing an `emptyDir` volume:
   - **log-generator** — writes sample logs (with PII) to the shared volume
   - **otel-collector** — RHBO collector reading from that volume, processing, and printing to stdout

### Deploy Variations

```bash
# Install only the operator (no demo workloads)
./deploy.sh --operator-only

# Deploy demo but skip operator install (if already installed)
./deploy.sh --skip-operator

# Use the OpenTelemetryCollector CR instead of a raw Deployment
./deploy.sh --use-cr

# Also deploy the per-node journald DaemonSet
./deploy.sh --journald

# Combine flags
./deploy.sh --use-cr --journald
```

### Operator Install Details

The `00-operator-install.yaml` manifest follows the [official Red Hat documentation](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/3.9/html/installing_red_hat_build_of_opentelemetry/install-otel) and creates:

| Resource | Namespace | Purpose |
|---|---|---|
| `Project` | `openshift-opentelemetry-operator` | Operator namespace with cluster monitoring enabled |
| `OperatorGroup` | `openshift-opentelemetry-operator` | All-namespaces install scope |
| `Subscription` | `openshift-opentelemetry-operator` | Subscribes to `opentelemetry-product` on the `stable` channel from `redhat-operators` |

The deploy script waits for OLM to assign a CSV and for the CSV to reach `Succeeded` before proceeding.

### Watch Processor Effects

```bash
# Follow the collector output — see processed, filtered, redacted logs
oc logs -f deployment/rhbo-demo -c otel-collector -n rhbo-demo

# Compare with the raw input (PII visible, debug logs present)
oc logs -f deployment/rhbo-demo -c log-generator -n rhbo-demo

# Journald collector (if deployed)
oc logs -f daemonset/rhbo-journald-collector -n rhbo-demo
```

You will see:

1. **Resource attributes added** — every log has `deployment.environment`, `team.name`, `k8s.cluster.name`
2. **Attributes cleaned** — `processed_by: rhbo-attributes-processor` added, temporary parse attributes removed
3. **Transform + PII redaction** — severity uppercased, credit cards/SSNs/emails/API keys replaced with `****`
4. **Filtered logs** — no DEBUG-level or health-check logs appear

### Teardown

```bash
# Remove demo namespace only (keeps operator installed)
./openshift/deploy.sh --teardown

# Remove everything including the operator
./openshift/deploy.sh --teardown-all
```

---

## Project Structure

```
├── data/
│   ├── app.log                              # Sample app logs (contains PII)
│   └── otlp-logs.jsonl                      # Sample OTLP JSON logs (contains PII)
├── scripts/
│   └── generate-logs.sh                     # Continuous log generator
├── openshift/
│   ├── 00-operator-install.yaml             # RHBO operator (Project + OperatorGroup + Subscription)
│   ├── 01-namespace.yaml                    # Namespace: rhbo-demo
│   ├── 02-configmap-sample-data.yaml        # Seed log data
│   ├── 03-configmap-log-generator.yaml      # Log generator script
│   ├── 04-configmap-collector.yaml          # Collector config (filelog + otlpjson)
│   ├── 05-deployment-demo.yaml              # Sidecar Deployment (generator + collector)
│   ├── 06-opentelemetrycollector-cr.yaml    # Operator CR (alternative to 05)
│   ├── 07-daemonset-journald.yaml           # Journald DaemonSet + config
│   └── deploy.sh                            # One-command deploy script
├── otel-collector-config.yaml               # Standalone config (with journald)
├── otel-collector-config-no-journald.yaml   # Standalone config (without journald)
├── docker-compose.yaml                      # Docker Compose alternative
├── Dockerfile.log-generator                 # Docker build for log generator
└── README.md                                # This file
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  OpenShift Cluster                                                      │
│                                                                         │
│  ┌─────────────────── Pod: rhbo-demo ──────────────────────────┐       │
│  │                                                              │       │
│  │  ┌──────────────┐   emptyDir    ┌────────────────────────┐  │       │
│  │  │ log-generator│──/var/log/──▶│ otel-collector (RHBO)  │  │       │
│  │  │              │   demo/       │                        │  │       │
│  │  │ writes:      │              │ filelog receiver        │  │       │
│  │  │  app.log     │              │ otlpjsonfile receiver   │  │       │
│  │  │  otlp.jsonl  │              │         │               │  │       │
│  │  └──────────────┘              │         ▼               │  │       │
│  │                                │ ┌──────────────────┐    │  │       │
│  │                                │ │ 1. resource      │    │  │       │
│  │                                │ │ 2. transform     │    │  │       │
│  │                                │ │ 3. filter        │    │  │       │
│  │                                │ │ 4. redaction     │    │  │       │
│  │                                │ └────────┬─────────┘    │  │       │
│  │                                │          ▼              │  │       │
│  │                                │   debug exporter        │  │       │
│  │                                │   (stdout)              │  │       │
│  │                                └────────────────────────┘  │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
│  ┌─────────── DaemonSet: rhbo-journald-collector ──────────────┐       │
│  │  hostPath: /var/log/journal  →  journald receiver           │       │
│  │  Same 4 processors → debug exporter                         │       │
│  └─────────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
```

## Demo Talk Track

### Opening
> "Let me show you how RHBO on OpenShift can transform, filter, and secure your telemetry data without changing a single line of application code."

### Receiver Story
> "We have three different log sources feeding into the RHBO collector:
> - A **file log receiver** tailing a standard application log from a shared volume
> - An **OTLP JSON file receiver** consuming structured telemetry exports
> - A **journald receiver** running as a DaemonSet, pulling directly from each node's systemd journal
>
> All three feed into the same processing pipeline — the same four processors."

### Processor Walkthrough

**1. Resource Processor**
> "First, the resource processor enriches every single log with deployment metadata — environment, team ownership, cluster name. This happens automatically at the collector level; no application instrumentation changes needed."

**2. Attributes Processor**
> "Next, the attributes processor manipulates log record attributes directly. It stamps a processing marker, and cleans up temporary attributes left over from parsing. You can insert, update, delete, or even hash attribute values — great for normalisation and housekeeping."

**3. Transform Processor**
> "The transform processor is where OTTL really shines. We normalise severity text to uppercase, truncate oversized attributes, and — crucially — **redact PII in-flight**. Credit card numbers, Social Security Numbers, email addresses, API keys, JWT tokens — all replaced with `****` using `replace_pattern` before the data leaves the collector. Compliance-ready telemetry, zero application changes."

**4. Filter Processor**
> "Finally, the filter processor drops the noise. All those DEBUG health-check logs and readiness probes that flood your observability backend? Gone. We keep only actionable INFO, WARN, and ERROR logs. This directly reduces storage costs and improves signal-to-noise ratio."

### Closing
> "Four processors, three receivers, zero application changes, all running on OpenShift with a Red Hat supported, enterprise-grade OpenTelemetry distribution."

---

## Customisation

### Use the RHBO operator image

The sidecar deployment (`04-deployment-demo.yaml`) uses:

```yaml
image: registry.redhat.io/rhosdt/opentelemetry-collector-rhel9:latest
```

Replace with the specific version tag for your environment if needed.

### Add an observability backend

Replace or augment `debugexporter` with `otlpexporter` or `otlphttpexporter` to send data to:
- Red Hat OpenShift distributed tracing (Tempo)
- Red Hat OpenShift Logging (Loki)
- Any OTLP-compatible backend

### Supported components

See the full [RHBO manifest](https://github.com/os-observability/redhat-opentelemetry-collector/blob/main/manifest.yaml) for all supported receivers, processors, exporters, and connectors.
