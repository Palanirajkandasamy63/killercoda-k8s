# Step 5 — The get pvc triage

A Pod stuck on storage sits in Pending or ContainerCreating and logs nothing, because its container never ran. The fault is in a claim or a volume the Pod never names in its own events. One command is the first look, and it splits the failure three ways.

## The first-look command

```bash
kubectl get pvc -A
```{{exec}}

The `STATUS` column is the diagnosis. Three readings, three different problems:

- **Bound** — the claim has its volume. Storage delivered; if the Pod is still stuck, the volume is refusing that Pod.
- **Pending** — the claim cannot get a volume. A missing class, or no volume that matches. Healthy when no Pod uses the claim yet.
- **the claim you expected is not listed** — the Pod names a claim that does not exist in this namespace. A typo, or the claim lives elsewhere.

That is the whole differential. `kubectl get pvc` is to storage what `kubectl get endpoints` was to Services in M04: the Pod's status says it is stuck, and the claim says why.

## Follow the chain from the Pod's side

```bash
POD=$(kubectl get pods -n cdr-storage -l app=cdr-writer -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod "$POD" -n cdr-storage
```{{exec}}

In the `Volumes:` block, the volume's type is `PersistentVolumeClaim` and its `ClaimName:` is `cdr-data`. That name is the only storage reference the Pod holds. Everything else — the volume, the class, the directory on disk — hangs off the claim. Follow it:

```bash
kubectl get pvc cdr-data -n cdr-storage
kubectl get pv
```{{exec}}

Pod → `claimName` → claim → class → volume → a directory on a node.

## What a delete would do

```bash
kubectl get storageclass local-path -o yaml
```{{exec}}

Read `reclaimPolicy: Delete`. On this class, deleting a bound claim destroys the volume and its data. A class set to `Retain` keeps the volume instead, moving it to Released for a human to recover. Two rules follow: `kubectl delete pvc` is a data-destruction command on a Delete-policy class, and in-use protection will hold the claim in Terminating while any Pod still references it.

That is the healthy chain. Each break/fix scenario snaps exactly one link — see `finish.md` for the order.
