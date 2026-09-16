# Step 1 — Diagnose the refused second Pod

Two replicas, one node, a Bound claim, and one Pod that will not start. Work the differential you already know, and watch it run out of answers.

## See the split

```bash
kubectl get pods -n cdr-storage -o wide
```{{exec}}

One `cdr-writer` replica is Running with a node in the `NODE` column. The other is Pending with none. Now the first-look command:

```bash
kubectl get pvc -n cdr-storage
```{{exec}}

`cdr-data` is Bound. So the claim is not Pending (break/fix 01) and not absent (break/fix 02). Storage was delivered.

## Rule out the node-spanning case

```bash
PV=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.spec.volumeName}')
kubectl describe pv "$PV"
```{{exec}}

Read `Node Affinity:` and compare it with the `NODE` column above. The volume is pinned to the node where the Running replica already sits, and the Pending replica has no competing node to go to — this cluster has one schedulable node. Break/fix 03's failure needed two nodes. This one does not.

## Read what the scheduler actually says

```bash
kubectl describe pod -n cdr-storage -l app=cdr-writer
```{{exec}}

Scroll to the `Events:` block of the Pending Pod. The `FailedScheduling` message names the cause outright:

```
node has pod using PersistentVolumeClaim with the same name and ReadWriteOncePod access mode
```

(The same message also lists the control-plane taint for the other node — that line is background noise here, not the fault.)

Events expire after about an hour, and the scheduler does not retry an already-unschedulable Pod until the cluster changes. If `Events:` is empty, force a fresh attempt:

```bash
kubectl delete pod -n cdr-storage $(kubectl get pods -n cdr-storage -l app=cdr-writer --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod -n cdr-storage -l app=cdr-writer
```{{exec}}

The ReplicaSet recreates the Pod immediately and the event reappears.

## Confirm the access mode

```bash
kubectl describe pvc cdr-data -n cdr-storage
```{{exec}}

`Access Modes: RWOP`. **ReadWriteOncePod permits exactly one Pod in the whole cluster to use the claim** — not one node, one Pod. The first replica took it, and the scheduler refuses every other Pod that mounts the same claim, including Pods on the same node.

That is the difference the word "Once" hides. Under `ReadWriteOnce` this Deployment would run both replicas happily, because they share a node. Under `ReadWriteOncePod` the second Pod has nowhere to be.

Nothing is broken. An access mode is keeping a promise the workload cannot live with. On to the fix.
