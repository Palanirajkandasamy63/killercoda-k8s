# Step 2 — Fix it and verify

The claim needs the real class, `local-path`. Read the constraint first: **`storageClassName` is immutable**, so you cannot edit it on an existing claim. Try it and the API refuses:

```bash
kubectl patch pvc cdr-data -n cdr-storage -p '{"spec":{"storageClassName":"local-path"}}'
```{{exec}}

Rejected — the field is immutable. Changing a class means delete and recreate. That is safe here, because the claim never bound and holds no data. A Pod references the claim, so remove the consumer first and the delete will not wait on it:

```bash
kubectl scale deployment cdr-writer -n cdr-storage --replicas=0
kubectl delete pvc cdr-data -n cdr-storage
```{{exec}}

Recreate the claim with the correct class:

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
```{{exec}}

Bring the workload back. Its Pod is the first consumer, so `WaitForFirstConsumer` binds the volume as the Pod schedules:

```bash
kubectl scale deployment cdr-writer -n cdr-storage --replicas=1
```{{exec}}

## Verify

```bash
kubectl get pvc cdr-data -n cdr-storage
kubectl wait --for=condition=Ready pod -l app=cdr-writer -n cdr-storage --timeout=60s
kubectl get pods -n cdr-storage
```{{exec}}

`cdr-data` is Bound to a `local-path` volume, and `cdr-writer` is Running and Ready. The volume was provisioned the moment a Pod consumed the claim.

For self-grading and the full differential, see [`ANSWER-KEY.md`](../ANSWER-KEY.md). You are done — see `finish.md`.
