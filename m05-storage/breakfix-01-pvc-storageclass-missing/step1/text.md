# Step 1 — Diagnose the unbound claim

The Pod is Pending with no logs, because its container never ran. It is waiting on storage. Do not look for a crash. Follow the claim.

## Confirm the symptom

```bash
kubectl get pods -n cdr-storage
```{{exec}}

`cdr-writer` is Pending. Read the Pod's own events:

```bash
kubectl describe pod -n cdr-storage -l app=cdr-writer
```{{exec}}

In the `Events:` block, the `FailedScheduling` message reports an **unbound PersistentVolumeClaim**. The Pod cannot be placed, because the volume it needs is not ready. That names the category and points one object over.

## The first look

```bash
kubectl get pvc -n cdr-storage
```{{exec}}

`cdr-data` is Pending, not Bound. A Pod *is* trying to use this claim, which rules out the healthy `WaitForFirstConsumer` case from the baseline. This claim genuinely cannot bind. Ask it why:

```bash
kubectl describe pvc cdr-data -n cdr-storage
```{{exec}}

The Events line at the bottom is explicit:

```
storageclass.storage.k8s.io "fast-ssd" not found
```

The claim asked for a StorageClass named `fast-ssd`. No such class exists, so no provisioner is called, and no volume is ever created.

## Confirm the class is absent

```bash
kubectl get storageclass
```{{exec}}

The only class on this cluster is `local-path`. There is no `fast-ssd` — either a typo, or a class that was never installed. The claim is pinned to a provisioner that does not exist.

On to the fix, which has one catch.
