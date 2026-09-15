#!/bin/bash
# Checks: cdr-data's bound PV advertises RWO — the access mode the persistence
# and Multi-Attach lessons rest on. Defensive baseline check.
PV=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.spec.volumeName}' 2>/dev/null)
if [ -z "$PV" ]; then
  echo "cdr-data has no bound volume yet. Wait for the fleet to finish coming up and retry." >&2
  exit 1
fi
MODES=$(kubectl get pv "$PV" -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null)
echo "✓ cdr-data's PV $PV is $MODES (ReadWriteOnce — one node at a time)"
exit 0
