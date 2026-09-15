#!/bin/bash
# Checks: cdr-writer's Pod provides its storage through a PersistentVolumeClaim
# volume, so the learner has a real volumes block to read. Defensive baseline check.
POD=$(kubectl get pods -n cdr-storage -l app=cdr-writer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "No cdr-writer Pod yet. The fleet may still be coming up — wait and retry." >&2
  exit 1
fi
CLAIM=$(kubectl get pod "$POD" -n cdr-storage -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}' 2>/dev/null)
if [ -z "$CLAIM" ]; then
  echo "cdr-writer's Pod has no persistentVolumeClaim volume. Wait for the fleet to finish coming up and retry." >&2
  exit 1
fi
echo "✓ cdr-writer mounts a PersistentVolumeClaim volume (ClaimName: $CLAIM)"
exit 0
