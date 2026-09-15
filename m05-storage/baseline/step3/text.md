# Step 3 — The class recipe, and a healthy Pending

One object holds every setting that decides how and when a claim gets its volume. Read it, then watch a claim sit Pending on purpose — the most misread state in Kubernetes storage.

## Read the recipe

```bash
kubectl describe storageclass local-path
```{{exec}}

Four lines matter:

- `Provisioner: rancher.io/local-path` — the component that creates the real storage. Here it carves a directory on a node's disk.
- `ReclaimPolicy: Delete` — when a bound claim is deleted, the volume and its data are destroyed.
- `VolumeBindingMode: WaitForFirstConsumer` — do not bind the claim until a Pod uses it. The other value is `Immediate`, which binds at claim creation and is the default when a class omits the field.
- `AllowVolumeExpansion: <unset>` — this class does not permit growth.

## Growth needs the class's permission

Ask for a bigger claim:

```bash
kubectl patch pvc cdr-data -n cdr-storage -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
```{{exec}}

The API refuses: the class that provisioned the claim must support resize. Set `allowVolumeExpansion: true` on a class and the same patch succeeds, growing the volume in place. Growth is one-way, because a claim never shrinks.

## Watch WaitForFirstConsumer hold a claim

Create a claim that no Pod uses:

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: scratch-demo, namespace: cdr-storage }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 100Mi } }
YAML
kubectl describe pvc scratch-demo -n cdr-storage
```{{exec}}

`Status: Pending`, and the Events line at the bottom reads `waiting for first consumer to be created before binding`. **That is healthy, not broken.** With `WaitForFirstConsumer`, the class delays binding on purpose: for node-local storage it cannot know which node's volume to create until the scheduler picks a node for the Pod.

The rule to carry into every scenario: **Pending means broken only once a Pod is trying to use the claim and it still will not bind.** No consumer, no problem.

Clean up:

```bash
kubectl delete pvc scratch-demo -n cdr-storage
```{{exec}}

That delete returned immediately, because nothing was using the claim. A claim a Pod still references behaves differently — Storage Object in Use Protection holds it in Terminating until the consumer goes away. Break/fix 04 walks that path.

Next: the access mode, and proving the data outlives the Pod.
