# `m05-storage/` — M05 — Storage: Volumes, PersistentVolumes, Claims & StorageClasses

**Category:** PersistentVolumes / Claims (storage)

Concept reading: `m05-storage/LESSON.md`

## Break/fix 01 — A claim that never binds (missing StorageClass)

**Symptom — what you'd actually see:**

`cdr-writer` in `cdr-storage` is Pending from cluster start, with no logs and nothing crashing. Its container never ran. It is waiting on storage.

**Think about this before you open the answer:**

The `get pvc` reflex, and the dynamic-provisioning chain from claim to class to volume. Self-grading questions:

- Was `kubectl get pvc` one of your first three commands, rather than describing the Pod in circles?
- Did you read `describe pvc` for the reason, instead of guessing?
- Did you hit the immutability of `storageClassName` and recreate the claim, rather than fighting a rejected patch?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `cdr-data` claim sets `storageClassName: fast-ssd`, and no such class exists on the cluster. With no class there is no provisioner to call, so no volume is created and the claim stays Pending<sup><a href="https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/">[1]</a></sup>. A Pod that mounts a Pending claim cannot be scheduled, so `cdr-writer` is Pending too. The claim holds the diagnosis; the Pod is one object downstream.

**Diagnostic commands (run in this order):**

```bash
# 1. The Pod is Pending, and its events point at storage rather than a crash
kubectl get pods -n cdr-storage
kubectl describe pod -n cdr-storage -l app=cdr-writer
#    Events: ... pod has unbound immediate PersistentVolumeClaims

# 2. First look — the claim's status is the diagnosis
kubectl get pvc -n cdr-storage
#    cdr-data   Pending

# 3. Ask the claim why
kubectl describe pvc cdr-data -n cdr-storage
#    Events: storageclass.storage.k8s.io "fast-ssd" not found

# 4. Confirm the class is absent
kubectl get storageclass
#    only local-path
```

A Pod is using this claim, so Pending here is broken, not the healthy `WaitForFirstConsumer` case.

**Exact fix:**

Point the claim at the real class. `storageClassName` is **immutable**, so this is a delete and recreate rather than an edit. It is safe here, because the claim never bound and holds no data. Remove the consumer first, so the delete does not wait on it:

```bash
kubectl scale deployment cdr-writer -n cdr-storage --replicas=0
kubectl delete pvc cdr-data -n cdr-storage
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: cdr-data, namespace: cdr-storage }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 1Gi } }
YAML
kubectl scale deployment cdr-writer -n cdr-storage --replicas=1
```

**Verify:**

```bash
kubectl get pvc cdr-data -n cdr-storage        # Bound
kubectl wait --for=condition=Ready pod -l app=cdr-writer -n cdr-storage --timeout=60s
```

**Production thinking:**

A class name typo, or an uninstalled class, fails every claim that names it, silently, at apply time. The workload simply never comes up. Guard it by pinning workloads to classes that exist in every target cluster, and by alerting on claims Pending beyond a threshold *with a consumer present* — that qualifier is what keeps `WaitForFirstConsumer` from paging you. The immutability is the sharp edge: fixing a wrong class on a claim that already holds data is a migration, not a one-liner. Provision a new claim on the right class, copy, cut over.

</details>

---

## Break/fix 02 — A Pod names a claim that is not there

**Symptom — what you'd actually see:**

`directory` in `app-services` is Pending. It looks like break/fix 01, and `describe pod` names a different cause: the claim the Pod mounts is not present at all.

**Think about this before you open the answer:**

That the Pod-to-claim link is by name and namespace, and that `get pvc` distinguishes absent from Pending. Self-grading questions:

- Did you correlate the Pod's `claimName` with the `get pvc` list, noticing `directory-store` is absent, rather than fixating on `directory-data` showing Pending?
- Did you read `persistentvolumeclaim "..." not found` as a wrong name, not a provisioning failure?
- Did you fix the reference, rather than creating a redundant `directory-store` claim to satisfy the typo?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `directory` Deployment's Pod template mounts a volume with `claimName: directory-store`, and no claim by that name exists. The real claim is `directory-data`. A Pod references a claim by exact name within its own namespace, so a name that matches nothing means the Pod waits for a volume nobody requested<sup><a href="https://kubernetes.io/docs/concepts/storage/persistent-volumes/">[2]</a></sup>. This is the absent-claim leaf, distinct from break/fix 01's Pending-claim leaf.

**Diagnostic commands (run in this order):**

```bash
# 1. The event names the exact claim, and the Volumes block names what the Pod wants
kubectl describe pod -n app-services -l app=directory
#    Events:  persistentvolumeclaim "directory-store" not found
#    Volumes: ClaimName: directory-store

# 2. First look — list the claims that exist
kubectl get pvc -n app-services
#    directory-data   Pending   <-- exists; healthy WaitForFirstConsumer, no consumer yet
#    (no directory-store at all — the claim the Pod named)
```

The discriminator against break/fix 01: there the named claim was present but Pending; here the named claim is not in the list. Do not be thrown that `directory-data` shows Pending — that is the healthy binding mode, because the mis-pointed Pod never consumed it. Correlate the Pod's `claimName` with the list, not just the claim statuses.

**Exact fix:**

Point the Deployment's `claimName` at the claim that exists. Unlike a claim's `storageClassName`, a Pod's `claimName` is freely mutable, and editing the Pod template rolls a new Pod:

```bash
kubectl patch deployment directory -n app-services --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName","value":"directory-data"}]'
# or: kubectl edit deployment directory -n app-services   → claimName: directory-data
```

**Verify:**

```bash
kubectl wait --for=condition=Ready pod -l app=directory -n app-services --timeout=60s
kubectl get pvc -n app-services                # directory-data now Bound
```

**Production thinking:**

This ships from a rename that touched one side only, or from a volume block copy-pasted between workloads. No storage is unhealthy; the Pod points at nothing. Keep the claim and the `claimName` in one templated source (Kustomize or Helm, M16–M17) so they cannot diverge. And remember that creating a second claim to match a typo'd name fixes the symptom while doubling your volumes and splitting your data. Correct the reference instead.

</details>

---

## Break/fix 03 — An RWO volume cannot serve two nodes

**Symptom — what you'd actually see:**

`directory` in `app-services` was scaled to 2 replicas. One is Running, the other will not schedule. `kubectl get pvc` shows `directory-data` Bound, so the storage exists and bound cleanly, and a Pod still cannot start.

**Think about this before you open the answer:**

The access modes, and reading the Bound-but-stuck signature as exclusivity. Self-grading questions:

- Did the Bound claim stop you chasing a provisioning bug that was not there, and send you to the access mode?
- Did you read `ReadWriteOnce` as one *node*, and recognize `didn't match PersistentVolume's node affinity` and `Multi-Attach` as the same rule?
- Did you land on a single node-bound consumer, or a genuine RWX or `volumeClaimTemplates` design, rather than deleting the stuck Pod and watching it return?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`directory-data` is `ReadWriteOnce`, which permits read-write mounting by a single node<sup><a href="https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes">[3]</a></sup>. The two replicas were forced onto different nodes. The first attached the volume on its node, and the second cannot attach the same volume from another node. Because this is a node-local volume, the conflict surfaces as `didn't match PersistentVolume's node affinity` — the volume carries hard node affinity. On a cloud block volume the identical rule reads `Multi-Attach error for volume ... already exclusively attached to one node`. A Bound claim with a stuck Pod is the signature of exclusivity, not binding.

**Diagnostic commands (run in this order):**

```bash
# 1. One replica up, one stuck, and they are on different nodes
kubectl get pods -n app-services -l app=directory -o wide

# 2. First look — the claim is Bound, so neither leaf 1 nor leaf 2
kubectl get pvc -n app-services
#    directory-data   Bound

# 3. Read the scheduling failure — name the Pending replica, since -l matches both
kubectl describe pod -n app-services $(kubectl get pods -n app-services -l app=directory --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
#    Events: ... node(s) didn't match PersistentVolume's node affinity ...

# 4. See where the volume is pinned
PV=$(kubectl get pvc directory-data -n app-services -o jsonpath='{.spec.volumeName}')
kubectl describe pv "$PV"
#    Node Affinity: the node running the healthy replica
```

Bound claim plus stuck Pod is always an access-mode or topology problem, never a binding one.

**Exact fix:**

Stop asking one RWO volume to serve Pods on two nodes. Run a single node-bound consumer:

```bash
kubectl scale deployment directory -n app-services --replicas=1
```

**Verify:**

```bash
kubectl rollout status deployment directory -n app-services --timeout=60s
kubectl get pods -n app-services -l app=directory -o wide     # one Running/Ready, none stuck
```

**Production thinking:**

This failure hides in a single-node dev cluster and detonates on a multi-node one. Two replicas on one node share an RWO volume fine, so it works in test, and the moment the scheduler spreads them the second replica jams. The design question is what the workload needs. A *shared* multi-writer volume means RWX, on network file storage or a driver that advertises it. A *per-replica* durable volume means a StatefulSet with `volumeClaimTemplates` (M07), one claim per Pod, no sharing. Scaling to one is the incident fix. Choosing the right access mode for the access pattern is the durable one.

</details>

---

## Break/fix 04 — RWOP refuses a second Pod

**Symptom — what you'd actually see:**

`cdr-writer` in `cdr-storage` runs 2 replicas. One is Running, the other never schedules. `kubectl get pvc` shows `cdr-data` Bound, and `kubectl get pods -o wide` shows both replicas targeting the *same* node — so nothing is being asked to span nodes either.

**Think about this before you open the answer:**

That access modes count nodes except RWOP, which counts Pods, and that a claim's spec is immutable while a live consumer blocks its deletion. Self-grading questions:

- Did you rule out break/fix 03 by checking the `NODE` column, instead of assuming every Bound-but-stuck Pod is a node-spanning conflict?
- Did you read the `FailedScheduling` message rather than inferring the cause, and separate it from the control-plane taint line in the same event?
- Did you recognize the Terminating claim as in-use protection working, rather than a stuck object needing a forced finalizer removal?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`cdr-data` is `ReadWriteOncePod`, which permits read-write mounting by a single Pod across the whole cluster<sup><a href="https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes">[3]</a></sup>. The first replica took the claim, and the scheduler refuses every other Pod that mounts it, including Pods on the same node. `ReadWriteOnce` counts nodes and would have allowed both of these Pods, because they share one node. `ReadWriteOncePod` counts Pods. The claim is Bound throughout: the failure is exclusivity at the Pod level.

**Diagnostic commands (run in this order):**

```bash
# 1. One replica up, one Pending — and both want the same node
kubectl get pods -n cdr-storage -o wide

# 2. First look — the claim is Bound
kubectl get pvc -n cdr-storage
#    cdr-data   Bound

# 3. Rule out the node-spanning case: the volume is on the node already in use
PV=$(kubectl get pvc cdr-data -n cdr-storage -o jsonpath='{.spec.volumeName}')
kubectl describe pv "$PV"
#    Node Affinity: the node running the healthy replica

# 4. Read the scheduler's own words — name the Pending replica, since -l matches both
kubectl describe pod -n cdr-storage $(kubectl get pods -n cdr-storage -l app=cdr-writer --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
#    Events: node has pod using PersistentVolumeClaim with the same name and
#            ReadWriteOncePod access mode

# 5. Confirm the access mode
kubectl describe pvc cdr-data -n cdr-storage
#    Access Modes: RWOP
```

**Exact fix:**

This workload runs two Pods on one node by design, so the claim needs `ReadWriteOnce`. A claim's `accessModes` is immutable, so that means delete and recreate. Deleting a claim a Pod still uses does not remove it — Storage Object in Use Protection holds it in Terminating behind a `kubernetes.io/pvc-protection` finalizer until the consumer is gone<sup><a href="https://kubernetes.io/docs/concepts/storage/persistent-volumes/#storage-object-in-use-protection">[4]</a></sup>. On a claim holding real records this procedure is a data migration, because the class reclaim policy is `Delete`.

```bash
kubectl patch pvc cdr-data -n cdr-storage -p '{"spec":{"accessModes":["ReadWriteOnce"]}}'   # rejected: immutable
kubectl delete pvc cdr-data -n cdr-storage --wait=false
kubectl get pvc -n cdr-storage                      # Terminating, held by the finalizer
kubectl scale deployment cdr-writer -n cdr-storage --replicas=0   # consumer gone → delete completes
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: cdr-data, namespace: cdr-storage }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 1Gi } }
YAML
kubectl scale deployment cdr-writer -n cdr-storage --replicas=2
```

**Verify:**

```bash
kubectl rollout status deployment cdr-writer -n cdr-storage --timeout=90s
kubectl get pods -n cdr-storage -o wide       # both replicas Running/Ready on one node
kubectl get pvc cdr-data -n cdr-storage       # Bound, ACCESS MODES = RWO
```

**Production thinking:**

RWOP is the right tool for a volume that must never have two writers, such as a single-writer database, and it caps that workload at one Pod by design. The failure mode is tightening a shared claim to RWOP without noticing the Deployment runs more than one replica — the workload then loses capacity silently, one Pod at a time, with a perfectly healthy-looking claim. Put single-writer volumes behind a workload that cannot exceed one Pod, and treat a claim's access mode as part of the workload's contract rather than a storage detail. Force-removing the `pvc-protection` finalizer to hurry a delete is the anti-pattern: Kubernetes forgets the object while the real disk, and any process still writing to it, survives.

</details>

---
