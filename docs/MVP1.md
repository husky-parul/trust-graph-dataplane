# Trust Graph MVP: Zero-instrumentation agent lineage with OpenTelemetry

Implement a complete trust graph system that captures "who acted on behalf
of whom" in multi-agent systems without instrumenting application code.

## Architecture

- Envoy ingress gateway injects trust headers at entry point
- Envoy sidecars on each agent emit spans with trust.* attributes
- OpenTelemetry Collector receives traces and exports to Jaeger
- Lineage service reconstructs trust chains from distributed traces

## Agents

- **chat-agent**: Router/orchestrator with keyword-based multi-agent dispatch
- **summary-agent**: Aggregates salary data (calls read-agent)
- **read-agent**: Reads employee data from database
- **sales-agent**: Queries sales data linked to employees

## Trust Attributes Captured

| Attribute | Description |
|-----------|-------------|
| `trust.principal_id` | Original user/caller identity |
| `trust.run_id` | Request correlation across agents |
| `trust.hop_kind` | `principal_to_agent` \| `agent_to_agent` \| `agent_to_resource` |
| `trust.source` | Caller identity |
| `trust.target` | Callee identity |

## Features

- A2A agent cards (JSON metadata) describing capabilities
- `/lineage/{run_id}` for full debug trace view
- `/lineage/{run_id}/trust` for deduplicated trust graph
- Multi-hop lineage: Principal -> Agent -> Agent -> Resource

## What This Demonstrates

Accountability and provenance in agent-based systems using only infrastructure components:

- **Envoy** - Traffic routing and trace emission
- **OpenTelemetry** - Trace collection and normalization
- **Jaeger** - Trace storage and visualization
- **Kubernetes** - Orchestration and service discovery

No application code instrumentation required.
