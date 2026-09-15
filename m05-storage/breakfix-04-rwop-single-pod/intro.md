# M05 — Break/fix 04: RWOP Refuses a Second Pod

> Pre-req: the M05 baseline tour and break/fix 01–03. You have seen claim Pending, claim absent, and a Bound claim whose second Pod sat on the wrong node. This is the fourth shape, and the narrowest.

`cdr-writer` in `cdr-storage` runs 2 replicas. One is Running. The other never schedules.

Run `kubectl get pvc` and `cdr-data` is Bound, so this is not break/fix 01 or 02. Run `kubectl get pods -o wide` and both replicas want the *same* node, so this is not break/fix 03 either — nothing is being asked to span nodes. The storage is healthy, the placement is sane, and a Pod still cannot start.

The access mode is the only object left holding an opinion. ReadWriteOnce would let both of these Pods share the volume, because they share a node. This claim asks for something stricter.

Your job: read the scheduler's own words, name the access mode that produced them, and restore one the workload can use. Changing an access mode is not an edit, so the fix walks a deletion path with a safety net on it. The cluster takes up to ~2–3 minutes to come up, and one replica stays stuck by design. Click **Start** when ready.
