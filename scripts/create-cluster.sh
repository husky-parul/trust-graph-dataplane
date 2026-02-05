#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-trust-graph}"

# Check for required dependencies
check_dependency() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: '$1' is not installed."
        echo ""
        case "$1" in
            kind)
                echo "Install kind:"
                echo "  Linux:   curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64 && chmod +x ./kind && sudo mv ./kind /usr/local/bin/"
                echo "  macOS:   brew install kind"
                echo "  Go:      go install sigs.k8s.io/kind@v0.22.0"
                ;;
            kubectl)
                echo "Install kubectl:"
                echo "  Linux:   curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
                echo "  macOS:   brew install kubectl"
                ;;
            docker)
                echo "Install Docker: https://docs.docker.com/get-docker/"
                ;;
        esac
        exit 1
    fi
}

check_dependency kind
check_dependency kubectl

# Check for container runtime (Docker or Podman)
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    echo "Using Docker as container runtime"
elif command -v podman &>/dev/null; then
    echo "Using Podman as container runtime"
    export KIND_EXPERIMENTAL_PROVIDER=podman
    # Ensure podman socket is available for kind
    if ! podman info &>/dev/null 2>&1; then
        echo "Error: Podman is not running properly."
        exit 1
    fi
else
    echo "Error: No container runtime found."
    echo "Please install Docker or Podman."
    echo "  Docker: https://docs.docker.com/get-docker/"
    echo "  Podman: https://podman.io/getting-started/installation"
    exit 1
fi

echo "Creating kind cluster: ${CLUSTER_NAME}"

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster '${CLUSTER_NAME}' already exists. Delete it first with: kind delete cluster --name ${CLUSTER_NAME}"
    exit 1
fi

# Create cluster with port mappings for ingress
kind create cluster --name "${CLUSTER_NAME}" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
      - containerPort: 30443
        hostPort: 8443
        protocol: TCP
      - containerPort: 30686
        hostPort: 16686
        protocol: TCP
EOF

echo "Cluster '${CLUSTER_NAME}' created successfully"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
