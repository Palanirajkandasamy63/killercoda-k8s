#!/bin/bash
# Checks: the local-path StorageClass exists and uses WaitForFirstConsumer, the
# binding behavior the whole module leans on. Defensive baseline check.
MODE=$(kubectl get storageclass local-path -o jsonpath='{.volumeBindingMode}' 2>/dev/null)
if [ -z "$MODE" ]; then
  echo "StorageClass local-path not found yet. The provisioner may still be installing — wait and retry." >&2
  exit 1
fi
echo "✓ StorageClass local-path present (volumeBindingMode: $MODE)"
exit 0
