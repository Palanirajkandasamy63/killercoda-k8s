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

`-l app=directory` matches both replicas, and its `Events:` block belongs to whichever Pod `describe` prints — not necessarily the stuck one. Name the Pending replica directly:

```bash
kubectl describe pod -n app-services $(kubectl get pods -n app-services -l app=directory --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
```{{exec}}

The `FailedScheduling` message names it:

```
0/2 nodes are available: 1 node(s) didn't match PersistentVolume's node affinity, 1 node(s) didn't match pod anti-affinity rules.
```

Two nodes, two different disqualifying reasons: one node fails because the other replica already sits there (anti-affinity, mechanics are M06), the other fails because it is not the node `directory-data` is pinned to. The second clause is the one this scenario is about — `directory-data` is ReadWriteOnce, and an RWO volume cannot be attached on a second node.

## See where the volume is pinned

```bash
PV=$(kubectl get pvc directory-data -n app-services -o jsonpath='{.spec.volumeName}')
kubectl describe pv "$PV"
```{{exec}}

Read `Node Affinity:` and compare it with the `NODE` column above. The volume is tied to the node running the healthy replica. That is ReadWriteOnce doing exactly what it promises: one node at a time. On a cloud block volume the same conflict reads `Multi-Attach error` instead — same rule, different words.

The volume is not broken. One RWO volume is being asked to serve two nodes. On to the fix.
