#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s"

echo "=== Deploying Trust Graph Infrastructure ==="

# Create namespaces first
echo "Creating namespaces..."
kubectl apply -f "${K8S_DIR}/namespaces/"

# Deploy observability stack (Jaeger + OTel Collector)
echo "Deploying observability stack..."
kubectl apply -f "${K8S_DIR}/observability/"

# Wait for observability to be ready
echo "Waiting for Jaeger to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/jaeger -n observability || true

echo "Waiting for OTel Collector to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/otel-collector -n observability || true

# Deploy workloads
echo "Deploying agent workloads..."
kubectl apply -f "${K8S_DIR}/workloads/"

# Wait for workloads
echo "Waiting for agent to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/agent -n workloads || true

# Deploy ingress gateway
echo "Deploying ingress gateway..."
kubectl apply -f "${K8S_DIR}/ingress-gateway/"

# Wait for ingress
echo "Waiting for ingress gateway to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/envoy-ingress -n ingress-gateway || true

echo "=== Deployment Complete ==="
echo ""
echo "Access points:"
echo "  Envoy Ingress: http://localhost:8080"
echo "  Jaeger UI:     http://localhost:16686"
