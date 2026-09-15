# M05 — Baseline Tour

A container's filesystem is ephemeral. Restart the container and it reverts to the image. Delete the Pod and everything it wrote is gone. That is correct for a stateless service, and wrong for a stateful one. Polyphone runs both: `cdr-writer` persists Call Detail Records, `directory` holds an address book, and the StatefulSets keep per-instance state. Their data must outlive the Pod.

This tour starts at the general idea — a volume is a directory the containers in a Pod can reach — then walks the durable path: **PersistentVolumeClaim**, **PersistentVolume**, and the **StorageClass** that provisions one to satisfy the other.

It runs on the full Polyphone fleet, with no new workloads. Every claim uses the cluster's `local-path` StorageClass: dynamic, `WaitForFirstConsumer`, ReadWriteOnce, `Delete` policy.

Five short steps:

1. **A volume is a directory** — `.spec.volumes` and `volumeMounts`, and an emptyDir that dies with its Pod
2. **A claim, a volume, a class** — a Bound claim, the volume it bound to, and the claimRef that links them
3. **The class recipe, and a healthy Pending** — provisioner, reclaim policy, binding mode, expansion
4. **Access modes, and data that outlives the Pod** — the four modes, and persistence across a Pod delete
5. **The get pvc triage** — the one command that splits every storage-stuck Pod

Nothing is broken here. See what healthy storage looks like before the scenarios snap each link. The cluster takes 90–150 seconds to come up. Click **Start** when ready.
