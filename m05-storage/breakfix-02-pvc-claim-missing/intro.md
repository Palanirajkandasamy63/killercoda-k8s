# M05 — Break/fix 02: A Pod Names a Claim That Is Not There

> Pre-req: the M05 baseline tour and break/fix 01. You have seen a claim stuck Pending. This claim is not stuck. It is absent.

`directory` in `app-services` is Pending and never started. At a glance it looks like break/fix 01 — a Pod waiting on storage — but the shape differs. This time `describe pod` names the exact cause, and it is neither a class problem nor a binding problem.

The Pod is asking for a claim that does not exist. A Pod references a claim by name, in its own namespace. If that name matches nothing, the Pod waits forever for a volume nobody requested. This is the second leaf of the differential: the claim the Pod names is not Pending, it is absent.

Your job: read what the Pod is mounting, compare it with the claims that exist, and point the Pod at the right one. The cluster takes up to ~2–3 minutes to come up, and one workload stays Pending by design. Click **Start** when ready.
