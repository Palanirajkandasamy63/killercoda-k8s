# Done

`directory` had a Bound claim and a Pod that still would not start — the third leaf, and the one that trips people, because `get pvc` looks perfect. A single `ReadWriteOnce` volume was asked to back two replicas on two nodes, and RWO means one node at a time. The scheduler refused the second replica with `didn't match PersistentVolume's node affinity`, which is the local-volume form of a Multi-Attach error. The fix was to stop spanning nodes.

That leaf has a second form, narrower than this one. `ReadWriteOnce` counts nodes, so two Pods on *one* node share the volume happily. `ReadWriteOncePod` counts Pods, and refuses the second Pod anywhere. Break/fix 04 is that case.

`kubectl get pvc` splits every storage-stuck Pod three ways:

- **Pending** → the claim cannot bind (break/fix 01 — a class that does not exist).
- **absent** → the Pod names a claim that does not exist (break/fix 02).
- **Bound, Pod still stuck** → the volume refuses that consumer (this one, and break/fix 04).

**Next:**

- Check your path against [`ANSWER-KEY.md`](../ANSWER-KEY.md).
- For the *why*, see [`LESSON.md`](../LESSON.md) § Access modes, attach, and exclusivity.
- Next scenario: **`breakfix-04-rwop-single-pod`** — a Bound claim, both Pods on one node, and one still refused.
