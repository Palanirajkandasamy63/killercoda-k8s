# `m24-stateful-coordination/` — M24 — Stateful Coordination: Identity, Discovery & Leadership

**Category:** Stateful coordination (identity/leader election)

Concept reading: `m24-stateful-coordination/LESSON.md`

## Break/fix 01 — Per-Pod DNS gone: Service lost `clusterIP: None`

**Symptom — what you'd actually see:**

`session-cache`'s Pods (`-0/-1/-2`) are all `Running`, nothing crashing, but a peer that tries to resolve `session-cache-0.session-cache.media.svc.cluster.local` gets `NXDOMAIN`. The cache can't form a cluster because no member can address another by name. Identity is intact; discovery is not.

**Think about this before you open the answer:**

That you separate identity from discovery and read the Service, not the Pods. Self-grading:

- Did you resist `kubectl logs` / Pod restarts once you saw every Pod `Running`, and go to DNS + the Service instead?
- Did you spot `CLUSTER-IP` being an IP rather than `None` as the root cause — and know that a VIP means no per-Pod records?
- Did you delete-and-recreate rather than fight the immutable `clusterIP` with `patch`/`edit`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The governing Service was created without `clusterIP: None`, so it's an ordinary ClusterIP Service with a real VIP. Per-Pod stable DNS records (`<pod>.<service>.<ns>.svc.cluster.local`) are published **only** for a *headless* governing Service<sup><a href="https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/">[4]</a></sup>; the moment the Service got a VIP those records disappeared, and the Service name now resolves to a single round-robin IP that hides members instead of exposing them<sup><a href="https://kubernetes.io/docs/concepts/services-networking/service/#headless-services">[3]</a></sup>. The StatefulSet's `serviceName` still matches, so it's not a naming mismatch — the Service simply isn't headless.

**Diagnostic commands (run in this order):**

```bash
# 1. The Pods are fine — establish that first
kubectl get pods -n media -l app=session-cache -o wide   # all Running, stable ordinals

# 2. The per-Pod name won't resolve; the Service name resolves to ONE IP
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  nslookup session-cache-0.session-cache.media.svc.cluster.local   # can't resolve / NXDOMAIN
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  nslookup session-cache.media.svc.cluster.local                   # one VIP, not the Pod set

# 3. The tell: the Service has a clusterIP, not None
kubectl get svc -n media session-cache                             # CLUSTER-IP is a real IP
kubectl get svc session-cache -n media -o jsonpath='{.spec.clusterIP}'; echo   # 10.96.x.x, not None
```

**Exact fix:**

`clusterIP` is **immutable**, so you can't edit it back — a `patch` is rejected (`may not change once set`). Delete and recreate the Service headless (this touches neither the Pods nor their PVCs):

```bash
kubectl delete svc session-cache -n media
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: session-cache
  namespace: media
  labels: { app: session-cache, plane: media, tier: lab }
spec:
  clusterIP: None
  selector: { app: session-cache }
  ports: [{ port: 6379, name: cache }]
EOF
```

**Verify:**

```bash
kubectl get svc session-cache -n media                             # CLUSTER-IP: None
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  nslookup session-cache-0.session-cache.media.svc.cluster.local   # resolves to Pod-0's IP
```

**Production thinking:**

This is the classic "works in dev, breaks in stage" where someone gave the governing Service a `clusterIP` to "make it show up in the service list," not realizing that headlessness *is* the feature. The one-command discriminator between this and a plain DNS typo is `get svc … clusterIP`: `None` vs. an IP<sup><a href="https://kubernetes.io/docs/concepts/services-networking/service/#headless-services">[3]</a></sup>. Guard it by templating the Service with `clusterIP: None` in the same chart as the StatefulSet (M16–M17) and by an admission policy that rejects a governing Service that isn't headless (M20). Because `clusterIP` is immutable, the recovery is always delete-and-recreate — cheap for a headless Service (no VIP to lose), but worth knowing before the incident, not during it.

</details>

---

## Break/fix 02 — StatefulSet wedged behind ordinal 0

**Symptom — what you'd actually see:**

`session-cache` is declared `replicas: 3` but only `session-cache-0` exists, stuck `0/1 Running` (Running, never Ready). No `session-cache-1`, no `session-cache-2` — and no Pending Pod to describe, because the higher ordinals were never created. `kubectl get statefulset` reads `READY 0/3`.

**Think about this before you open the answer:**

That you read the *order* of a StatefulSet's failure, not just the missing Pods. Self-grading:

- Did you recognize that missing higher ordinals are *not created*, not `Pending` — so it's an ordering problem, not a scheduling/capacity one?
- Did you diagnose the **first** unready ordinal (0) rather than hunting for why `-1`/`-2` are "missing"?
- Did you fix the probe port (the thing keeping 0 unready), then notice the patch alone leaves the set wedged — and delete the stuck ordinal-0 Pod so `OrderedReady` reruns it on the corrected template?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The container's readiness probe does an HTTP GET on **port 8080**, but the container is nginx, which serves on **port 80** — nothing listens on 8080, so every probe returns `connection refused` and ordinal 0 never crosses into Ready. With the default `podManagementPolicy: OrderedReady`, the controller will not create ordinal N+1 until ordinal N is Running **and** Ready<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#pod-management-policies">[2]</a></sup>. So the whole set is wedged behind a single unready ordinal: the container is healthy, the *probe* points at the wrong port, and that one wrong port halts every higher member<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Only ordinal 0 exists, and it isn't Ready
kubectl get statefulset session-cache -n media            # READY 0/3
kubectl get pods -n media -l app=session-cache            # one Pod: session-cache-0, 0/1 Running

# 2. Why isn't it Ready? The readiness probe is failing
kubectl describe pod session-cache-0 -n media | grep -A8 Events
#    Readiness probe failed: ... connection refused

# 3. Read what the probe actually checks
kubectl get statefulset session-cache -n media \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet}'; echo   # port 8080 (nginx serves on 80)
```

**Exact fix:**

The Pod template is mutable, so `patch` (or `edit`) the probe port to 80 — but that alone won't recover the set. Under `OrderedReady`, a StatefulSet won't roll a corrected template onto a Pod that was never Ready (a documented "forced rollback"<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#forced-rollback">[7]</a></sup>), so you must also delete the stuck ordinal-0 Pod; its replacement is created from the corrected template, goes Ready, and the cascade unblocks:

```bash
kubectl patch statefulset session-cache -n media --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'
# or: kubectl edit statefulset session-cache -n media  → readinessProbe.httpGet.port 8080 → 80
kubectl delete pod session-cache-0 -n media          # forced rollback: the bad-revision Pod must go
kubectl rollout status statefulset session-cache -n media --timeout=120s
```

**Verify:**

```bash
kubectl get statefulset session-cache -n media           # READY 3/3
kubectl get pods -n media -l app=session-cache           # session-cache-0/-1/-2 all 1/1 Running
```

**Production thinking:**

`OrderedReady` makes a set only as available as its lowest unready ordinal — a property that's a feature (member 0 bootstraps before 1 joins) and a foot-gun (one bad probe or a wedged init dark-outs the whole set). When ordered startup isn't a real dependency, `podManagementPolicy: Parallel` removes this single point of stall by bringing all Pods up at once<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#pod-management-policies">[2]</a></sup>. Recovery carries its own trap: correcting the template doesn't heal a Pod that was never Ready, so automation that "just applies the fix" and waits will hang until someone deletes the wedged Pod by hand<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#forced-rollback">[7]</a></sup>. Probe-port drift is a common trigger: pin the probe port to the container's named port so a port rename can't silently orphan the probe, and alert on a StatefulSet whose `readyReplicas` sits below `replicas` for longer than a rollout should take — that gap, not a Pod crash, is the signal here.

</details>

---

## Break/fix 03 — No leader elected: leader-election RBAC gap

**Symptom — what you'd actually see:**

`call-coordinator`'s two replicas are both `Running`, `1/1`, nothing crashing — but no leader is ever elected and `kubectl get lease call-coordinator -n call-routing` returns `NotFound`. The singleton work never runs: the workload is up but idle. Pod health is a red herring.

**Think about this before you open the answer:**

That a leaderless singleton sends you to the Lease and its RBAC, not the Pods. Self-grading:

- Did you look for the Lease (and find it absent) rather than restarting the "idle" Pods?
- Did you use `auth can-i --as=system:serviceaccount:…` to prove the permission gap in one line, instead of guessing?
- Did you fix the Role's *verbs* on `leases` (`get`/`create`/`update`), not the RoleBinding, the ServiceAccount, or the Deployment?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

Acquiring a Lease means *writing* that object (`get`, then `create` on first win, then `update` to renew), and the client does this as its Pod's ServiceAccount<sup><a href="https://kubernetes.io/docs/concepts/architecture/leases/">[5]</a></sup>. The `leader-election` Role bound to the `coordinator` ServiceAccount grants only `list` and `watch` on `leases` — the `get`, `create`, and `update` verbs the election client needs are missing. The identity can *see* Leases but never *hold* one, so it's forbidden from the lock, no Lease is ever created, and no replica leads<sup><a href="https://kubernetes.io/docs/reference/access-authn-authz/rbac/">[6]</a></sup>. (In a real controller the client logs `leases.coordination.k8s.io … is forbidden` and retries forever.)

**Diagnostic commands (run in this order):**

```bash
# 1. Pods up, but the leadership lock is absent
kubectl get pods -n call-routing -l app=call-coordinator   # both 1/1 Running
kubectl get lease call-coordinator -n call-routing         # Error ... NotFound

# 2. Can the SA acquire the lock? Impersonate it with --as
kubectl auth can-i get    leases.coordination.k8s.io -n call-routing --as=system:serviceaccount:call-routing:coordinator
kubectl auth can-i create leases.coordination.k8s.io -n call-routing --as=system:serviceaccount:call-routing:coordinator
kubectl auth can-i update leases.coordination.k8s.io -n call-routing --as=system:serviceaccount:call-routing:coordinator
#    all three: no

# 3. Find the gap in the Role behind the binding
kubectl describe rolebinding leader-election -n call-routing
kubectl get role leader-election -n call-routing -o yaml | grep -A4 'coordination.k8s.io'   # only list, watch
```

**Exact fix:**

A Role is freely mutable — re-apply it with the full leader-election verb set. No Pod restart is needed; the binding already points at it:

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: leader-election, namespace: call-routing }
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
EOF
```

**Verify:**

```bash
# The permission (root-cause fix) is restored
for v in get create update; do
  kubectl auth can-i $v leases.coordination.k8s.io -n call-routing \
    --as=system:serviceaccount:call-routing:coordinator; done          # yes, yes, yes
# Prove it end to end — acquire the lock AS the SA, exactly as the client would
kubectl create -f - --as=system:serviceaccount:call-routing:coordinator <<'EOF'
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata: { name: call-coordinator, namespace: call-routing }
spec: { holderIdentity: call-coordinator-leader, leaseDurationSeconds: 15 }
EOF
kubectl get lease call-coordinator -n call-routing                     # exists, with a HOLDER
```

**Production thinking:**

A leaderless singleton with healthy Pods is almost always RBAC on the lock object — the Pods being up tells you nothing, because leadership lives in the Lease and the ability to take it lives in the Role<sup><a href="https://kubernetes.io/docs/reference/access-authn-authz/rbac/">[6]</a></sup>. Two related failures wear the same face: a challenger that can't take over a dead leader's stale Lease (same RBAC gap on the standby) and a `leaseDuration`/`renewDeadline` misconfig that lets a healthy leader be declared dead — a split-brain. Keep the invariant `leaseDuration > renewDeadline > retryPeriod` in your election config, and remember a Lease is a *cooperative* lock, not a fence<sup><a href="https://kubernetes.io/docs/concepts/architecture/leases/">[5]</a></sup>: if two writers at once would corrupt data, the fencing (a monotonic token the shared resource rejects on) has to live in the resource, not the Lease.

</details>

---
