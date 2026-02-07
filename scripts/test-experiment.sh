#!/bin/bash
# Test Experiment 1: Basic multi-agent trust lineage with sidecar proxies

set -e

INGRESS_URL="${INGRESS_URL:-http://localhost:8080}"

echo "=== Trust Graph Experiment 1: Multi-Agent Trust Lineage ==="
echo ""

echo "1. Testing salary summary (full chain: claude -> summary-agent -> read-agent -> mock-database)..."
curl -s -H "x-principal-id: claude" "${INGRESS_URL}/summary/salaries" | python3 -m json.tool

echo ""
sleep 2

echo "2. Checking lineage runs..."
curl -s "${INGRESS_URL}/lineage/all?format=text"

echo ""
echo "3. Check Jaeger UI for trace lineage:"
echo "   http://localhost:16686"
echo ""
echo "   Look for spans showing:"
echo "   - trust.principal_id: user:claude"
echo "   - trust.hop_kind: principal_to_agent -> agent_to_agent -> agent_to_resource"
