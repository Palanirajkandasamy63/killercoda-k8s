# Done

`cdr-writer` sat Pending with no logs and nothing crashing, because its claim could not bind. The claim named a StorageClass, `fast-ssd`, that does not exist, so no provisioner ran and no volume was created. `get pvc` showed the claim Pending, and `describe pvc` named the cause outright. The fix worked around an immutable field: `storageClassName` cannot be edited, so you deleted the claim and recreated it with the real class, and `WaitForFirstConsumer` bound it as soon as a Pod consumed it.

That is the first leaf of the storage differential: **a Pod stuck on storage is a claim that is not Bound. Read the claim, not the Pod.** Same instinct as M04's empty EndpointSlice, one layer down.

**Next:**

- Check your path against [`ANSWER-KEY.md`](../ANSWER-KEY.md).
- For the *why*, see [`LESSON.md`](../LESSON.md) § StorageClasses, provisioning, and binding mode.
- Next scenario: **`breakfix-02-pvc-claim-missing`** — this time the claim is not Pending. It is not there at all.
