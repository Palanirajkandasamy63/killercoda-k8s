# Step 2 — Fix it and verify

`cdr-writer` legitimately runs two Pods on one node, so the claim needs `ReadWriteOnce`. Read the warning before you start: an access mode cannot be edited, and this class destroys data on delete. On a claim holding records this procedure is a data migration, not a one-liner. This claim never took a write, so it is safe here.

## Confirm the field is immutable

```bash
kubectl patch pvc cdr-data -n cdr-storage -p '{"spec":{"accessModes":["ReadWriteOnce"]}}'
```{{exec}}

Rejected: a claim's spec is immutable after creation, apart from its storage request. Changing an access mode means delete and recreate, the same constraint `storageClassName` carries in break/fix 01.

## Watch in-use protection hold the delete

Delete the claim while a Pod still uses it:

```bash
kubectl delete pvc cdr-data -n cdr-storage --wait=false
kubectl get pvc -n cdr-storage
```{{exec}}

`STATUS` reads Terminating, and it stays there. This is **Storage Object in Use Protection**: a `kubernetes.io/pvc-protection` finalizer postpones the removal while any Pod references the claim. See the finalizer and the deletion timestamp:

```bash
kubectl get pvc cdr-data -n cdr-storage -o yaml
```{{exec}}

Read `finalizers:` and `deletionTimestamp:` under `metadata:`. Kubernetes has accepted the delete and is refusing to act on it. Nothing is stuck in the usual sense — it is waiting for the consumer.

## Remove the consumer, then recreate the claim

```bash
kubectl scale deployment cdr-writer -n cdr-storage --replicas=0
kubectl get pvc -n cdr-storage
```{{exec}}

The claim is gone the moment the last referencing Pod disappears. Recreate it with the access mode the workload needs:

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: cdr-data, namespace: cdr-storage }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 1Gi } }
YAML
kubectl scale deployment cdr-writer -n cdr-storage --replicas=2
```{{exec}}

## Verify

```bash
kubectl rollout status deployment cdr-writer -n cdr-storage --timeout=90s
kubectl get pods -n cdr-storage -o wide
kubectl get pvc cdr-data -n cdr-storage
```{{exec}}

Both replicas are Running and Ready on the same node, and `cdr-data` is Bound with `ACCESS MODES` reading RWO. Two Pods now share one volume, which is exactly what ReadWriteOnce permits.

## Choosing the mode

Restoring RWO is right here, because these Pods share a node and share data by design. Pick the mode from how the workload actually uses the volume. Use RWOP when a volume must never have two writers, such as a single-writer database, and accept that it caps the workload at one Pod. Use RWX on network file storage when Pods on several nodes must write one volume. Use `volumeClaimTemplates` in a StatefulSet (M07) when each replica needs its own volume instead of a shared one.

For self-grading, see [`ANSWER-KEY.md`](../ANSWER-KEY.md). You are done — see `finish.md`.
