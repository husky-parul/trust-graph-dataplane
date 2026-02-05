#!/bin/bash
set -euo pipefail

echo "=== Verifying Trust Graph Deployment ==="
echo ""

echo "--- Namespaces ---"
kubectl get namespaces | grep -E "ingress-gateway|workloads|observability|egress-gateway" || echo "No trust-graph namespaces found"
echo ""

echo "--- Pods ---"
for ns in ingress-gateway workloads observability egress-gateway; do
    if kubectl get namespace "$ns" &>/dev/null; then
        echo "Namespace: $ns"
        kubectl get pods -n "$ns" 2>/dev/null || echo "  No pods"
        echo ""
    fi
done

echo "--- Services ---"
for ns in ingress-gateway workloads observability; do
    if kubectl get namespace "$ns" &>/dev/null; then
        echo "Namespace: $ns"
        kubectl get svc -n "$ns" 2>/dev/null || echo "  No services"
        echo ""
    fi
done

echo "--- Connectivity Test ---"
echo "Testing Jaeger UI (localhost:16686)..."
if curl -s -o /dev/null -w "%{http_code}" http://localhost:16686 2>/dev/null | grep -q "200"; then
    echo "  Jaeger UI: OK"
else
    echo "  Jaeger UI: NOT REACHABLE"
fi

echo "Testing Envoy Ingress (localhost:8080)..."
if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null | grep -qE "200|404"; then
    echo "  Envoy Ingress: OK"
else
    echo "  Envoy Ingress: NOT REACHABLE"
fi
