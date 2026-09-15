# M05 — Break/fix 03: An RWO Volume Cannot Serve Two Nodes

> Pre-req: the M05 baseline tour and break/fix 01–02. You have split "claim Pending" from "claim absent". This is the third case: claim Bound, Pod still stuck.

`directory` in `app-services` was scaled to 2 replicas for headroom. One came up. The other will not schedule.

Run `get pvc` and `directory-data` is Bound, so this is neither break/fix 01 nor break/fix 02. The storage exists and bound cleanly. A Pod still cannot start.

A Bound claim with a stuck Pod is the signature of an exclusivity problem, and the access mode is the cause. `directory-data` is `ReadWriteOnce`, so one node may mount it at a time. The two replicas were forced onto two different nodes, and the second cannot attach a volume that is already committed to the first node.

Your job: recognize the Bound-but-stuck shape, read the scheduling failure, and stop asking one RWO volume to serve two nodes. The cluster takes up to ~2–3 minutes to come up, and one replica stays stuck by design. Click **Start** when ready.
