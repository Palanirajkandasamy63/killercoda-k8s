# Step 2 — Fix it and verify

An RWO volume serves one node's Pods. This workload asked two nodes to share one, so the immediate fix is to stop doing that. Run a single node-bound consumer.

## Scale to a single consumer

```bash
kubectl scale deployment directory -n app-services --replicas=1
```{{exec}}

The stuck replica is removed, and the survivor runs on the node holding `directory-data`. One RWO consumer on the volume's node is exactly what the access mode allows.

## Verify

```bash
kubectl rollout status deployment directory -n app-services --timeout=60s
kubectl get pods -n app-services -l app=directory -o wide
```{{exec}}

One Running, Ready Pod and no stuck replica. The Deployment is fully available, and `directory-data` never had to move.

## The real-world version

Scaling to one is the fix *here*. It is also a constraint to understand rather than a reflex. `ReadWriteOnce` means one node at a time, full stop. No scheduling change makes an RWO volume serve replicas on several nodes.

Match the volume to how the workload uses its data:

- Several replicas on several nodes, all writing shared data → a `ReadWriteMany` volume on network file storage, such as NFS or a CSI driver that advertises RWX.
- Each replica needs its own durable volume → a StatefulSet with `volumeClaimTemplates` (M07). One claim per Pod, no sharing, no conflict.
- The volume must never have two writers at all → `ReadWriteOncePod`, which break/fix 04 covers.

For self-grading and the full differential, see [`ANSWER-KEY.md`](../ANSWER-KEY.md). You are done — see `finish.md`.
