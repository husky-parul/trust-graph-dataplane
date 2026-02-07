#!/bin/bash
# Quick smoke test: send a request through ingress and check lineage

set -euo pipefail

INGRESS_URL="${INGRESS_URL:-http://localhost:8080}"

echo "Sending test request through ingress gateway..."
echo ""

echo "--- Multi-agent query ---"
curl -s -X POST -H "x-principal-id: test-user" -H "Content-Type: application/json" \
  -d '{"prompt": "Show me all employees"}' \
  "${INGRESS_URL}/chat" | python3 -m json.tool

echo ""
sleep 2

echo "--- Recent lineage runs ---"
curl -s "${INGRESS_URL}/lineage/all?format=text"

echo ""
echo "Check traces in Jaeger: http://localhost:16686"
