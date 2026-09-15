# Done

You walked the storage chain end to end. A volume is a plain directory, and the `emptyDir` you made died with its Pod. The `cdr-data` claim is Bound to a volume its class provisioned, and a `claimRef` binds the two. `WaitForFirstConsumer` held a consumer-less claim Pending on purpose. The class refused an expansion, because it does not set `allowVolumeExpansion`. An RWO volume stayed pinned to one node, and the data survived a Pod delete.

That is the shape of healthy. Internalize it, so each broken link stands out.

**Next:**

- For the *why* behind all of it, read [`LESSON.md`](../LESSON.md).
- Then work the four break/fix scenarios, in order. Together they walk the **storage differential** top to bottom, one `get pvc` signature each:
  - **`breakfix-01-pvc-storageclass-missing`** — claim Pending: it cannot bind, because its StorageClass does not exist.
  - **`breakfix-02-pvc-claim-missing`** — claim absent: the Pod names a claim that is not there.
  - **`breakfix-03-rwo-multi-attach`** — claim Bound, Pod still stuck: an RWO volume asked to serve two nodes.
  - **`breakfix-04-rwop-single-pod`** — claim Bound, Pod still stuck on one node: RWOP refuses a second Pod.
- Check your diagnostic path against [`ANSWER-KEY.md`](../ANSWER-KEY.md) after each.
