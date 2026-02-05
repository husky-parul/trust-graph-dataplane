#!/bin/bash
# Test the claude -> summary-agent -> read-agent -> database lineage

echo "=== Trust Graph Experiment: User Claude ==="
echo ""
echo "Flow: claude (user) -> summary-agent -> read-agent -> mock-database"
echo ""

# Test with x-principal-id header identifying the user as "claude"
echo "1. Testing salary summary (full chain)..."
curl -s -H "x-principal-id: claude" http://localhost:8080/summary/salaries | jq .

echo ""
echo "2. Check Jaeger UI for trace lineage:"
echo "   http://localhost:16686"
echo ""
echo "   Look for spans showing:"
echo "   - principal: claude"
echo "   - agent chain: ingress -> summary-agent -> read-agent -> database"
