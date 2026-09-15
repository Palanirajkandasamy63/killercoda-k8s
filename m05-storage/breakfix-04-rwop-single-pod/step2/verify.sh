#!/bin/bash
# Checks: cdr-data is Bound with ReadWriteOnce (not RWOP), and every cdr-writer
# replica the Deployment wants is Ready — i.e. the access mode now matches how the
# workload uses the volume. Asserts the outcome, not a specific command path.
MODES=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null)
if [ -z "$MODES" ]; then
  echo "No cdr-data claim in cdr-storage. Recreate it with ReadWriteOnce:" >&2
  echo "  kubectl apply -f - <<'YAML'" >&2
  echo "  apiVersion: v1" >&2
  echo "  kind: PersistentVolumeClaim" >&2
  echo "  metadata: { name: cdr-data, namespace: cdr-storage }" >&2
  echo "  spec: { accessModes: [ReadWriteOnce], storageClassName: local-path, resources: { requests: { storage: 1Gi } } }" >&2
  echo "  YAML" >&2
  exit 1
fi
if [ "$MODES" = "ReadWriteOncePod" ]; then
  echo "cdr-data is still ReadWriteOncePod, which permits one Pod cluster-wide. accessModes is immutable — scale cdr-writer to 0, delete the claim, and recreate it with ReadWriteOnce." >&2
  exit 1
fi
STATUS=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$STATUS" != "Bound" ]; then
  echo "cdr-data is $STATUS, not Bound. With WaitForFirstConsumer it binds when a Pod consumes it: kubectl scale deployment cdr-writer -n cdr-storage --replicas=2" >&2
  exit 1
fi
PENDING=$(kubectl get pods -n cdr-storage -l app=cdr-writer \
  --field-selector=status.phase=Pending -o name 2>/dev/null | grep -c .)
if [ "$PENDING" -gt 0 ]; then
  echo "$PENDING cdr-writer replica(s) still Pending. Read the FailedScheduling event: kubectl describe pod -n cdr-storage -l app=cdr-writer" >&2
  exit 1
fi
DESIRED=$(kubectl get deploy cdr-writer -n cdr-storage -o jsonpath='{.spec.replicas}' 2>/dev/null)
READY=$(kubectl get deploy cdr-writer -n cdr-storage -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
READY=${READY:-0}
if [ -z "$DESIRED" ] || [ "$READY" -lt 1 ] || [ "$READY" != "$DESIRED" ]; then
  echo "cdr-writer has $READY/$DESIRED replicas Ready. Give the rollout a few seconds: kubectl rollout status deployment cdr-writer -n cdr-storage --timeout=90s" >&2
  exit 1
fi
echo "✓ cdr-data is Bound as $MODES, and cdr-writer runs $READY/$DESIRED replicas sharing it on one node"
exit 0
