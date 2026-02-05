#!/bin/bash
set -euo pipefail

INGRESS_URL="${INGRESS_URL:-http://localhost:8080}"

echo "Sending test request through ingress gateway..."
echo "URL: ${INGRESS_URL}/agent"
echo ""

curl -v "${INGRESS_URL}/agent" \
    -H "x-principal-id: user-123" \
    -H "x-request-id: test-$(date +%s)"

echo ""
echo ""
echo "Check traces in Jaeger: http://localhost:16686"
