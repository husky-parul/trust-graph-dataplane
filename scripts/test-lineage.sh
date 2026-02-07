#!/bin/bash
# Test all lineage endpoints for a given run_id

set -euo pipefail

INGRESS_URL="${INGRESS_URL:-http://localhost:8080}"

# Get run_id from argument or find the latest
if [ $# -ge 1 ]; then
    RUN_ID="$1"
else
    echo "Finding latest run_id..."
    RUN_ID=$(curl -s "${INGRESS_URL}/lineage/all" | python3 -c "
import json, sys
d = json.load(sys.stdin)
runs = d.get('runs', [])
if runs:
    print(runs[0]['run_id'])
else:
    print('NONE')
")
    if [ "$RUN_ID" = "NONE" ]; then
        echo "No runs found. Send a request first:"
        echo "  curl -X POST -H 'x-principal-id: claude' -H 'Content-Type: application/json' \\"
        echo "    -d '{\"prompt\": \"show me sales and employee summary\"}' http://localhost:8080/chat"
        exit 1
    fi
fi

echo "=== Lineage for run_id: ${RUN_ID} ==="
echo ""

echo "--- Debug view (/lineage/{run_id}) ---"
curl -s "${INGRESS_URL}/lineage/${RUN_ID}?format=text" | head -30
echo ""

echo "--- DAG (/lineage/{run_id}/dag) ---"
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/dag?format=json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'error' in d:
    print(f'  Error: {d[\"error\"]}')
else:
    s = d.get('summary', {})
    print(f'  Nodes: {s.get(\"total_nodes\")}, Edges: {s.get(\"total_edges\")}')
    for e in d.get('edges', []):
        print(f'    {e[\"source\"]} -> {e[\"target\"]} (logical={e[\"logical_count\"]}, raw={e[\"count\"]})')
"
echo ""

echo "--- Trust chain (/lineage/{run_id}/trust) ---"
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/trust?format=text"
echo ""

echo "--- Explain: mock-database (/lineage/{run_id}/explain?node=resource:mock-database) ---"
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/explain?node=resource:mock-database&format=text"
echo ""

echo "--- DAG (DOT format) ---"
curl -s "${INGRESS_URL}/lineage/${RUN_ID}/dag?format=dot"
echo ""
