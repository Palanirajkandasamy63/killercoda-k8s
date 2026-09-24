# `m09-resilience-autoscaling/` — M09 — Resilience & Autoscaling

**Category:** Resilience & autoscaling (PDB, HPA, rollouts)

Concept reading: `m09-resilience-autoscaling/LESSON.md`

## Break/fix 01 — PDB Blocks Drain

**Symptom — what you'd actually see:**

A `kubectl drain` of the worker for a kernel patch hangs — the eviction it attempts comes back `TooManyRequests: Cannot evict pod as it would violate the pod's disruption budget`. `sip-registrar` in `signaling` is healthy the whole time (`2/2` Running); nothing is crashing or `Pending`.

**Think about this before you open the answer:**

Recognizing that a blocked drain is a budget problem, and the allowed-disruptions math. Self-grading:

- Did you read the *PDB's* status (`ALLOWED DISRUPTIONS 0`) rather than hunting for an unhealthy Pod (there isn't one)?
- Did you connect `minAvailable == replicas` to `allowedDisruptions = 0`, and understand *why* that blocks every eviction?
- Did you fix it by lowering the floor (or moving to `maxUnavailable`), not by deleting the PDB outright (which removes the protection entirely)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`sip-registrar`'s PodDisruptionBudget has `minAvailable: 2` — equal to the Deployment's replica count. Allowed disruptions is `currentHealthy − desiredHealthy = 2 − 2 = 0`, so the eviction API permits no voluntary eviction at all<sup><a href="https://kubernetes.io/docs/concepts/workloads/pods/disruptions/">[3]</a></sup>. A drain is a series of evictions, so it blocks indefinitely. The budget meant to protect the service instead protects it into un-maintainability.

**Diagnostic commands (run in this order):**

```bash
# 1. The budget, not the workload — read allowed disruptions
kubectl get pdb -n signaling                       # sip-registrar: ALLOWED DISRUPTIONS 0

# 2. See the refusal against the real eviction API (safe: one Pod, recreated)
POD=$(kubectl get pod -n signaling -l app=sip-registrar -o jsonpath='{.items[0].metadata.name}')
cat <<EOF > /tmp/evict.json
{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"$POD","namespace":"signaling"}}
EOF
kubectl create --raw "/api/v1/namespaces/signaling/pods/$POD/eviction" -f /tmp/evict.json
#    Error ... TooManyRequests ... Cannot evict pod ... disruption budget

# 3. The math and the offending field
kubectl describe pdb sip-registrar -n signaling    # Current Healthy 2, Desired Healthy 2, Allowed Disruptions 0
kubectl get pdb sip-registrar -n signaling -o jsonpath='{.spec.minAvailable}'; echo   # 2 (== replicas)
```

**Exact fix:**

Give the budget headroom — `minAvailable` below the replica count:

```bash
kubectl patch pdb sip-registrar -n signaling --type merge -p '{"spec":{"minAvailable":1}}'
# or switch to maxUnavailable: 1 (better when an HPA moves the replica count)
```

**Verify:**

```bash
kubectl get pdb sip-registrar -n signaling         # ALLOWED DISRUPTIONS 1
# the eviction from step 2, re-run, now succeeds and the Deployment restores 2/2
```

**Production thinking:**

A blocked drain is more often a bad PDB than a bad node — `kubectl get pdb -A` with `ALLOWED DISRUPTIONS 0` is the fast check when maintenance stalls. Express budgets as `maxUnavailable` for HPA-driven workloads (a fixed `minAvailable` drifts between "block everything" and "protect nothing" as replicas scale), never set the floor at the replica count, and alert on drains that exceed a timeout. Remember the limits: a PDB constrains only *voluntary* disruption — it does nothing for a node crash, and a plain `kubectl delete pod` bypasses it entirely<sup><a href="https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/">[5]</a></sup>. The Cluster Autoscaler's scale-down also removes nodes through the eviction API, so a sane PDB protects a service from being drained off a node the autoscaler decides to reclaim<sup><a href="https://kubernetes.io/docs/concepts/cluster-administration/node-autoscaling/">[7]</a></sup>.

</details>

---

## Break/fix 02 — HPA Can't Read Its Metric

**Symptom — what you'd actually see:**

`transcode-scaler` in `media` has an HPA, but `kubectl get hpa` shows `TARGETS <unknown>/50%` and it never scales off `1` replica regardless of load. metrics-server is healthy — `kubectl top pods -n media` returns live CPU for the Pod.

**Think about this before you open the answer:**

Reading an HPA's condition to find *why* it's dead, and the request-is-the-denominator rule. Self-grading:

- Did you treat `<unknown>` as "can't read the metric," and go to `describe hpa` Conditions rather than assuming a metrics outage?
- Did you connect `FailedGetResourceMetric` / `missing request for cpu` to the target's missing request, not to metrics-server?
- Did you fix the **request** (the denominator), and understand why the container's memory *limit* was irrelevant to a CPU-utilization HPA?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The HPA targets CPU *utilization*, which it computes as `usage ÷ request`, but `transcode-scaler`'s container declares no CPU request. With no denominator the utilization is undefined, so the HPA can't get the metric: `ScalingActive False`, reason `FailedGetResourceMetric`, message `missing request for cpu`<sup><a href="https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/">[1]</a></sup>. The metrics pipeline is fine; the gap is on the target.

**Diagnostic commands (run in this order):**

```bash
# 1. The unknown target — the metric can't be read, it isn't "0% load"
kubectl get hpa -n media                           # transcode-scaler: <unknown>/50%, REPLICAS 1

# 2. The HPA states the reason in its conditions
kubectl describe hpa transcode-scaler -n media     # ScalingActive False, FailedGetResourceMetric, "missing request for cpu"

# 3. Confirm the target has no CPU request; contrast with the working one
kubectl get deployment transcode-scaler -n media -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo   # {"limits":{"memory":"128Mi"}}
kubectl get deployment sip-router -n signaling -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'; echo   # cpu: 25m (has a denominator)
```

**Exact fix:**

Add a CPU request to the target:

```bash
kubectl set resources deployment/transcode-scaler -n media --requests=cpu=100m
# or: kubectl edit deployment transcode-scaler -n media  → add resources.requests.cpu
```

**Verify:**

```bash
# give metrics-server ~15-30s for a sample of the new Pod
kubectl get hpa transcode-scaler -n media          # TARGETS now a real %, e.g. 1%/50%
kubectl describe hpa transcode-scaler -n media | grep -A5 Conditions   # ScalingActive True
```

**Production thinking:**

No request is the top reason an HPA reads `<unknown>`. Enforce requests on autoscaled workloads with a `LimitRange` or admission policy (M20) so a Deployment can't ship without one. Size the request honestly: the target percentage is relative to it, so a too-small request makes the workload look busy (over-scale) and a too-large one hides load (under-scale) — the same M06 request now doing double duty as the autoscaler's 100% mark. If you can't size it by hand, VPA recommends requests from observed usage<sup><a href="https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler">[8]</a></sup> (but don't run it *and* an HPA on the same resource — they fight). And pick the right metric: a CPU HPA can't see a queue backlog, which is what KEDA is for<sup><a href="https://keda.sh/docs/latest/concepts/">[9]</a></sup>.

</details>

---

## Break/fix 03 — Stuck Rollout

**Symptom — what you'd actually see:**

A `portal-web` release in `admin-portal` has been rolling out for minutes and `kubectl rollout status` never returns. The service is up (users unaffected), but `kubectl get deployment` shows `READY 2/2`, `AVAILABLE 2`, `UP-TO-DATE 1` — only one Pod is the new version.

**Think about this before you open the answer:**

Diagnosing a stuck rollout on the Deployment's own state, and knowing rollback is the fast recovery. Self-grading:

- Did the "service is fine but the rollout won't finish" split point you at the *new* ReplicaSet's Pods rather than at the running old ones?
- Did you read `ProgressDeadlineExceeded` and the bad image, instead of restarting Pods or scaling in the hope it clears?
- Did you recover with `rollout undo` (or a corrected roll-forward), and note that Kubernetes never rolled back on its own?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

Revision 2 set the image to `nginx:1.25-doesnotexist`, a tag not in the registry. The new ReplicaSet's Pod can't pull it (`ImagePullBackOff`); because the default `maxUnavailable` rounds down to `0` for 2 replicas, the Deployment won't retire an old Pod until the new one is Ready — which never happens — so the rollout stalls with the old version still serving<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/deployment/">[2]</a></sup>. After `progressDeadlineSeconds` (60), `Progressing=False, ProgressDeadlineExceeded`. Kubernetes reports the stall but does not auto-roll-back.

**Diagnostic commands (run in this order):**

```bash
# 1. Rollout not done — new version partial, old still serving
kubectl get deployment portal-web -n admin-portal            # READY 2/2, UP-TO-DATE 1
kubectl rollout status deployment/portal-web -n admin-portal --timeout=10s
#    Waiting ... 1 out of 2 new replicas have been updated

# 2. The broken new ReplicaSet
kubectl get rs -n admin-portal -l app=portal-web             # new RS 0 ready
kubectl get pods -n admin-portal -l app=portal-web           # one ImagePullBackOff

# 3. Why it's stuck, and the offending image
kubectl describe deployment portal-web -n admin-portal | grep -A8 Conditions   # Progressing False, ProgressDeadlineExceeded
kubectl get deployment portal-web -n admin-portal -o jsonpath='{.spec.template.spec.containers[0].image}'; echo   # nginx:1.25-doesnotexist
kubectl rollout history deployment/portal-web -n admin-portal   # rev1 good, rev2 bad
```

**Exact fix:**

Roll back to the last good revision:

```bash
kubectl rollout undo deployment/portal-web -n admin-portal
kubectl rollout status deployment/portal-web -n admin-portal   # successfully rolled out
# roll-forward alternative: kubectl set image deployment/portal-web app=nginx:1.25 -n admin-portal
```

**Verify:**

```bash
kubectl get deployment portal-web -n admin-portal            # READY 2/2, UP-TO-DATE 2, AVAILABLE 2
kubectl get deployment portal-web -n admin-portal -o jsonpath='{.spec.template.spec.containers[0].image}'; echo   # nginx:1.25
```

**Production thinking:**

The rolling update failing *safe* — stalling, not crashing — is the feature that saved you here, but it also means a bad deploy can sit half-rolled and silent. Alert on `Progressing=False`/`ProgressDeadlineExceeded`, not just on error rate (the old version masks it). The durable prevention is upstream: a readiness probe so a bad Pod is never counted Ready, a canary or progressive rollout, and a pipeline that verifies the image exists (M02) and rolls back automatically on a deadline breach. Rollback is the emergency lever; roll-forward with a fixed image is right when the fix is trivial and you'd rather not lose the revision's other changes.

</details>

---
