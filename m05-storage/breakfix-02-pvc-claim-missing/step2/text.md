# Step 2 — Fix it and verify

`directory-data` exists and waits for a consumer. The Deployment names `directory-store`, which does not. Point the Pod template's `claimName` at the claim that is there. A Pod's `claimName` is freely mutable, unlike a claim's own `storageClassName`, so editing the Deployment rolls a new Pod.

## Correct the claimName

```bash
kubectl patch deployment directory -n app-services --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName","value":"directory-data"}]'
```{{exec}}

Or by hand:

```bash
kubectl edit deployment directory -n app-services
# under volumes: → persistentVolumeClaim:
# change  claimName: directory-store
# to      claimName: directory-data
```

Editing the Pod template triggers a rollout. The Pending Pod is replaced by one that mounts `directory-data`. A Pod now consumes that claim, so `WaitForFirstConsumer` binds it, and the Pod schedules and starts.

The mirror-image fix is equally valid. If the *claim* were misnamed and the Pod were right, you would create or rename the claim instead. Repair whichever side is wrong. Here the Pod named a claim that never existed.

## Verify

```bash
kubectl wait --for=condition=Ready pod -l app=directory -n app-services --timeout=60s
kubectl get pods -n app-services -l app=directory
kubectl get pvc -n app-services
```{{exec}}

The `directory` Pod is Running and Ready, and `directory-data` is Bound now that a Pod consumes it. The volume never changed. Only the name the Pod used did.

For self-grading and the full differential, see [`ANSWER-KEY.md`](../ANSWER-KEY.md). You are done — see `finish.md`.
