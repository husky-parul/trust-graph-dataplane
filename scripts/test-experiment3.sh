#!/bin/bash
# Test the Trust DAG, Explain, and Trust Chain endpoints (Experiment 3)

set -e

INGRESS_URL="${INGRESS_URL:-http://localhost:8080}"

echo "=== Trust Graph Experiment 3: DAG + Explain + Trust Chain ==="
echo ""

# Step 1: Generate a multi-agent trace
echo "1. Generating multi-agent trace..."
echo '   POST /chat {"prompt": "show me sales and employee summary"}'
curl -s -X POST -H "x-principal-id: claude" -H "Content-Type: application/json" \
  -d '{"prompt": "show me sales and employee summary"}' \
  "${INGRESS_URL}/chat" | python3 -c "
import json, sys
d = json.load(sys.stdin)
agents = d.get('agents_called', [])
print(f'   Called {len(agents)} agents: {agents}')
"

echo ""
sleep 5  # Wait for traces to propagate to Jaeger

# Step 2: Get the latest run_id
echo "2. Getting latest run_id..."
RUN_ID=$(curl -s "${INGRESS_URL}/lineage/all" | python3 -c "
import json, sys
d = json.load(sys.stdin)
runs = [r for r in d.get('runs', []) if r.get('principal') == 'claude']
if runs:
    print(runs[0]['run_id'])
else:
    print('NONE')
")

if [ "$RUN_ID" = "NONE" ]; then
    echo "   ERROR: No runs found with principal=claude"
    exit 1
fi
echo "   Run ID: $RUN_ID"
echo ""

# Step 3: Test DAG endpoint
echo "3. Testing DAG endpoint (/dag?format=json)..."
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/dag?format=json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
s = d.get('summary', {})
print(f'   Nodes: {s.get(\"total_nodes\",\"?\")} ({s.get(\"principals\",0)} principals, {s.get(\"agents\",0)} agents, {s.get(\"resources\",0)} resources)')
print(f'   Edges: {s.get(\"total_edges\",\"?\")}')
for e in d.get('edges', []):
    print(f'     {e[\"source\"]} -> {e[\"target\"]} (count={e[\"count\"]}, logical={e[\"logical_count\"]})')
"

echo ""

# Step 4: Test DAG DOT format
echo "4. Testing DAG DOT format..."
DOT=$(curl -s "${INGRESS_URL}/lineage/${RUN_ID}/dag?format=dot")
NODE_COUNT=$(echo "$DOT" | grep -c '\[label=' || true)
EDGE_COUNT=$(echo "$DOT" | grep -c ' -> ' || true)
echo "   DOT output: ${NODE_COUNT} nodes, ${EDGE_COUNT} edges"

echo ""

# Step 5: Test Explain endpoint
echo "5. Testing Explain endpoint (?node=resource:mock-database)..."
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/explain?node=resource:mock-database&format=json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
causes = d.get('cause_groups', [])
print(f'   Question: {d.get(\"question\",\"?\")}')
print(f'   Cause groups: {len(causes)}')
for i, c in enumerate(causes, 1):
    path = ' -> '.join(c.get('full_path', []))
    print(f'     {i}. {path} (spans={c.get(\"span_count\",\"?\")}, duration={c.get(\"total_duration_us\",\"?\")}us)')
parallel = d.get('parallel_groups', [])
if parallel:
    for g in parallel:
        indices = [str(i+1) for i in g.get('cause_indices', [])]
        print(f'   Parallel: causes {', '.join(indices)}')
"

echo ""

# Step 6: Test Trust Chain endpoint
echo "6. Testing Trust Chain endpoint (/trust)..."
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/trust?format=json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'   Type: {d.get(\"type\",\"?\")}')
print(f'   Total events: {d.get(\"total_events\",\"?\")}')
print(f'   Agents: {d.get(\"agents_involved\",[])}')
print(f'   Resources: {d.get(\"resources_accessed\",[])}')
for step in d.get('trust_chain', []):
    path = step.get('causal_path', [])
    via = f'  via: {\" -> \".join(path)}' if len(path) > 2 else ''
    print(f'     {step[\"step\"]}. [{step[\"hop_kind\"]}] {step[\"source\"]} -> {step[\"target\"]} ({step.get(\"span_duration_us\",\"?\")}us){via}')
"

echo ""

# Step 7: Test text formats
echo "7. Testing text formats..."
echo "   --- Explain (text) ---"
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/explain?node=resource:mock-database&format=text" | head -25

echo ""
echo "   --- Trust Chain (text) ---"
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/trust?format=text" | head -25

echo ""
echo "=== Experiment 3 Tests Complete ==="
echo ""
echo "Endpoints tested:"
echo "  /lineage/{run_id}/dag?format=json|dot"
echo "  /lineage/{run_id}/explain?node=...&format=json|text"
echo "  /lineage/{run_id}/trust?format=json|text"
