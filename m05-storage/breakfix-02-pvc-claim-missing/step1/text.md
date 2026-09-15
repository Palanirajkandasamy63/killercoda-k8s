# Step 1 — Diagnose the missing claim

Same surface as break/fix 01 — a Pod Pending on storage — and `get pvc` tells a different story. Follow the claim.

## Confirm the symptom, then read the Pod's own words

```bash
kubectl get pods -n app-services -l app=directory
```{{exec}}

`directory` is Pending. This time the events name the exact cause:

```bash
kubectl describe pod -n app-services -l app=directory
```{{exec}}

Two places in that output matter. The `Events:` block reads `persistentvolumeclaim "directory-store" not found`. Further up, the `Volumes:` block shows `ClaimName: directory-store` — the only storage reference the Pod holds.

## List the claims that exist

```bash
kubectl get pvc -n app-services
```{{exec}}

There is no `directory-store`. The claim the Pod names was never created. The real claim is `directory-data`, one word apart.

That is the discriminator against break/fix 01. There, `describe pod` said the claim was *unbound*, and the named claim was in the list as Pending. Here it says the claim is *not found*, because nothing by that name exists. Claims are matched by exact name inside one namespace, so a one-word difference makes a claim invisible to the Pod.

You will also see `directory-data` itself sitting Pending. That is the healthy `WaitForFirstConsumer` from the baseline, not a second fault: nothing consumes `directory-data`, precisely because the Pod that should is pointed at the wrong name. Fix the name and this claim gets its consumer.

The volume is fine. The Pod is not asking for it. On to the fix.
