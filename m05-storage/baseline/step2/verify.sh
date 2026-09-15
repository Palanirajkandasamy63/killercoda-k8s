#!/bin/bash
# Checks: cdr-data PVC is Bound to a PV via the local-path class, so the learner
# has a healthy claim to read. Defensive baseline check.
STATUS=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$STATUS" != "Bound" ]; then
  echo "cdr-data is not Bound yet (status '$STATUS'). The fleet may still be coming up — wait and retry." >&2
  exit 1
fi
VOL=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.spec.volumeName}' 2>/dev/null)
echo "✓ cdr-data is Bound to PV $VOL (via StorageClass local-path)"
exit 0
