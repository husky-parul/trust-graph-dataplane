# Experiment 2: Multi-Agent Chat Router with Sales Data

## Overview

This experiment extends the trust graph with:
1. **Sales table** in mock-database linked to employees by `employee_id`
2. **sales-agent** - queries sales data from the database
3. **chat-agent** - router/orchestrator that routes prompts to appropriate agents
4. **A2A agent cards** - metadata files describing each agent's capabilities

## Architecture

```
                           ┌─────────────────┐
                           │   Principal     │
                           │   (claude)      │
                           └────────┬────────┘
                                    │
                                    ▼
                           ┌─────────────────┐
                           │ Ingress Gateway │
                           │    (Envoy)      │
                           └────────┬────────┘
                                    │
                                    ▼
                           ┌─────────────────┐
                           │   chat-agent    │
                           │   (router)      │
                           └────────┬────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              │                     │                     │
              ▼                     ▼                     ▼
     ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
     │   sales-agent   │   │   read-agent    │   │  summary-agent  │
     └────────┬────────┘   └────────┬────────┘   └────────┬────────┘
              │                     │                     │
              │                     │                     ▼
              │                     │            ┌─────────────────┐
              │                     │            │   read-agent    │
              │                     │            └────────┬────────┘
              │                     │                     │
              └─────────────────────┴─────────────────────┘
                                    │
                                    ▼
                           ┌─────────────────┐
                           │  mock-database  │
                           │   (resource)    │
                           └─────────────────┘
```

## Data Schema

### Employees Table
```json
[
  {"id": 1, "name": "Alice", "salary": 75000},
  {"id": 2, "name": "Bob", "salary": 82000},
  {"id": 3, "name": "Charlie", "salary": 69000}
]
```

### Sales Table (NEW)
```json
[
  {"id": 1, "employee_id": 1, "amount": 15000, "product": "Widget Pro", "date": "2024-01-15"},
  {"id": 2, "employee_id": 1, "amount": 22000, "product": "Enterprise Suite", "date": "2024-01-20"},
  {"id": 3, "employee_id": 2, "amount": 8500, "product": "Widget Basic", "date": "2024-01-18"},
  {"id": 4, "employee_id": 2, "amount": 31000, "product": "Enterprise Suite", "date": "2024-02-01"},
  {"id": 5, "employee_id": 3, "amount": 12000, "product": "Widget Pro", "date": "2024-01-25"},
  {"id": 6, "employee_id": 3, "amount": 9500, "product": "Widget Basic", "date": "2024-02-05"}
]
```

## Agents

### chat-agent (Router/Orchestrator)
- **Endpoint**: `POST /chat`
- **Input**: `{"prompt": "your query"}`
- **Routing Logic**: Keyword-based matching
  - `sales|revenue|deal|sold` → sales-agent
  - `employee|read|list|who|staff` → read-agent
  - `summary|salary|average|total|payroll` → summary-agent
- **Multi-agent**: Can call multiple agents in one request

### sales-agent
- **Endpoint**: `GET /sales/all` - all sales records
- **Endpoint**: `GET /sales/employee/{id}` - sales by employee
- **Downstream**: mock-database

### read-agent
- **Endpoint**: `GET /read/employees` - all employees
- **Downstream**: mock-database

### summary-agent
- **Endpoint**: `GET /summary/salaries` - salary statistics
- **Downstream**: read-agent

## Agent Cards (A2A)

Located in `k8s/workloads/agent-cards/`:
- `read-agent-card.json`
- `summary-agent-card.json`
- `sales-agent-card.json`
- `chat-agent-card.json`

Each card contains:
- Name, version, description
- Capabilities
- Endpoints and operations
- Dependencies (downstream agents/resources)
- Trust metadata

## Trust Lineage

### Example: Multi-agent query

Prompt: `"Show me all employees and their sales with salary summary"`

Expected lineage:
```
principal:claude
  └─▶ agent:chat-agent (principal_to_agent)
        ├─▶ agent:sales-agent (agent_to_agent)
        │     └─▶ resource:mock-database (agent_to_resource)
        ├─▶ agent:read-agent (agent_to_agent)
        │     └─▶ resource:mock-database (agent_to_resource)
        └─▶ agent:summary-agent (agent_to_agent)
              └─▶ agent:read-agent (agent_to_agent)
                    └─▶ resource:mock-database (agent_to_resource)
```

## Deployment

```bash
# Apply all resources
kubectl apply -f k8s/workloads/mock-database.yaml
kubectl apply -f k8s/workloads/envoy-sidecar-config.yaml
kubectl apply -f k8s/workloads/sales-agent.yaml
kubectl apply -f k8s/workloads/chat-agent.yaml
kubectl apply -f k8s/ingress-gateway/envoy-config.yaml

# Restart deployments to pick up config changes
kubectl rollout restart deployment -n workloads
kubectl rollout restart deployment envoy-gateway -n ingress-gateway

# Wait for pods
kubectl get pods -n workloads -w
```

## Testing

```bash
# Run test script
./scripts/test-experiment2.sh

# Or test manually:

# Single agent - sales
curl -X POST -H "x-principal-id: claude" -H "Content-Type: application/json" \
  -d '{"prompt": "Show me sales data"}' \
  http://localhost:8080/chat

# Multi-agent query
curl -X POST -H "x-principal-id: claude" -H "Content-Type: application/json" \
  -d '{"prompt": "Show employees and their sales with salary summary"}' \
  http://localhost:8080/chat

# Check lineage
curl http://localhost:8080/lineage/all?format=text
```

## Verification

1. **Jaeger UI**: http://localhost:16686
   - Search for service `envoy-ingress`
   - Look for traces with `trust.lineage=true` tag
   - Verify multi-hop spans with proper trust.* attributes

2. **Lineage Service**:
   ```bash
   curl http://localhost:8080/lineage/all?format=text
   curl http://localhost:8080/lineage/<run_id>?format=text
   ```
