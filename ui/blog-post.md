## Trust Graph: Capturing Agent Delegation Lineage with Envoy and OpenTelemetry

### The problem

In agent-based systems, a single user request can fan out across multiple agents before touching a resource. A user asks a question, `chat-agent` routes it to `sales-agent`, `read-agent`, and `summary-agent`, each of which queries `mock-database`. Traditional distributed tracing captures latency and errors across these hops — but it doesn't capture **who authorized what**. The delegation chain across trust boundaries is invisible.

We wanted to answer: *who caused this database access, and on whose behalf?* — without touching application code.

### The approach

Every agent runs with an Envoy sidecar. The sidecars — not the agents — emit spans tagged with trust metadata. The agent process never sees these tags and cannot tamper with them.

At the ingress gateway (`envoy-ingress`), a Lua filter extracts the caller identity and stamps it onto the request:

```lua
-- k8s/ingress-gateway/envoy-config.yaml
local trust_principal = "user:" .. principal
request_handle:headers():add("x-trust-principal-id", trust_principal)
request_handle:headers():add("x-caller-type", "principal")
request_handle:headers():add("x-caller-id", trust_principal)
```

Each sidecar (e.g. `envoy-sidecar-summary-agent`) then emits Zipkin spans with five custom tags:

```yaml
# k8s/workloads/envoy-sidecar-config.yaml
custom_tags:
  - tag: trust.source
    request_header: { name: x-caller-id }
  - tag: trust.target
    literal: { value: "agent:summary-agent" }
  - tag: trust.hop_kind
    request_header: { name: x-trust-hop-kind }
  - tag: trust.run_id
    request_header: { name: x-request-id }
  - tag: trust.principal_id
    request_header: { name: x-principal-id }
```

These spans flow through the OTel Collector (`otel-collector.yaml`) into Jaeger. Each Envoy listener creates independent traces — there are no parent-child references across services. Everything is correlated by `trust.run_id`.

### Reconstructing the DAG

A `lineage-service` reads spans from Jaeger and reconstructs the Trust DAG using **temporal backtracking**: for each span, find the most recent inbound span whose `trust.target` matches the current actor, before the current timestamp. This rebuilds the causal chain without requiring parent-child span references.

The result is a typed graph:
```
user:alice → agent:chat-agent → agent:sales-agent → resource:mock-database
                               → agent:read-agent  → resource:mock-database
                               → agent:summary-agent → agent:read-agent → resource:mock-database
```

Nodes are typed (`principal`, `agent`, `resource`). Edges carry `hop_kind`, call count, span IDs, and timestamps. The DAG is ingested into SQLite for fast repeat queries.

### What the lineage service computes

**Explain** (`/lineage/{run_id}/explain?node=resource:mock-database`) — answers "why was this resource accessed?" with full delegation chains back to the principal, parallel execution detection, and per-span attribution.

**Assess** (`/lineage/{run_id}/assess`) — scores each run against a learned baseline from prior runs. Six rules: novel edge (15pts), novel resource access (20pts), depth exceeded (10pts), fanout exceeded (10pts), retry storm (15pts), novel path (10pts). Verdict thresholds: ok (0-25), warn (26-60), high (61-100).

**Capability alignment** — agent cards declare their dependencies (e.g. `read-agent` declares `["resource:mock-database"]`). The assess endpoint compares observed edges against declared dependencies and flags overreach.

### The stack

All running in a `kind` cluster with three namespaces:

| Namespace | Components |
|-----------|-----------|
| `ingress-gateway` | `envoy-ingress` — Lua filter + Zipkin tracing |
| `workloads` | `chat-agent`, `read-agent`, `summary-agent`, `sales-agent`, `mock-database`, `lineage-service` — each agent has an Envoy sidecar |
| `observability` | `otel-collector`, `jaeger` |

No SDKs. No agent code changes. The agents are plain Python HTTP servers that know nothing about tracing. The entire trust graph is captured at the infrastructure layer.

### Key design decision

Envoy sidecars create independent traces per listener — there are no parent-child references across services. We deliberately chose **not** to propagate trace context between agents. Instead, all spans share a `trust.run_id` and the lineage service reconstructs causality after the fact. This means the observation layer is fully decoupled from the application layer. Agents cannot forge, drop, or alter their lineage.
