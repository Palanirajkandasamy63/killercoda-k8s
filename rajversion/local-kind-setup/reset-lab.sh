#!/usr/bin/env bash
# Full reset between scenarios: delete and recreate the kind cluster.
# This is the reliable option — some scenarios install cluster-scoped
# things (cert-manager, Kyverno, Istio, Flux) that a namespace-only
# reset won't cleanly undo.
set -euo pipefail
CLUSTER_NAME="${KIND_CLUSTER_NAME:-polyphone-lab}"
CONFIG="${2:-kind-cluster.yaml}"

echo ">>> Deleting kind cluster '$CLUSTER_NAME' (if it exists) ..."
kind delete cluster --name "$CLUSTER_NAME" || true

echo ">>> Creating fresh kind cluster '$CLUSTER_NAME' ..."
kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG"

kubectl config use-context "kind-${CLUSTER_NAME}"
echo ">>> Ready. Now run: ./run-scenario.sh <path-to-scenario>"
