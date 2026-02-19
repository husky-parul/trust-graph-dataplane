## Trust DAG: A Trust-Aware Data Plane for Agent Delegation Lineage

### The problem

In agent-based systems, a single user request can fan out across multiple agents before touching a resource. A user asks a question, `chat-agent` routes it to `sales-agent`, `read-agent`, and `summary-agent`, each of which queries `mock-database`. Traditional distributed tracing captures latency and errors across these hops — but it doesn't capture **who authorized what**. The delegation chain across trust boundaries is invisible.

We wanted to answer: *who caused this database access, and on whose behalf?* — without touching application code. And we wanted the same infrastructure that observes to be able to enforce.

### What Trust DAG is

Trust DAG is a **trust-aware data plane fabric** for agent-based systems. It does three things:

1. **Observes** — Proxy sidecars on every agent emit trust-tagged spans capturing who called whom, on whose behalf, at every hop
2. **Reconstructs** — A lineage service builds the full delegation DAG, scores runs for novelty, and validates agent behavior against declared capabilities
3. **Enforces** — The same proxy that observes can call out to pluggable policy engines to block high-risk requests

The observation point sits outside the agent's trust boundary. A compromised agent cannot alter its own trace data. Agents that are not instrumented are still fully visible — the surrounding infrastructure captures their delegation lineage regardless.

### The approach

Every agent runs with a proxy sidecar. The sidecars — not the agents — emit spans tagged with trust metadata. The agent process never sees these tags and cannot tamper with them.

At the ingress gateway, a filter extracts the caller identity and stamps it onto the request. In our demo implementation this is a Lua filter on Envoy:

```lua
-- demo: ingress gateway filter
local trust_principal = "user:" .. principal
request_handle:headers():add("x-trust-principal-id", trust_principal)
request_handle:headers():add("x-caller-type", "principal")
request_handle:headers():add("x-caller-id", trust_principal)
```

Each sidecar emits spans with five custom trust tags. In our demo these are configured as Envoy tracing tags exported via OpenTelemetry:

```yaml
# demo: sidecar trust tag configuration
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

These spans flow through a telemetry collector into the trace store. Everything is correlated by `trust.run_id`. The proxy, collector, and backend are all pluggable — Trust DAG depends on the trust tags, not on specific products.

### Reconstructing the DAG

The lineage service reads spans from the trace store and reconstructs the Trust DAG. When parent-child span references are available, it uses them directly. When they are not — for example, when sidecars create independent traces — it falls back to **temporal backtracking**: for each span, find the most recent inbound span whose `trust.target` matches the current actor, before the current timestamp. This rebuilds the causal chain without requiring agent cooperation.

The result is a typed graph:
```
user:alice → agent:chat-agent → agent:sales-agent → resource:mock-database
                               → agent:read-agent  → resource:mock-database
                               → agent:summary-agent → agent:read-agent → resource:mock-database
```

Nodes are typed (`principal`, `agent`, `resource`). Edges carry `hop_kind`, call count, span IDs, and timestamps.

### What the lineage service computes

**Explain** (`/lineage/{run_id}/explain?node=resource:mock-database`) — answers "why was this resource accessed?" with full delegation chains back to the principal, parallel execution detection, and per-span attribution.

**Assess** (`/lineage/{run_id}/assess`) — scores each run against a learned baseline from prior runs. The demo uses six DAG-derived rules: novel edge, novel resource access, depth exceeded, fanout exceeded, retry storm, and novel path. But the scoring framework is extensible — any signal source can contribute. For example, if agent evals are available (output quality, safety violations, hallucination detection), those scores plug in alongside the structural DAG signals. The verdict is a single combined risk score that flows into the policy engine at the enforcement point. The DAG tells you *who did what*. Evals tell you *how well they did it*. Assess combines both.

**Capability alignment** — agent cards declare their dependencies (e.g. `read-agent` declares `["resource:mock-database"]`). The assess endpoint compares observed edges against declared dependencies and flags overreach.

### Enforcement: pluggable policy engines

The same sidecar that emits trust-tagged spans is also the enforcement point, calling out to external policy decision points:

```
Request → Proxy Sidecar (Trust DAG)
              ├── Observe: emit trust-tagged span
              ├── Enforce: call PDP(s) → allow/deny
              │     └── Any policy engine
              └── Record: lineage service reconstructs DAG
```

Trust DAG does not own the policy decision. It owns the proxy, the trust metadata, the lineage reconstruction, and the risk signals. The policy decision is delegated to whatever engine is plugged in.

### The demo stack

The demo runs in a local Kubernetes cluster with three namespaces:

| Namespace | Components |
|-----------|-----------|
| `ingress-gateway` | Ingress proxy — identity extraction + tracing |
| `workloads` | `chat-agent`, `read-agent`, `summary-agent`, `sales-agent`, `mock-database`, `lineage-service` — each agent has a proxy sidecar |
| `observability` | Telemetry collector + trace backend |

No SDKs. No agent code changes. The agents are plain HTTP servers that know nothing about tracing. The entire trust graph is captured at the infrastructure layer. In the long run, infrastructure components — LLM servers, inference runtimes, agent orchestrator platforms — will be instrumented. Agents may or may not be. The system degrades gracefully: instrumented agents give richer context, uninstrumented agents are still fully visible through the surrounding infrastructure spans.

### Composability with trust frameworks

Trust DAG is a standalone system. It captures delegation lineage, produces risk signals, and enforces at the proxy independently. But it is designed to be composable with higher-level trust frameworks that manage identity, policy, and configuration.

For example, a framework that provides operator-managed configuration, OAuth lifecycle, and policy distribution gets these capabilities from Trust DAG without building them:

| Capability | What Trust DAG provides |
|---|---|
| Sidecar enforcement | Proxy sidecars with trust tags at every hop |
| Observability | Sidecars → telemetry collector → any trace backend |
| Connected delegation graph | Full DAG reconstruction across all hops — not just per-hop events |
| Runtime capability validation | Agent cards vs observed behavior, overreach detection |
| Baseline anomaly detection | Novelty scoring against learned history |
| Provenance query | "Why was this resource accessed, by whom, on whose behalf?" |
| Pluggable enforcement | Callout to any policy decision point |

Trust DAG doesn't require a control plane to function. When one is present, it composes cleanly — the control plane distributes policy and configuration, Trust DAG handles observation, lineage, risk signals, and enforcement at the proxy.
