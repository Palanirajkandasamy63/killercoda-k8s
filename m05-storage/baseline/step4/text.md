# Step 4 — Access modes, and data that outlives the Pod

The access mode declares how many places may mount a volume at once. Read it, then prove the data survives the Pod that wrote it.

## Read the access mode

```bash
kubectl get pv
```{{exec}}

The `ACCESS MODES` column reads RWO. There are four modes, and three of them count nodes:

- **ReadWriteOnce (RWO)** — read-write by a single node. Several Pods on that one node may all read and write it.
- **ReadOnlyMany (ROX)** — read-only by many nodes.
- **ReadWriteMany (RWX)** — read-write by many nodes.
- **ReadWriteOncePod (RWOP)** — read-write by a single Pod, anywhere in the cluster.

So "Once" means one node, not one Pod. Only RWOP counts Pods. Break/fix 03 and 04 turn on that difference.

## See where the volume lives

```bash
PV=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.spec.volumeName}')
kubectl describe pv "$PV"
```{{exec}}

Read two parts. `Node Affinity:` pins this volume to the node that holds the directory, because `local-path` storage is a path on one machine's disk. `Status: Bound` and `Claim: cdr-storage/cdr-data` confirm the binding. The volume is not floating in the cluster: it lives on one node, and any Pod that mounts it must run there.

## Write data, then destroy the Pod

`cdr-writer` mounts `cdr-data` at /data. Write a record:

```bash
POD=$(kubectl get pods -n cdr-storage -l app=cdr-writer -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n cdr-storage "$POD" -- sh -c 'echo "cdr-2026-07-01-000042" > /data/record && cat /data/record'
```{{exec}}

Delete the Pod. The Deployment creates a replacement:

```bash
kubectl delete pod -n cdr-storage "$POD"
kubectl wait --for=condition=Ready pod -l app=cdr-writer -n cdr-storage --timeout=60s
```{{exec}}

## Confirm the data survived

```bash
NEWPOD=$(kubectl get pods -n cdr-storage -l app=cdr-writer -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n cdr-storage "$NEWPOD" -- cat /data/record
```{{exec}}

The record is still there: a different Pod, the same volume. The container filesystem went with the old Pod, and so would an `emptyDir` (step 1). The claim's data did not, because it lives in the volume. That is the whole reason PersistentVolumes exist.

Next: the one command that diagnoses this chain when it breaks.
