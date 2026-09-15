# Done

`cdr-writer` had a Bound claim, both replicas targeting one node, and a Pod the scheduler would not place. The claim was `ReadWriteOncePod`, which permits exactly one Pod in the cluster — not one node. The first replica took it, and the scheduler refused the second with `node has pod using PersistentVolumeClaim with the same name and ReadWriteOncePod access mode`. Under `ReadWriteOnce` the same two Pods share the volume without complaint, because they share a node.

The fix crossed two mechanisms worth keeping. A claim's `accessModes` is immutable, so changing it means delete and recreate. And deleting a claim a Pod still uses does not remove it: Storage Object in Use Protection holds it in Terminating behind a `kubernetes.io/pvc-protection` finalizer until the consumer is gone. A delete that appears to hang is often that finalizer doing its job.

That closes the storage differential. `kubectl get pvc` splits every storage-stuck Pod three ways:

- **Pending** → the claim cannot bind (break/fix 01 — a class that does not exist).
- **absent** → the Pod names a claim that was never created (break/fix 02).
- **Bound, Pod still stuck** → the volume refuses that consumer. Two forms: across nodes under RWO (break/fix 03), and across Pods under RWOP (this one).

**Next:**

- Check your path against [`ANSWER-KEY.md`](../ANSWER-KEY.md).
- For the *why*, see [`LESSON.md`](../LESSON.md) § Access modes, attach, and exclusivity.
- You have completed M05's break/fix set. Revisit [`LESSON.md`](../LESSON.md) § Production thinking, then move on to M06 — Scheduling.
