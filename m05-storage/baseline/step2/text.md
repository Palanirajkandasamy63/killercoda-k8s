# Step 2 — A claim, a volume, a class

Durable storage is three objects that reference each other. A **PersistentVolumeClaim** is a request for storage. A **PersistentVolume** is the piece of storage. A **StorageClass** is the recipe that provisioned that volume. A Pod names only the claim.

## See the claims the fleet holds

```bash
kubectl get pvc -A
```{{exec}}

Every claim-backed workload has one: `cdr-data` in `cdr-storage`, `directory-data` in `app-services`, and the per-Pod claims the StatefulSets mint (`state-media-engine-0`, `state-presence-0`). The `STATUS` column reads Bound, so each claim found a volume. Read one closely:

```bash
kubectl describe pvc cdr-data -n cdr-storage
```{{exec}}

Five lines carry the whole state: `Status: Bound`, `Capacity: 1Gi`, `Access Modes: RWO`, `StorageClass: local-path`, and `Volume:` — the name of the PV it bound to, something like pvc-9f3c… The claim asked for 1Gi RWO, the class provisioned a volume to match, and the two bound.

## Read the binding from the other side

```bash
kubectl get pv
```{{exec}}

Each volume lists its `CAPACITY`, `ACCESS MODES`, `RECLAIM POLICY`, `STATUS`, and — under `CLAIM` — which claim owns it, as cdr-storage/cdr-data. That back-reference is the binding itself. It is a `claimRef`, a bi-directional link: the volume's `spec.claimRef` names the claim, and the claim's `spec.volumeName` names the volume. See both fields:

```bash
kubectl get pvc cdr-data -n cdr-storage -o yaml
```{{exec}}

Read `spec.volumeName` under `spec:`. Now read the matching field on the volume:

```bash
PV=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV" -o yaml
```{{exec}}

Read the `claimRef:` block: it names the claim's kind, namespace and name. A binding is exclusive and one-to-one, so no second claim can take this volume while that `claimRef` is set.

Note the scopes. PVCs are namespaced, and PVs are not. A Pod may only use a claim in its own namespace, which makes the claim the tenant-facing handle and the volume a cluster resource.

## See the class that made it

```bash
kubectl get storageclass
```{{exec}}

One class, `local-path`. The claim named it in `storageClassName`, and creating the claim triggered that class to carve a volume. That is **dynamic provisioning** — no administrator pre-created anything. The chain end to end: the Pod names the claim, the claim names the class, and the class provisioned the volume.

Next: how that provisioning is configured, and a Pending claim that is perfectly healthy.
