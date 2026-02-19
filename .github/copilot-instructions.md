# Trust Graph with OpenTelemetry - AI Coding Agent Instructions

## Project Vision

Capture **who acted on behalf of whom** in multi-agent systems using infrastructure-only telemetry, without instrumenting application code. Build provenance and accountability through distributed trace analysis.

```
Principal → Agent → (Agent → …) → Resource
```

## Architecture Overview

### Components & Responsibilities

| Component | Role | Key Decision |
|-----------|------|--------------|
| **Envoy Ingress** | Entry point; injects trust headers (`x-caller-type: principal`, `x-request-id`, `x-principal-id`); starts traces with `trust.principal_id` and `trust.run_id` | Spans annotated with `trust.hop_kind = principal_to_agent` |
| **Agent Sidecars** | Embedded Envoy proxies on each agent; propagate and transform trust headers on outbound calls | Set `trust.hop_kind = agent_to_agent` or `agent_to_resource`; set `x-caller-type: agent` |
| **OTel Collector** | Central hub; receives traces from all Envoys; normalizes and exports to Jaeger | Runs in `observability` namespace |
| **Jaeger** | Distributed trace storage and visualization | Backend for trace queries and trust DAG reconstruction |
| **Agent Services** | chat-agent (router), read-agent, summary-agent, sales-agent; each runs with sidecar in `workloads` namespace | Keyword-based routing in chat-agent; downstream agents coordinate via trace headers |
| **Lineage Service** | Reconstructs trust DAGs from traces; exposes `/lineage/{run_id}` (full trace) and `/lineage/{run_id}/trust` (deduplicated graph) | Authoritative source for provenance queries |

### Trust Attributes (Span Annotations)

Every span from Envoy includes:

- **`trust.principal_id`** — Original caller (e.g., `user:alice`)
- **`trust.run_id`** — Global request correlation ID across all hops
- **`trust.hop_kind`** — `principal_to_agent` \| `agent_to_agent` \| `agent_to_resource`
- **`trust.source`** — Caller identity (e.g., `principal:alice`, `agent:chat-agent`)
- **`trust.target`** — Callee identity (e.g., `agent:read-agent`, `resource:postgres`)

### Kubernetes Namespace Model

| Namespace | Purpose | Components |
|-----------|---------|------------|
| `ingress-gateway` | Envoy ingress proxy | Ingress Envoy, routes external traffic |
| `workloads` | Agent services and supporting services | chat-agent, read-agent, summary-agent, sales-agent, lineage-service, lineage-ui, mock-database |
| `observability` | Telemetry infrastructure | Jaeger, OTel Collector |
| `egress-gateway` | (Future) Envoy egress for external resources | Not yet implemented |

### Data Flows

1. **Client → Ingress** — Client sends HTTP request; Envoy ingress injects `x-principal-id`, `x-request-id`, `x-caller-type: principal`
2. **Ingress → Agent** — Envoy spans with `trust.hop_kind=principal_to_agent` and `trust.source=principal:*`, `trust.target=agent:*`
3. **Agent → Agent** — Sidecar intercepts outbound call; emits span with `trust.hop_kind=agent_to_agent`; transforms header to `x-caller-type: agent`
4. **Agent → Resource** — (e.g., database) Sidecar emits `trust.hop_kind=agent_to_resource` span
5. **All Traces → OTel Collector** — Collector normalizes, deduplicates, exports to Jaeger
6. **Lineage Service Queries → Jaeger** — Reconstructs DAG for given `trust.run_id`

## Critical Developer Workflows

### Initial Setup

```bash
# Create a local kind cluster with required namespaces
./scripts/create-cluster.sh

# Deploy entire stack: namespaces, observability, workloads, gateways
./scripts/deploy-all.sh

# Verify cluster health and connectivity
./scripts/verify.sh

# Send a test request and inspect lineage
./scripts/test-request.sh
```

### Testing & Debugging

- **Run experiments** — `./scripts/test-experiment.sh`, `test-experiment2.sh`, etc. test specific lineage scenarios
- **Inspect traces** — Port-forward to Jaeger: `kubectl port-forward -n observability svc/jaeger 16686:16686`, visit `http://localhost:16686`
- **Check sidecar injection** — Ensure ConfigMap `envoy-sidecar-config.yaml` is applied to `workloads` namespace
- **Verify agent-cards** — ConfigMap `agent-cards-config` must be created from `k8s/workloads/agent-cards/` JSON files

### Build & Deployment Patterns

- **Agent container image** — Built from `docker/agent/Dockerfile` (a simple Python HTTP server); used for all agent services
- **YAML deployments** — Each agent (`chat-agent.yaml`, `read-agent.yaml`, etc.) is a Deployment + Service in `workloads`
- **Config embedding** — Agent Python logic is embedded in `server.py` ConfigMap within the YAML (not external)
- **Sidecar injection** — Workload Deployments use annotation to inject Envoy sidecar; sidecar config stored in `envoy-sidecar-config.yaml` ConfigMap

## Project Conventions & Patterns

### Trace Analysis Pattern

When working with traces in experiments or lineage reconstruction:

1. **Group by `trust.run_id`** — All spans with the same run_id belong to one logical execution
2. **Order by `trust.hop_kind`** — Establish sequence: `principal_to_agent` first, then `agent_to_agent` hops, finally `agent_to_resource`
3. **Deduplicate by source+target** — Multiple identical calls (e.g., repeated database queries) collapse to one DAG edge with count
4. **Preserve metadata** — Each DAG edge includes span timestamps, span IDs, and hop_kind for auditability

See [experiments/dag/](experiments/dag/) for JSON examples of reconstructed DAGs and trust decisions.

### Header Propagation Convention

- **Ingress** sets initial headers: `x-principal-id`, `x-request-id`, `x-caller-type: principal`
- **Sidecars** read incoming `x-caller-type` to decide hop_kind, then set `x-caller-type: agent` on outbound calls
- **Headers persist** across hops; downstream agents inherit the original `x-principal-id` and `x-request-id`

### Agent Routing Pattern (chat-agent example)

Chat agent routes based on keywords in the request prompt:
- Keywords like "sales", "revenue" → call `sales-agent`
- Keywords like "employee", "list" → call `read-agent`
- Keywords like "summary", "salary" → call `summary-agent`

Each downstream agent call goes through its sidecar, creating a trace hop.

### Agent Card Pattern

Each agent publishes a capability descriptor as JSON in `k8s/workloads/agent-cards/`:

```json
{
  "name": "read-agent",
  "endpoint": "/read/employees",
  "description": "Reads employee records from database"
}
```

Cards are loaded into `agent-cards-config` ConfigMap during deployment; lineage-ui may use them for visualization.

## Integration Points & Dependencies

- **Kubernetes** — Local kind cluster; must have Docker or Podman running
- **Envoy** — Proxy configuration defined in ConfigMaps; no code changes needed
- **OpenTelemetry** — OTLP receiver on collector; Jaeger backend
- **Jaeger** — Trace backend; queried via REST API by lineage-service

## Key Files & Reference Points

| Path | Purpose |
|------|---------|
| [CLAUDE.md](CLAUDE.md) | High-level project context; architecture decisions |
| [MVP1.md](MVP1.md) | Feature list and agent descriptions |
| [k8s/ingress-gateway/](k8s/ingress-gateway/) | Envoy ingress config; defines trust header injection |
| [k8s/workloads/envoy-sidecar-config.yaml](k8s/workloads/envoy-sidecar-config.yaml) | Sidecar proxy config; must be patched when changing hop logic |
| [k8s/workloads/chat-agent.yaml](k8s/workloads/chat-agent.yaml) | Example agent deployment with sidecar + embedded ConfigMap |
| [k8s/observability/](k8s/observability/) | Jaeger + OTel Collector configs |
| [experiments/dag/](experiments/dag/) | Example DAGs and trust decision artifacts (JSON) |
| [scripts/](scripts/) | Automation for cluster setup, testing, verification |

## Gotchas & Important Notes

1. **Order matters in deploy-all.sh** — PVC must be created before agent Deployments (they mount it for lineage data)
2. **Agent cards ConfigMap** — Must be created with `--from-file=` pointing to `agent-cards/` directory; used by lineage-ui
3. **Sidecar injection** — Requires annotation on Deployment spec; config lives in `envoy-sidecar-config.yaml` ConfigMap
4. **Trace correlation** — Every request must carry `x-request-id`; OTel Collector uses it to correlate spans
5. **Future egress gateway** — Egress gateway is scaffolded but not yet integrated; agent → resource hops are currently traced via sidecar, not egress gateway
6. **Trust model** — Current system captures *observed* lineage, not *enforced* authorization; SPIFFE/SVID integration is a future phase
