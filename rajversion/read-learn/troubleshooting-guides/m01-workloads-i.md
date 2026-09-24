# `m01-workloads-i/` — M01 — Workloads I: Pods, Deployments, ReplicaSets

**Category:** Pod lifecycle & probes

Concept reading: `m01-workloads-i/LESSON.md`

## Break/fix 01 — Liveness Restart Loop

**Symptom — what you'd actually see:**

Alert: `route-engine` in `call-routing` is in `CrashLoopBackOff`. The restart count climbs every ~15 seconds.

**Think about this before you open the answer:**

Not fixing a probe path — that's trivial. The lesson is **telling a real crash from a probe killing a healthy app** before you waste an incident debugging code that was never broken. Self-grading questions:

- Did you run `kubectl logs --previous` and notice the log was *clean*?
- Did you read `describe` and spot `Liveness probe failed` + `Killing` (probe) versus a bare `Terminated/Error` with no probe events (real crash)?
- Did you resist "the app is broken, let me read the code" and instead ask "what's killing it"?

<details>
<summary>📖 Going deeper: should this workload have a liveness probe at all?<sup><a href="https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/">[1]</a></sup></summary>

Liveness is a blunt instrument: its only action is restart. That helps exactly one failure class — a process wedged in a state only a restart clears (a deadlock it can't detect itself). For everything else, restarting is either useless or harmful:

- **Dependency down?** Restarting won't bring the database back; it just adds churn. Use readiness — stop taking traffic, keep the process, rejoin when the dependency recovers.
- **Slow under load?** A tight liveness timeout fires during a latency spike and restarts a busy-but-healthy pod, making the spike worse — a cascading-restart outage.

Rule of thumb: **default to no liveness probe.** Add one only when you can name the wedged state it rescues, and make it conservative (generous `timeoutSeconds`, `failureThreshold` ≥ 3). Use a `startupProbe` for slow boots rather than a long `initialDelaySeconds` on liveness.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

A `livenessProbe` with `httpGet` `path: /healthz` — a path nginx doesn't serve, so it returns `404`. Only HTTP `200`–`399` pass a probe, so liveness fails every period and the kubelet kills and restarts a perfectly healthy container<sup><a href="https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/">[1]</a></sup>. The `CrashLoopBackOff` is the kubelet backing off between those forced restarts<sup><a href="https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#restart-policy">[2]</a></sup> — not an application crash.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm it's a loop, not a one-off — restart count rising
kubectl get pods -n call-routing
```

```bash
# 2. Ask the dead container what happened. Clean log that just stops = app didn't crash.
POD=$(kubectl get pod -n call-routing -l app=route-engine -o jsonpath='{.items[0].metadata.name}')
kubectl logs $POD -n call-routing --previous
```

```bash
# 3. Find the killer. Liveness events + Killing = probe, not crash.
kubectl describe pod $POD -n call-routing
# Events: Liveness probe failed: HTTP probe failed with statuscode: 404
#         Killing container ... failed liveness probe
```

```bash
# 4. Read the offending probe — Pod Template's Liveness: line
kubectl describe deploy route-engine -n call-routing
#   Liveness:  http-get http://:http/healthz delay=0s timeout=1s period=10s #success=1 #failure=3
#   nginx serves / , not /healthz → every probe 404s
```

**Exact fix:**

```bash
# Option A: point the probe at a path the app serves
kubectl patch deployment route-engine -n call-routing --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/"}]'

# Option B: kubectl edit, change path: /healthz → path: /
# Option C: if there's no real health endpoint, remove the liveness probe — a
#           wrong liveness probe is worse than none.
```

**Verify:**

```bash
kubectl rollout status deployment route-engine -n call-routing
kubectl get pods -n call-routing -w
# RESTARTS stops climbing; pods stay Running 1/1 READY
```

**Production thinking:**

The live `kubectl patch` stops the bleeding, but the bad probe is in your manifests — on the next Flux reconciliation the cluster drifts back to crash-looping. Real fix: PR to `platform-gitops` correcting (or removing) the probe, let Flux re-apply, then ask how a probe that never passed got merged — should CI have caught a liveness probe pointing at an unserved path? `kubectl` changes are temporary unless the source of truth agrees (Flux and the GitOps loop come in M18).

</details>

---

## Break/fix 02 — Readiness Traffic Blackhole

**Symptom — what you'd actually see:**

Alert: callers of the `directory` service in `app-services` get connection errors. The pods are `Running`. Nothing is restarting.

**Think about this before you open the answer:**

The readiness-vs-liveness distinction made concrete, and the readiness → Endpoints link. Self-grading questions:

- Did you read the `READY` column instead of stopping at `Running`?
- Did you check `kubectl get endpoints` — the command that proves the Service has no backends?
- Did you notice there were **no restarts and no `Killing` events**, and correctly conclude readiness (not liveness) was the cause?

<details>
<summary>📖 Going deeper: when readiness blackholes the whole service at once<sup><a href="https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/">[1]</a></sup></summary>

Readiness is gentle per-Pod, but it has a dangerous failure mode at the fleet level. If a readiness probe checks a **shared downstream dependency** (the same database every replica uses), then when that dependency blips, *every replica fails readiness simultaneously* — and the Service drops to zero endpoints all at once. You've converted a brief dependency hiccup into a total outage of your own service.

Two guards:

- Keep readiness **local** — probe "can this process serve?", not "is the whole backend healthy?". Let a request to the dependency fail and be retried rather than de-registering every pod.
- If you must gate on a dependency, make the probe tolerant (high `failureThreshold`, longer `periodSeconds`) so a short blip doesn't empty the Service.

The general principle: a health check that all replicas evaluate identically against a shared input is a single point of failure wearing a health-check costume.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

A `readinessProbe` with `httpGet` `port: 8080`, but the container serves on `80`. The probe gets `connection refused` every period, so the Pod's `Ready` condition never goes true. A failing readiness probe does **not** restart the container — it removes the Pod from the Service's Endpoints<sup><a href="https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/">[1]</a></sup>. With every replica unready, the Service has zero backends and blackholes traffic<sup><a href="https://kubernetes.io/docs/concepts/services-networking/service/">[3]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Read past the phase — Running but 0/1 READY, 0 RESTARTS
kubectl get pods -n app-services -l app=directory
```

```bash
# 2. Confirm the blackhole at the Service — no endpoints
kubectl get endpoints directory -n app-services
# ENDPOINTS   <none>
```

```bash
# 3. Why isn't it Ready? Conditions: Ready False, and NO Killing event (readiness ≠ restart)
POD=$(kubectl get pod -n app-services -l app=directory -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod $POD -n app-services
# Conditions:  Ready  False
# Events:      Readiness probe failed: dial tcp 10.x.x.x:8080: connect: connection refused
```

```bash
# 4. Read the probe vs the served port — Pod Template's Port: and Readiness: lines
kubectl describe deploy directory -n app-services
#   Port:       80/TCP
#   Readiness:  http-get http://:8080/ ...   ← probes 8080, container serves 80
```

**Exact fix:**

```bash
# Point readiness at the served port. Named port 'http' is cleaner than a literal 80.
kubectl patch deployment directory -n app-services --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":"http"}]'
# or kubectl edit, change port: 8080 → port: http (or 80)
```

**Verify:**

```bash
kubectl rollout status deployment directory -n app-services
kubectl get endpoints directory -n app-services
# ENDPOINTS now lists IP:80 entries — backends restored
kubectl get pods -n app-services -l app=directory
# Running, 1/1 READY
```

**Production thinking:**

Same GitOps story as breakfix-01 — patch to recover, PR to `platform-gitops` for the durable fix. The deeper question is detection: a probe that never passes should fail in staging, not production. Why did a readiness probe on the wrong port reach prod — no smoke test that the Service had endpoints after deploy? A synthetic check on `kubectl get endpoints <svc>` post-rollout would have caught it.

</details>

---

## Break/fix 03 — preStop Truncation

**Symptom — what you'd actually see:**

Report: `session-broker` in `media` drops in-flight call sessions every time it's rolled or scaled. `kubectl get pods` shows nothing wrong — the pod is `Running` and `Ready`.

**Think about this before you open the answer:**

Reading the termination sequence, and recognizing that a healthy-looking pod can still fail on shutdown. Self-grading questions:

- Did you look at the *shutdown controls* (`terminationGracePeriodSeconds`, `preStop`) instead of hunting for a problem in `get pods` (where there isn't one)?
- Did you reproduce the failure by **timing a delete**, rather than guessing?
- Did you fix it by sizing the budget to the drain — *keeping* the drain — rather than deleting the `preStop` hook to make the symptom vanish?

<details>
<summary>📖 Going deeper: grace-period accounting and the PID-1 trap<sup><a href="https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination">[2]</a></sup></summary>

The full sequence, precisely: on deletion the Pod is marked `Terminating` and removed from Endpoints; the kubelet runs `preStop`; then sends `SIGTERM` to PID 1; then waits out the remainder of `terminationGracePeriodSeconds`; then `SIGKILL`. `preStop` and the post-`SIGTERM` wait **share** the one budget. If `preStop` alone exceeds it, the kubelet grants a single ~2-second extension and kills — enough to unwind, not to finish a real drain. Size for `preStop` + app shutdown + headroom; don't lean on the extension.

Two traps beyond sizing:

1. **PID-1 signal forwarding.** `SIGTERM` goes to PID 1 in the container. If the image runs the app under a shell (`sh -c "app"`), the shell is PID 1 and often won't forward the signal — the app never hears `SIGTERM` and gets `SIGKILL`ed at grace expiry no matter how long the budget is. Use exec-form `CMD`, a tiny init like `tini`, or ensure the app itself is PID 1.

2. **Measuring, not guessing.** Don't pick the grace period by gut. Measure the real drain: how long does the longest in-flight unit of work take to complete (a media leg, a long request, a websocket close)? Set the grace period to the p99 of that plus headroom. Too low truncates work; too high makes rollouts and node drains crawl (every pod takes the full budget to leave).

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

A `preStop` hook that drains for 15 seconds (`sleep 15`), behind a `terminationGracePeriodSeconds: 1`. The grace period is the total shutdown budget — `preStop` plus `SIGTERM` handling both spend from it<sup><a href="https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/">[4]</a></sup>. With only 1 second, the kubelet grants one short (~2s) extension and then `SIGKILL`s the container while `preStop` is still draining<sup><a href="https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination">[2]</a></sup>. The drain is truncated on every termination, so in-flight sessions die.

**Diagnostic commands (run in this order):**

```bash
# 1. The bug is in the shutdown path — read the controls in the spec (describe hides them)
kubectl get deploy session-broker -n media -o yaml
#   terminationGracePeriodSeconds: 1        <- 1s budget
#   lifecycle: { preStop: { exec: { command: ["/bin/sleep","15"] } } }   <- 15s drain
```

```bash
# 2. Reproduce + time it. A delete runs the same sequence as a rollout/scale-down.
POD=$(kubectl get pod -n media -l app=session-broker -o jsonpath='{.items[0].metadata.name}')
time kubectl delete pod $POD -n media
# returns in ~1-3s, not the ~15s the drain needs → drain was cut short
```

**Exact fix:**

```bash
# Size the grace period to exceed the drain (15s) with headroom. Keep the drain.
kubectl patch deployment session-broker -n media \
  -p '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":30}}}}'
# or kubectl edit, terminationGracePeriodSeconds: 1 → 30
```

**Verify:**

```bash
kubectl rollout status deployment session-broker -n media
POD=$(kubectl get pod -n media -l app=session-broker -o jsonpath='{.items[0].metadata.name}')
time kubectl delete pod $POD -n media
# now blocks ~15s — the full drain runs to completion before the pod exits
```

**Production thinking:**

The patch fixes one workload; the pattern is what matters. Audit every workload that holds in-flight state (media, websockets, long requests) for a grace period that actually fits its drain — and tie it to node operations: `kubectl drain` and node autoscaling both respect `terminationGracePeriodSeconds`, so an undersized one drops work during routine node maintenance, not just deploys. Durable fix lives in `platform-gitops`; the audit and the measurement method are the real deliverable.

</details>

---
