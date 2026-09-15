#!/bin/bash
# Checks: the two standalone fleet claims (cdr-data, directory-data) are Bound,
# so the healthy chain the scenarios break is in place. Defensive baseline check.
for pair in "cdr-data:cdr-storage" "directory-data:app-services"; do
  PVC="${pair%%:*}"; NS="${pair##*:}"
  STATUS=$(kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$STATUS" != "Bound" ]; then
    echo "$PVC in $NS is not Bound yet (status '$STATUS'). Wait for the fleet to finish coming up and retry." >&2
    exit 1
  fi
done
echo "✓ cdr-data and directory-data are both Bound — the healthy storage chain is in place"
exit 0
