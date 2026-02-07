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

echo "Waiting for observability to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/jaeger -n observability || true
kubectl wait --for=condition=available --timeout=120s deployment/otel-collector -n observability || true

# Deploy workloads: PVC first (must exist before deployments that reference it)
echo "Deploying PVC..."
kubectl apply -f "${K8S_DIR}/workloads/lineage-pvc.yaml"

echo "Deploying sidecar configs..."
kubectl apply -f "${K8S_DIR}/workloads/envoy-sidecar-config.yaml"

echo "Creating agent-cards ConfigMap..."
kubectl create configmap agent-cards-config \
  --from-file="${K8S_DIR}/workloads/agent-cards/" \
  -n workloads --dry-run=client -o yaml > /tmp/agent-cards-cm.yaml
kubectl apply -f /tmp/agent-cards-cm.yaml

echo "Deploying agent workloads..."
kubectl apply -f "${K8S_DIR}/workloads/mock-database.yaml"
kubectl apply -f "${K8S_DIR}/workloads/read-agent.yaml"
kubectl apply -f "${K8S_DIR}/workloads/summary-agent.yaml"
kubectl apply -f "${K8S_DIR}/workloads/sales-agent.yaml"
kubectl apply -f "${K8S_DIR}/workloads/chat-agent.yaml"
kubectl apply -f "${K8S_DIR}/workloads/lineage-service.yaml"

echo "Waiting for workloads to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment --all -n workloads || true

# Deploy ingress gateway
echo "Deploying ingress gateway..."
kubectl apply -f "${K8S_DIR}/ingress-gateway/"

echo "Waiting for ingress gateway to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/envoy-ingress -n ingress-gateway || true

# Start port-forwarding
echo ""
echo "Starting port-forwards..."
# Kill any existing port-forwards
pkill -f "kubectl port-forward.*8080:8080" 2>/dev/null || true
pkill -f "kubectl port-forward.*16686:16686" 2>/dev/null || true
sleep 1

kubectl port-forward -n ingress-gateway svc/envoy-ingress 8080:8080 &
kubectl port-forward -n observability svc/jaeger 16686:16686 &
sleep 3

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Access points:"
echo "  Envoy Ingress:    http://localhost:8080"
echo "  Jaeger UI:        http://localhost:16686"
echo "  Lineage (all):    http://localhost:8080/lineage/all?format=text"
echo ""
echo "Test with:"
echo "  curl -X POST -H 'x-principal-id: claude' -H 'Content-Type: application/json' \\"
echo "    -d '{\"prompt\": \"show me sales and employee summary\"}' http://localhost:8080/chat"
