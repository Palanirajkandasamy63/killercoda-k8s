# Step 1 — Diagnose the Bound-but-stuck volume

This time `get pvc` looks fine. That is the point: the claim is Bound and a Pod is still stuck. Read the shape carefully.

## See the split

```bash
kubectl get pods -n app-services -l app=directory -o wide
```{{exec}}

Two replicas: one Running, one Pending. The `NODE` column shows the Running one on a node, and the Pending one with no node. Now check the claim:

```bash
kubectl get pvc -n app-services
```{{exec}}

`directory-data` is Bound. That is the discriminator for the third leaf. The claim is not Pending (break/fix 01) and not absent (break/fix 02). It is healthy, and a Pod is still stuck. When a Bound claim cannot get a Pod running, the problem is exclusivity at **attach**, not binding.

## Read why the stuck replica will not schedule

```bash
kubectl describe pod -n app-services -l app=directory
```{{exec}}

In the Pending Pod's `Events:` block, the `FailedScheduling` message names it:

```
... node(s) had volume node affinity conflict ...
```

`directory-data` is ReadWriteOnce and lives on one node. The stuck replica was pushed to a *different* node, because a scheduling rule forces the two replicas apart (anti-affinity mechanics are M06). An RWO volume cannot be attached on a second node.

## See where the volume is pinned

```bash
PV=$(kubectl get pvc directory-data -n app-services -o jsonpath='{.spec.volumeName}')
kubectl describe pv "$PV"
```{{exec}}

Read `Node Affinity:` and compare it with the `NODE` column above. The volume is tied to the node running the healthy replica. That is ReadWriteOnce doing exactly what it promises: one node at a time. On a cloud block volume the same conflict reads `Multi-Attach error` instead — same rule, different words.

The volume is not broken. One RWO volume is being asked to serve two nodes. On to the fix.
