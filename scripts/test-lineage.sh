#!/bin/bash
set -euo pipefail

INGRESS_URL="${INGRESS_URL:-http://localhost:8080}"
PRINCIPAL="${1:-user-alice}"

echo "=== Trust Graph Lineage Demo ==="
echo ""
echo "Principal: ${PRINCIPAL}"
echo ""

echo "--- Test 1: Single hop (Principal → Ingress → Agent) ---"
echo "curl ${INGRESS_URL}/agent"
curl -s "${INGRESS_URL}/agent" \
    -H "x-principal-id: ${PRINCIPAL}" \
    -H "x-request-id: single-hop-$(date +%s)" | head -c 200
echo ""
echo ""

echo "--- Test 2: Two hops (Principal → Ingress → Caller-Agent) ---"
echo "curl ${INGRESS_URL}/caller"
curl -s "${INGRESS_URL}/caller" \
    -H "x-principal-id: ${PRINCIPAL}" \
    -H "x-request-id: two-hop-$(date +%s)" | head -c 200
echo ""
echo ""

echo "--- Test 3: Full chain (Principal → Ingress → Caller-Agent → Egress → External) ---"
echo "curl ${INGRESS_URL}/chain"
RESPONSE=$(curl -s "${INGRESS_URL}/chain" \
    -H "x-principal-id: ${PRINCIPAL}" \
    -H "x-request-id: full-chain-$(date +%s)" 2>&1 || echo "Request failed - external service may be unreachable")
echo "${RESPONSE}" | head -c 500
echo ""
echo ""

echo "=== Lineage Summary ==="
echo ""
echo "Test 1: Principal(${PRINCIPAL}) → ingress-gateway → agent"
echo "Test 2: Principal(${PRINCIPAL}) → ingress-gateway → caller-agent"
echo "Test 3: Principal(${PRINCIPAL}) → ingress-gateway → caller-agent → egress-gateway → httpbin.org"
echo ""
echo "View traces in Jaeger: http://localhost:16686"
echo "Look for service: envoy-ingress"
