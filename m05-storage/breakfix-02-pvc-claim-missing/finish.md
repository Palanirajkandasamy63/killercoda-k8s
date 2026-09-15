# Done

`directory` sat Pending because it named a claim that did not exist: `directory-store`, one word off `directory-data`. A claim that is not there can never bind, so the Pod waited on nothing. `describe pod` said it in words — `persistentvolumeclaim "..." not found` — and `get pvc` confirmed the named claim was absent, while `directory-data` sat in the healthy `WaitForFirstConsumer` Pending because nothing consumed it. The fix touched only the Pod's `claimName`.

That is the second leaf. The claim a Pod names is Pending in break/fix 01 and absent here. The move that separates them is correlating the Pod's `claimName` with the `get pvc` list. Do not just scan which claims are Pending. Check whether the one the Pod asks for is even there. Same first command, two answers, two fixes.

**Next:**

- Check your path against [`ANSWER-KEY.md`](../ANSWER-KEY.md).
- For the *why*, see [`LESSON.md`](../LESSON.md) § The claim and the volume.
- Next scenario: **`breakfix-03-rwo-multi-attach`** — this time the claim is Bound, and a Pod is *still* stuck.
