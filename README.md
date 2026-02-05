# Trust Graph with OpenTelemetry

Capture **who acted on behalf of whom** in agent-based systems using infrastructure-only instrumentation.

```
Principal → Agent → (Agent → …) → Resource
```

## Overview

This project demonstrates distributed trust lineage tracking without application code changes. It uses standard infrastructure components to trace execution paths through agent systems.

## Architecture

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────┐     ┌──────────────┐
│   Client    │────▶│  Envoy Ingress  │────▶│    Agent    │────▶│ Envoy Egress │
│ (Principal) │     │    Gateway      │     │  Workload   │     │   Gateway    │
└─────────────┘     └────────┬────────┘     └─────────────┘     └──────┬───────┘
                             │                                         │
                             ▼                                         ▼
                    ┌─────────────────┐                        ┌─────────────┐
                    │     OTel        │                        │  Resource   │
                    │   Collector     │                        │  (External) │
                    └────────┬────────┘                        └─────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │     Jaeger      │
                    │  (Trace Store)  │
                    └─────────────────┘
```

## Components

| Component | Purpose |
|-----------|---------|
| **Envoy Ingress** | Routes traffic, starts traces, emits spans for Principal → Agent hops |
| **OTel Collector** | Central telemetry hub, normalizes and exports traces |
| **Jaeger** | Trace storage, query, and visualization |
| **Agent Service** | Dummy workload for validating the pipeline |
| **Envoy Egress** | (Future) Traces Agent → Resource hops |

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

## Project Structure

```
.
├── k8s/
│   ├── namespaces/          # Namespace definitions
│   ├── ingress-gateway/     # Envoy ingress configuration
│   ├── workloads/           # Agent service deployments
│   ├── observability/       # Jaeger + OTel Collector
│   └── egress-gateway/      # Envoy egress configuration
├── docker/
│   └── agent/               # Dummy agent service Dockerfile
├── scripts/                 # Setup and utility scripts
└── CLAUDE.md               # AI assistant context
```

## Namespace Model

| Namespace | Purpose |
|-----------|---------|
| `ingress-gateway` | Envoy ingress proxy |
| `workloads` | Agent services |
| `observability` | Jaeger + OTel Collector |
| `egress-gateway` | Envoy egress proxy |

## License

MIT
