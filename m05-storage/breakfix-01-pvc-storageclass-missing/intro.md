# M05 — Break/fix 01: A Claim That Never Binds

> Pre-req: the M05 baseline tour. You have seen a Bound claim and a healthy `WaitForFirstConsumer` Pending. This is a Pending that really is broken.

`cdr-writer` in `cdr-storage` never came up. `kubectl get pods -n cdr-storage` shows it Pending, and it has been that way since the cluster started. There are no logs, because the container never ran. Nothing is crashing. The Pod is waiting.

Waiting for what? A Pod that mounts a claim does not start until that claim is Bound. So the diagnosis is not in the Pod. It is in the claim, one object over. This is the first leaf of the storage differential: the claim cannot get a volume.

Your job: run `get pvc` instead of describing the Pod in circles, read why the claim is stuck, and repair the class it asks for. The cluster takes up to ~2–3 minutes to come up, and one workload stays Pending by design. Click **Start** when ready.
