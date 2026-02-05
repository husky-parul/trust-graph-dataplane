#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-trust-graph}"

echo "Deleting kind cluster: ${CLUSTER_NAME}"
kind delete cluster --name "${CLUSTER_NAME}"
echo "Cluster '${CLUSTER_NAME}' deleted"
