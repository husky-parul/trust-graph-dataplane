#!/bin/bash
set -euo pipefail

echo "=== Verifying Trust Graph Deployment ==="
echo ""

echo "--- Namespaces ---"
kubectl get namespaces | grep -E "ingress-gateway|workloads|observability" || echo "No trust-graph namespaces found"
echo ""

echo "--- Pods ---"
for ns in ingress-gateway workloads observability; do
    if kubectl get namespace "$ns" &>/dev/null; then
        echo "Namespace: $ns"
        kubectl get pods -n "$ns" -o wide 2>/dev/null || echo "  No pods"
        echo ""
    fi
done

echo "--- PVC ---"
kubectl get pvc -n workloads 2>/dev/null || echo "  No PVCs"
echo ""

echo "--- Services ---"
for ns in ingress-gateway workloads observability; do
    if kubectl get namespace "$ns" &>/dev/null; then
        echo "Namespace: $ns"
        kubectl get svc -n "$ns" 2>/dev/null || echo "  No services"
        echo ""
    fi
done

echo "--- Connectivity Tests ---"

echo -n "Jaeger UI (localhost:16686): "
if curl -s -o /dev/null -w "%{http_code}" http://localhost:16686 2>/dev/null | grep -q "200"; then
    echo "OK"
else
    echo "NOT REACHABLE (run: kubectl port-forward -n observability svc/jaeger 16686:16686 &)"
fi

echo -n "Envoy Ingress (localhost:8080): "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/lineage/all 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "OK"
else
    echo "NOT REACHABLE (run: kubectl port-forward -n ingress-gateway svc/envoy-ingress 8080:8080 &)"
fi

echo ""
echo "--- Endpoint Tests ---"

echo -n "Lineage service (/lineage/all): "
RESULT=$(curl -s http://localhost:8080/lineage/all 2>/dev/null)
if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'OK - {d[\"total_runs\"]} runs')" 2>/dev/null; then
    true
else
    echo "FAILED"
fi

echo -n "Chat agent (/chat): "
RESULT=$(curl -s -X POST -H "x-principal-id: test" -H "Content-Type: application/json" \
  -d '{"prompt": "list employees"}' http://localhost:8080/chat 2>/dev/null)
if echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'OK - called {len(d.get(\"agents_called\",[]))} agent(s)')" 2>/dev/null; then
    true
else
    echo "FAILED"
fi

echo -n "SQLite database: "
POD=$(kubectl get pods -n workloads -l app=lineage-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD" ]; then
    TABLE_COUNT=$(kubectl exec "$POD" -n workloads -- python3 -c "
import sqlite3
conn = sqlite3.connect('/data/lineage.db')
tables = conn.execute(\"SELECT count(*) FROM sqlite_master WHERE type='table'\").fetchone()[0]
print(tables)
conn.close()
" 2>/dev/null)
    if [ "$TABLE_COUNT" = "6" ]; then
        echo "OK - 6 tables"
    else
        echo "ISSUE - found $TABLE_COUNT tables (expected 6)"
    fi
else
    echo "FAILED - lineage-service pod not found"
fi

echo -n "Agent cards (/agent-cards): "
CARDS_RESULT=$(curl -s http://localhost:8080/agent-cards 2>/dev/null)
if echo "$CARDS_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'OK - {d[\"total\"]} cards')" 2>/dev/null; then
    true
else
    echo "FAILED"
fi

echo -n "Assessment endpoint: "
# Get any run_id to test
RUN_ID=$(curl -s http://localhost:8080/lineage/all 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
runs = [r['run_id'] for r in d.get('runs',[]) if r.get('total_spans',0) > 3]
print(runs[0] if runs else '')
" 2>/dev/null)
if [ -n "$RUN_ID" ]; then
    ASSESS_RESULT=$(curl -s "http://localhost:8080/lineage/${RUN_ID}/assess" 2>/dev/null)
    if echo "$ASSESS_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'OK - verdict={d[\"verdict\"]}, score={d[\"risk_score\"]}')" 2>/dev/null; then
        true
    else
        echo "FAILED"
    fi
else
    echo "SKIPPED (no runs with spans > 3)"
fi

echo ""
echo "=== Verification Complete ==="
