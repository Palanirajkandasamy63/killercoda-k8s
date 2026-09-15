# Done

You walked the storage chain end to end: a volume as a plain directory, an `emptyDir` that died with its Pod, a Bound claim and the volume a class provisioned for it, the `claimRef` that binds the two, the `WaitForFirstConsumer` binding that holds a consumer-less claim Pending on purpose, an expansion the class refused, an RWO volume pinned to one node, data that survived a Pod delete, and the `get pvc` triage. That is the shape of healthy. Internalize it, so each broken link stands out.

**Next:**

- For the *why* behind all of it, read [`LESSON.md`](../LESSON.md).
- Then work the four break/fix scenarios, in order. Together they walk the **storage differential** top to bottom, one `get pvc` signature each:
  - **`breakfix-01-pvc-storageclass-missing`** — claim Pending: it cannot bind, because its StorageClass does not exist.
  - **`breakfix-02-pvc-claim-missing`** — claim absent: the Pod names a claim that is not there.
  - **`breakfix-03-rwo-multi-attach`** — claim Bound, Pod still stuck: an RWO volume asked to serve two nodes.
  - **`breakfix-04-rwop-single-pod`** — claim Bound, Pod still stuck on one node: RWOP refuses a second Pod.
- Check your diagnostic path against [`ANSWER-KEY.md`](../ANSWER-KEY.md) after each.
