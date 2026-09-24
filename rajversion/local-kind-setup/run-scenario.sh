#!/usr/bin/env bash
# Run one Killercoda "Polyphone" breakfix scenario's background.sh against
# your local kind cluster, then print the scenario's own foreground.sh hint.
#
# Usage:
#   ./run-scenario.sh path/to/scenario-dir
#   e.g. ./run-scenario.sh killercoda-k8s-main/m03-configuration/breakfix-01-configmap-key-missing
#   e.g. ./run-scenario.sh killercoda-k8s-main/m03-configuration/baseline
set -euo pipefail

SCENARIO_DIR="${1:?Usage: $0 path/to/scenario-dir (folder containing background.sh)}"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-polyphone-lab}"

if [ ! -f "$SCENARIO_DIR/background.sh" ]; then
  echo "No background.sh found in $SCENARIO_DIR" >&2
  exit 1
fi

# Safety: refuse to run against anything that isn't the lab kind cluster.
CTX="$(kubectl config current-context 2>/dev/null || true)"
if [ "$CTX" != "kind-${CLUSTER_NAME}" ]; then
  echo "Current kubectl context is '$CTX', expected 'kind-${CLUSTER_NAME}'."
  echo "Run: kubectl config use-context kind-${CLUSTER_NAME}"
  exit 1
fi

echo ">>> Applying $SCENARIO_DIR/background.sh against $CTX ..."
bash "$SCENARIO_DIR/background.sh"

echo
echo ">>> Done. Scenario hint:"
if [ -f "$SCENARIO_DIR/intro.md" ]; then
  echo "---"
  cat "$SCENARIO_DIR/intro.md"
  echo "---"
fi
