# Trust DAG

A **trust-aware data plane** for agent-based systems. Captures who acted on behalf of whom at every delegation hop — without instrumenting application code — and uses the same infrastructure to enforce policy.

```
Principal → Agent → (Agent → …) → Resource
```

## What it does

1. **Observe** — Proxy sidecars emit trust-tagged spans at every hop. The observation point sits outside the agent's trust boundary. A compromised agent cannot alter its own trace data.
2. **Reconstruct** — A lineage service builds the full delegation DAG from trust-tagged spans. Each run is scored against learned baselines to detect novel edges, capability overreach, and anomalous patterns.
3. **Enforce** — The same proxy that observes calls out to pluggable policy engines to allow or deny requests before they reach the agent.

## Architecture

```
                   ┌──────────────────────────────────────────────────────────┐
                   │                    Trust DAG Data Plane                  │
                   │                                                         │
 alice ──────────> │  Ingress Gateway                                        │
                   │  (identity extraction + trust header stamping)           │
                   │       │                                                 │
                   │       ▼                                                 │
                   │  ┌──────────┐   ┌──────────┐   ┌──────────┐            │
                   │  │chat-agent│──>│read-agent │──>│mock-     │            │
                   │  │+ sidecar │   │+ sidecar  │   │database  │            │
                   │  └──────────┘   └──────────┘   └──────────┘            │
                   │       │                                                 │
                   │       ├────────>┌─────────────┐                         │
                   │       │         │summary-agent│──> read-agent ──> db    │
                   │       │         │+ sidecar    │                         │
                   │       │         └─────────────┘                         │
                   │       │                                                 │
                   │       └────────>┌───────────┐                           │
                   │                 │sales-agent│──> db                     │
                   │                 │+ sidecar  │                           │
                   │                 └───────────┘                           │
                   │                                                         │
                   │  OTel spans ──> OTel Collector ──> Trace Backend        │
                   │                                        │                │
                   │                                        ▼                │
                   │                                  Lineage Service        │
                   │                                  (DAG, Explain, Assess) │
                   └──────────────────────────────────────────────────────────┘
```

## Components

| Component | Purpose |
|-----------|---------|
| **Ingress Gateway** | Extracts caller identity, stamps trust headers, emits first-hop span |
| **Proxy Sidecars** | Per-agent inbound/outbound listeners. Inbound: span emission + enforcement. Outbound: header mutation + routing |
| **OTel Collector** | Receives trust-tagged spans from all proxies, exports to trace backend |
| **Trace Backend** | Span storage, queried by lineage service |
| **Lineage Service** | DAG reconstruction, explain (provenance), assess (risk scoring), capability alignment |
| **Agents** | `chat-agent` (router), `read-agent`, `summary-agent`, `sales-agent` — plain HTTP servers, no trust instrumentation |
| **Mock Database** | Simple data store queried by agents |

## Trust Headers

| Header | Purpose |
|--------|---------|
| `x-principal-id` | Verified caller identity — immutable through all hops |
| `x-caller-id` | Current caller — mutated at each outbound hop |
| `x-caller-type` | `principal` or `agent` — mutated at each hop |
| `x-request-id` | Correlation ID for the delegation run — immutable |
| `x-trust-hop-kind` | `ingress`, `delegation`, or `resource_access` — mutated at each hop |

## Lineage Service APIs

| Endpoint | Returns |
|----------|---------|
| `/lineage/{run_id}/dag` | Full delegation graph (JSON or DOT) |
| `/lineage/{run_id}/trust` | Topologically ordered event list |
| `/lineage/{run_id}/explain?node=X` | Provenance: why was this node accessed? |
| `/lineage/{run_id}/assess` | Risk score against learned baseline |
| `/agents` | Agent registry with capability cards |
| `/system` | Baseline statistics across all runs |

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Quick Start

```bash
# Create the kind cluster
./scripts/create-cluster.sh

# Deploy all components
./scripts/deploy-all.sh

# Verify the setup
./scripts/verify.sh

# Send a test request
./scripts/test-request.sh
```

After deploying, port-forward to access the services:
```bash
# Ingress gateway
kubectl port-forward -n ingress-gateway svc/envoy-ingress 8080:8080

# Trace backend
kubectl port-forward -n observability svc/jaeger 16686:16686
```

Then open:
- **Dashboard**: http://localhost:8080/dashboard
- **Trust DAG UI**: http://localhost:8080/ui
- **Demo Slides**: http://localhost:8080/ui/demo-slides.html

## Project Structure

```
.
├── k8s/
│   ├── namespaces/            # Namespace definitions
│   ├── ingress-gateway/       # Ingress proxy configuration
│   ├── workloads/             # Agents, sidecars, lineage service, database, UI
│   ├── observability/         # OTel Collector + trace backend
│   └── egress-gateway/        # Egress proxy configuration
├── scripts/                   # Cluster setup, deploy, verify, test scripts
├── ui/                        # Demo slides, blog post, architecture slides
├── experiments/               # Experiment results and analysis
├── .github/                   # Copilot instructions
└── CLAUDE.md                  # AI assistant context
```

## Namespaces

| Namespace | Components |
|-----------|-----------|
| `ingress-gateway` | Ingress proxy — identity extraction + tracing |
| `workloads` | Agents (chat, read, summary, sales), mock-database, lineage-service |
| `observability` | OTel Collector, trace backend |

## License

Apache-2.0
