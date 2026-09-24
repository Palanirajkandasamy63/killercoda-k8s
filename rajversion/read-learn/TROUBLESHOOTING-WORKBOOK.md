# Polyphone Killercoda Lab — Full Troubleshooting Workbook

This is the detailed version: for every break/fix scenario across all modules, the exact symptom, the questions to ask yourself, then (behind a collapsed **"Click to reveal"** section) the exact `kubectl` diagnostic commands in order, the root cause, the exact fix commands, and the verify command.

**How to practice:** read the Symptom + Think section, try to diagnose for real in the Killercoda scenario, THEN expand the answer to check yourself.

---

# `m00-foundations/` — M00 — Mental Model & kubectl Fluency

**Category:** Diagnostic fundamentals (kubectl / cluster awareness)

Concept reading: `m00-foundations/LESSON.md`

## Break/fix 01 — Context Blindness

**Symptom — what you'd actually see:**

Alert fires that Polyphone workloads are degraded. You run `kubectl get pods` and get back:

```text
No resources found in default namespace.
```

The cluster appears empty. But the alert says workloads are unhealthy. Something doesn't add up.

**Think about this before you open the answer:**

- Did you reach for `kubectl get pods -A` BEFORE assuming the cluster was broken? That single command separates "view is wrong" from "cluster is wrong" in 2 seconds.
- Did you read the error message carefully? `"No resources found in default namespace"` literally told you the scope.
- Do you know `kubectl config current-context` (which cluster/user/namespace combo is active) and `kubectl config view --minify` (the full settings)?

The anti-pattern: assume the cluster is broken, start poking at individual workloads, waste 15 minutes before noticing the prompt says you're in the wrong place.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The kubeconfig's default namespace is set explicitly to `default` (which is empty — Polyphone workloads all live in named namespaces like `app-services`, `media`, etc.). The cluster is fully healthy; the operator's *view* of it is misconfigured<sup><a href="https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. FIRST move: confirm the cluster isn't actually broken
kubectl get pods -A
# The cluster is fully populated. So the issue is with your view.

# 2. Re-read the original error message carefully
#    "No resources found in default namespace."
#    kubectl is telling you exactly where it looked

# 3. Confirm what your kubeconfig says
kubectl config current-context
kubectl config view --minify
# Shows context's namespace: default
kubectl config get-contexts
# The * row's NAMESPACE column also shows default
```

**Exact fix:**

```bash
# Scope to a workload namespace. The fleet has 10 named namespaces
# (app-services, media, signaling, admin-portal, analytics, …) — pick
# whichever fits the task at hand.
kubectl config set-context --current --namespace=app-services
```

**Verify:**

```bash
kubectl config view --minify | grep namespace:
# namespace: app-services  (or whichever you set)
kubectl get pods
# Shows the namespace's workloads — visible proof the cluster was
# always healthy, your view was scoped wrong.
```

**Production thinking:**

Three operational practices that make this class of incident impossible:

1. **Shell prompt customization** — show `<context>:<namespace>` in your prompt at all times (e.g., [kube-ps1](https://github.com/jonmosco/kube-ps1)). If you can see "prod-us-east-1:default" in your prompt, you'll never get surprised by a misconfigured scope.
2. **Separate terminals per environment** — don't share a terminal between prod and lab. Different windows, different colors, different tmux sessions. Make context-switching require deliberate action.
3. **Read-only contexts for prod by default** — kubeconfig maps prod to a read-only user; switching to write-capable is a deliberate, separate action. Cuts wrong-cluster mutations to near-zero.

</details>

---

## Break/fix 02 — Namespace Blindness

**Symptom — what you'd actually see:**

An alert fires: "Polyphone fleet — one or more workloads degraded." No namespace, no workload name, no hint about what's wrong.

**Think about this before you open the answer:**

The lesson is not fixing an image typo — that's trivial. The lesson is **finding the broken thing without being told where**. Self-grading questions:

- Did your first command include `-A`? That's the single biggest separator between strong and weak diagnostic flow.
- Did you reach for `kubectl get events -A --sort-by='.lastTimestamp'`? That command surfaces the failure as plain text in seconds. If you found the problem without it, fine — but build the habit, because some failures are event-only (the Pod shows no symptom; the event on the owning ReplicaSet does).
- Did you open one namespace at a time, hoping to guess right? That's the anti-pattern. It scales linearly with cluster size and feels productive while wasting minutes.

<details>
<summary>📖 Going deeper: <code>--field-selector</code> is the senior's <code>grep</code><sup><a href="https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/">[3]</a></sup></summary>

`kubectl get pods -A` returns everything. Real clusters have thousands of Pods; that output is unreadable. Three flags make it tractable:

- `--field-selector=status.phase!=Running,status.phase!=Succeeded` — only the unhappy ones (`Succeeded` is a good terminal state for Job/CronJob pods and for some lab helpers like `local-path-provisioner`)
- `--field-selector=spec.nodeName=<node>` — only Pods on a specific node (useful when triaging a node-level issue)
- `-o jsonpath='...'` — extract only the field you care about

Combine them:

```bash
# All non-Running pods cluster-wide, with their namespace and phase
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase
```

The list of selectable fields per resource is limited (Kubernetes doesn't index every field for selection)<sup><a href="https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/">[3]</a></sup>. The most useful set: `metadata.name`, `metadata.namespace`, `spec.nodeName`, `status.phase`. Everything else needs `jq` or jsonpath on the output.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `metrics-aggregator` Deployment in the `analytics` namespace has its container image set to `nginx:doesnotexist-1.25-foobar`. Pods are stuck in `ImagePullBackOff` — the kubelet's status for "I tried to pull this image, the registry said no, and I'm now backing off retries"<sup><a href="https://kubernetes.io/docs/concepts/containers/images/#imagepullbackoff">[2]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Scan cluster-wide — the M00 instinct
kubectl get pods -A
# One workload stands out: STATUS = ImagePullBackOff or ErrImagePull, namespace = analytics
```

```bash
# 2. OR sort events cluster-wide — often faster
kubectl get events -A --sort-by='.lastTimestamp' | tail -30
# "Failed to pull image" events bubble to the bottom
```

```bash
# 3. Zoom in
kubectl describe pod -n analytics -l app=metrics-aggregator
# Events section: Failed to pull image "nginx:doesnotexist-1.25-foobar"
```

**Exact fix:**

```bash
# Option A: kubectl set image (one-liner; good for the immediate recovery)
kubectl set image deployment/metrics-aggregator app=nginx:1.25 -n analytics

# Option B: kubectl edit (good when you want to inspect the whole manifest)
kubectl edit deployment metrics-aggregator -n analytics
# Change spec.template.spec.containers[0].image to nginx:1.25
```

**Verify:**

```bash
# -w watches until you Ctrl-C; the new Pod transitions through Pending -> Running
kubectl get pods -n analytics -w
```

When done, confirm the fleet is back to green:

```bash
kubectl get pods -A -l plane --field-selector=status.phase!=Running --no-headers | wc -l
# Expect 0 (or a brief transient as old ReplicaSets clean up).
# `-l plane` scopes to Polyphone workloads; otherwise `-A` also surfaces
# cluster-service helpers in `Succeeded` phase, which inflates the count.
```

**Production thinking:**

`kubectl set image` is a bandaid. It works, but the change isn't reflected in your GitOps source of truth. On the next Flux reconciliation, the cluster could drift back to the broken state — or worse, your fix gets reverted when an unrelated PR merges. The production fix:

1. Triage with `kubectl set image` to stop the bleeding.
2. Open a PR to `platform-gitops` correcting the manifest.
3. Let Flux re-apply the corrected manifest, eliminating the out-of-band fix.
4. Post-mortem: how did the bad image tag merge in the first place? Should CI block deployments referencing non-existent images?

`kubectl` changes are temporary unless the source of truth agrees. You'll meet Flux and the GitOps loop in M18. For now, take away the principle.

</details>

---

## Break/fix 03 — Event-Only Failure

**Symptom — what you'd actually see:**

Alert fires that `port-processor` Deployment in `number-porting` is short a replica (`desired=3, available=2`). The pods that exist are `Running`, `1/1 READY`. `kubectl describe pod` shows nothing wrong.

**Think about this before you open the answer:**

- Did you reach for `kubectl get events` or `kubectl describe rs` when pod-level checks came up empty? That's the climb-the-owner-chain instinct.
- Did you recognize that `kubectl describe pod` can only show events on Pods? When the failure is "the Pod never got created in the first place," the event lives on whoever tried to create it (the ReplicaSet).
- Did you stop to ask "should I raise the quota or reduce replicas?" instead of mechanically running one fix? Quotas exist for a reason; the production answer depends on whether the quota was wrong or the replica count was wrong.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The namespace's `ResourceQuota` caps total pods at 2, but the Deployment wants 3. The Pod that can't be created produces a `FailedCreate` event on the **ReplicaSet** (not on any Pod, because there's no Pod to attach the event to)<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/">[4]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm the gap
kubectl get deploy port-processor -n number-porting
# READY 2/3 — the Deployment is unsatisfied

# 2. Pods themselves are fine
kubectl get pods -n number-porting
kubectl describe pod -n number-porting -l app=port-processor
# Nothing wrong with the 2 pods that exist

# 3. Climb the owner chain
kubectl describe rs -n number-porting -l app=port-processor
# Events: FailedCreate ... pods "..." is forbidden: exceeded quota
```

```bash
# Shortcut: events surface this in seconds
kubectl get events -n number-porting --sort-by='.lastTimestamp'
# Same FailedCreate event, no chain-climbing required
```

```bash
# Confirm the quota
kubectl get resourcequota -n number-porting
# NAME        REQUEST     LIMIT   AGE
# pod-limit   pods: 2/2           ...   <- used/hard for pods. The deployment wants 3.

# For the full breakdown (used, hard, scopes), use describe:
kubectl describe resourcequota pod-limit -n number-porting
# Resource  Used  Hard
# pods      2     2
```

**Fix (two valid options):**

```bash
# Option A: raise the quota to match demand (use when 3 replicas was the intended count)
# Set to 3 — exactly what the Deployment needs, no headroom. Adding headroom is a
# capacity-planning question, not a triage one; do it via PR with justification.
kubectl patch resourcequota pod-limit -n number-porting --type=merge \
  -p '{"spec":{"hard":{"pods":"3"}}}'

# Option B: reduce replicas (use when 2 was the intended count)
kubectl scale deployment port-processor --replicas=2 -n number-porting
```

**Exact fix:**

**Verify:**

```bash
kubectl get deploy port-processor -n number-porting
# READY 3/3 (option A) or 2/2 (option B)
kubectl get events -n number-porting --sort-by='.lastTimestamp' | tail -5
# Should now show SuccessfulCreate, not FailedCreate
```

<details>
<summary>📖 Going deeper: the ReplicaSet didn't heal — what now?<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/">[4]</a></sup></summary>

A common gotcha after fixing the quota: you patch `hard: pods: "3"`, you confirm the new value with `kubectl get resourcequota`, and the deployment is **still** stuck at `READY 2/3`. Fresh events still show `limited: pods=2`.

Two things to check:

1. **Is the event actually fresh?** Sort by `lastTimestamp` and look at the timestamp on the latest `FailedCreate`. If it's minutes old, it's stale — the message text was frozen when the event fired and isn't re-evaluated. Events stick around for ~1 hour by default.

2. **Is the ReplicaSet on its backoff timer?** If spacing between `FailedCreate` events looks like `30s → 1m → 2m → 4m → 8m`, the ReplicaSet controller is doing exponential backoff on pod creation. It doesn't watch the quota; it's just waiting for its next retry window. The deployment can sit at 2/3 for ~15 minutes before the controller tries again on its own.

Three nudges, in order of cleanliness:

```bash
# A. Rollout restart — creates a NEW ReplicaSet with zero backoff history.
kubectl rollout restart deployment/port-processor -n number-porting

# B. Scale-down/scale-up — resets the gap to 0, forces a fresh evaluation.
kubectl scale deploy/port-processor --replicas=2 -n number-porting && \
kubectl scale deploy/port-processor --replicas=3 -n number-porting

# C. Delete a healthy pod — the RS reconciles on the delete (no backoff path).
kubectl delete pod -n number-porting -l app=port-processor --limit=1
```

The teaching point: **fixing the root cause doesn't always heal the workload automatically.** Controllers with backoff need a kick. This is one of the most common reasons `kubectl rollout restart` exists in an SRE's muscle memory — it's not just for picking up new ConfigMap values, it's also for breaking controllers out of failure-retry loops after you've removed the underlying obstacle.

</details>

**Production thinking:**

`ResourceQuota` is a guardrail. Raising it to bypass a failure trains the wrong instinct — eventually quotas don't constrain anything. The real fix lives in `platform-gitops`: either justify the higher quota via PR (capacity review, cost) or revert the replica change that triggered the breach. `kubectl patch` is triage; Flux will overwrite it on next reconciliation unless the source of truth agrees.

</details>

---

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

# `m01b-workloads-batch/` — M01b — Workloads: Jobs & CronJobs

**Category:** Jobs & CronJobs

Concept reading: `m01b-workloads-batch/LESSON.md`

## Break/fix 01 — CronJob Never Fires

**Symptom — what you'd actually see:**

Report: the `cdr-rollup` CronJob in `cdr-storage` hasn't produced output. No recent Jobs, no Pods, no error logs, no events. Billing reconciliation drifting on stale CDRs.

**Think about this before you open the answer:**

Not flipping a boolean — that's trivial. The skill is the **differential for a CronJob that creates nothing**, so you don't go spelunking through logs that don't exist. Self-grading questions:

- Did you recognize there were no logs/events *because* a suspended CronJob does nothing — rather than concluding the cluster was broken?
- Did you read `SUSPEND`/`LAST SCHEDULE`/`ACTIVE`/`schedule` as a checklist, instead of guessing one cause?
- Did you backfill the missed run with `kubectl create job --from=cronjob/...` rather than just waiting?

<details>
<summary>📖 Going deeper: the other ways a CronJob silently fires nothing<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/">[2]</a></sup></summary>

`suspend: true` is the most common, but the differential has more entries, and they all present identically (no Jobs, no obvious error):

- **A valid schedule that never matches.** `0 0 31 2 *` is legal cron — the 31st of February — and fires never. So is `0 0 30 2 *`. Always read the schedule semantically, not just for syntax errors (the API rejects *malformed* cron, but not *impossible* dates).
- **Missed runs past `startingDeadlineSeconds`.** If the controller was down or the cluster was too busy and a scheduled time slipped by more than `startingDeadlineSeconds`, that run is dropped. Set it very low and transient delays silently eat runs; `describe cronjob` shows "missed schedule" / "too many missed start times" events.
- **A previous run stuck `Active` with `concurrencyPolicy: Forbid`.** `Forbid` skips a new run while the old one is still going — so one hung Job blocks *all* successors. `kubectl get jobs` reveals the stuck `Active` Job; killing or fixing it unblocks the schedule.
- **Timezone confusion.** By default schedules are interpreted in the kube-controller-manager's timezone (UTC on most clusters). A `spec.timeZone` field exists; a mismatch between the expected and actual zone makes a CronJob fire "at the wrong time," which reads as "didn't fire" to whoever's watching the wrong clock.

The reflex: a silent CronJob is almost never a broken controller. It's a spec field — read them in order.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The CronJob has `spec.suspend: true`. A suspended CronJob is valid and otherwise healthy — the scheduler simply skips it, so it creates no Jobs<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/">[2]</a></sup>. That's why there's nothing to find in logs or events: it isn't failing, it's switched off. The most common real-world cause is someone suspending it for a maintenance window and never re-enabling it.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm it's creating nothing — LAST SCHEDULE <none>, no Jobs
kubectl get cronjob cdr-rollup -n cdr-storage
kubectl get jobs -n cdr-storage -l app=cdr-rollup
```

```bash
# 2. Work the differential — the default columns ARE the differential
kubectl get cronjob cdr-rollup -n cdr-storage
# SCHEDULE / SUSPEND / ACTIVE / LAST SCHEDULE → SUSPEND=True, that's it
```

```bash
# 3. Confirm it on the resource itself — describe spells out the flag and shows events
kubectl describe cronjob cdr-rollup -n cdr-storage
# Suspend:  True
```

**Exact fix:**

```bash
# A CronJob is patchable — suspend is a mutable, run-governing field.
kubectl patch cronjob cdr-rollup -n cdr-storage -p '{"spec":{"suspend":false}}'
# or kubectl edit, suspend: true → false (or delete the line)

# Backfill the missed run immediately rather than waiting for the schedule:
kubectl create job --from=cronjob/cdr-rollup cdr-rollup-recover -n cdr-storage
```

**Verify:**

```bash
kubectl get cronjob cdr-rollup -n cdr-storage      # SUSPEND False; LAST SCHEDULE updates within a minute
kubectl get jobs -n cdr-storage -l app=cdr-rollup  # recover Job + scheduled Job(s) reappearing
```

**Production thinking:**

The deeper issue is detection. A crash-looping Deployment pages you because traffic drops; a suspended CronJob pages *no one* — the only signal is stale data noticed downstream days later. The durable fix is twofold: correct `suspend` in `platform-gitops` so a Flux reconcile doesn't re-suspend it, and add a freshness/heartbeat alert (alert if `time() - kube_cronjob_status_last_schedule_time > 2 × period`, or if the rollup output table hasn't advanced). Make a missed scheduled run as loud as a down service.

</details>

---

## Break/fix 02 — Job Stuck Retrying

**Symptom — what you'd actually see:**

Release blocked: the pre-deploy `schema-migrate` Job in `provisioning` won't complete. `COMPLETIONS` stuck at `0/1`; one Pod with a climbing `RESTARTS` count.

**Think about this before you open the answer:**

Reading Job failure state correctly and knowing Jobs are immutable. Self-grading questions:

- Did you check `.status.conditions` to tell *retrying* from *given up*, rather than assuming "0/1" means "stuck"?
- Did you read `kubectl logs job/<name>` to find the *actual* failure (a typo → exit 127), not guess?
- Did you reach for delete-and-recreate after the patch was rejected — rather than fighting the immutability error?

<details>
<summary>📖 Going deeper: OnFailure vs Never, and why a Failed Job won't self-heal<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/job/">[1]</a></sup></summary>

**`OnFailure` vs `Never` change what you see.** `OnFailure` restarts the same container in place — one Pod, climbing `RESTARTS`, `CrashLoopBackOff` between tries (this scenario). `Never` leaves each failed Pod and creates a *new* one per attempt — a growing list of `Error` Pods, restart count stuck at 0. Same root-cause work; different surface. `Never` is useful when you want each attempt's Pod preserved for forensics; `OnFailure` is tidier when you don't.

**`backoffLimit` is the give-up count, and the give-up is sticky.** Once a Job is `Failed`, it does not retry on its own and — crucially — it does **not** self-heal the way a Deployment does. A Deployment with a fixed image rolls forward on the next reconcile; a `Failed` Job just sits there. So fixing the manifest in Git is necessary but not sufficient: something has to *re-run* the Job. In a GitOps world that usually means deleting the failed Job so Flux recreates it from the corrected manifest (or a pipeline step that re-applies it). Know that the corrected source won't execute itself.

**`activeDeadlineSeconds`** is the other bound: a wall-clock cap that overrides `backoffLimit` and fails a Job that runs too long — the right control for a migration that must not bleed into the maintenance window's end.

**`podFailurePolicy`** (stable since v1.31) is the modern complement to `backoffLimit`. This scenario's typo exits `127` every time — a guaranteed failure that `backoffLimit` still dutifully retries three times. A `podFailurePolicy` rule that does `FailJob` on that exit code would fail the Job on the *first* attempt, surfacing the bug in seconds. The mirror case: a rule that does `Ignore` on the `DisruptionTarget` condition so a node preemption or spot reclaim doesn't burn a retry. `podFailurePolicy` classifies *why* a Pod failed; `backoffLimit` caps how many countable failures you tolerate. See `LESSON.md` for the full breakdown.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The Job's container command has a typo on its final step — `ecaho` instead of `echo` — so the shell exits `127` (command not found) every run<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/job/">[1]</a></sup>. With `restartPolicy: OnFailure` the kubelet retries the *same* Pod in place (climbing restarts, `CrashLoopBackOff` between attempts), and the Job counts failures toward `backoffLimit` (3); once exhausted, the Job goes to `Failed` and stops trying<sup><a href="https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#restart-policy">[3]</a></sup>. No number of retries fixes a typo.

**Diagnostic commands (run in this order):**

```bash
# 1. Read the bound + live status: retrying, or given up? (yaml carries both spec + status)
kubectl get job schema-migrate -n provisioning
kubectl get job schema-migrate -n provisioning -o yaml
# spec.backoffLimit: 3 , template restartPolicy: OnFailure
# status: no Failed condition = still retrying; conditions[].type=Failed = backoffLimit exhausted
```

```bash
# 2. OnFailure → one pod, climbing RESTARTS (not a pile of new pods)
kubectl get pods -n provisioning -l app=schema-migrate
```

```bash
# 3. Ask the pod WHY it dies — the log gets through early steps then errors
kubectl logs job/schema-migrate -n provisioning
# ...applying 001_init
# /bin/sh: ecaho: not found
```

```bash
# 4. Confirm a real non-zero exit (not a probe kill): in Containers:, the Last State: block
POD=$(kubectl get pod -n provisioning -l app=schema-migrate -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod $POD -n provisioning
#   Last State:  Terminated   Reason: Error   Exit Code: 127
```

**Exact fix:**

A Job's pod template is immutable — `kubectl patch` of the command returns `field is immutable`. Delete and recreate with the corrected command:

```bash
kubectl delete job schema-migrate -n provisioning
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: schema-migrate
  namespace: provisioning
  labels: { app: schema-migrate, plane: control, tier: lab }
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: schema-migrate, plane: control, tier: lab }
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: busybox:1.36
          command: ["/bin/sh","-c","echo '[schema-migrate] connecting'; echo '[schema-migrate] applying 001_init'; sleep 3; echo '[schema-migrate] done'"]
EOF
```

**Verify:**

```bash
kubectl wait --for=condition=complete job/schema-migrate -n provisioning --timeout=60s
kubectl get job schema-migrate -n provisioning    # COMPLETIONS 1/1
```

**Production thinking:**

The live recreate unblocks the release, but the typo is in the manifest in `platform-gitops`. Correct it there and let Flux apply — then confront the detection gap: a migration command that exits 127 every time should fail in CI or staging, not in the release pipeline. Why did a Job whose command had never run successfully get promoted? And because a `Failed` Job won't re-run itself on reconcile, decide who owns re-triggering it after the fix lands (Flux deletes-and-recreates, a pipeline re-applies, or an operator does it by hand).

</details>

---

## Break/fix 03 — Completions Shortfall

**Symptom — what you'd actually see:**

Finance ticket: the daily `usage-export` in `analytics` is missing data — only 1 of 4 shards reached downstream. But the Job reports `COMPLETIONS 1/1`, `Complete`, exit 0, no errors, no failed Pods.

**Think about this before you open the answer:**

Not trusting a green status, and understanding `completions`/`parallelism`. Self-grading questions:

- Did you question `Complete` and compare `completions` to the *real* work size, rather than closing the ticket on a green Job?
- Did you confirm no Pods actually failed — distinguishing "did too little" from "errored"?
- Did you recreate (immutability) and confirm `4/4`, not just bump a number you assumed was patchable?

<details>
<summary>📖 Going deeper: Indexed completion makes "which shard is missing?" answerable<sup><a href="https://kubernetes.io/docs/tasks/job/indexed-parallel-processing-static/">[6]</a></sup></summary>

Default `NonIndexed` mode treats completions as interchangeable — any 4 successes finish the Job, and there's no built-in notion of *which* shard each Pod did. That's fine when Pods pull from a shared queue, but for statically partitioned work (export day-partition 0, 1, 2, 3) it has two weaknesses: nothing assigns each Pod a partition, and when one fails you only know "3 of 4 succeeded," not *which* one is missing.

`completionMode: Indexed` fixes both. The Job hands each Pod a unique `JOB_COMPLETION_INDEX` (0…`completions`-1) via env var and annotation; the Pod reads it to pick its partition, and the Job is Complete only when every index has succeeded exactly once. The operational payoff is diagnosability: the succeeded set is `{0,1,3}` and you instantly know shard 2 failed. For Polyphone's `usage-export`, Indexed mode would both eliminate the coordination problem and turn "missing data somewhere" into "shard 2 didn't run." When you see sharded batch work, ask whether it should be Indexed.

Note this scenario's bug — wrong `completions` — would still be a bug under Indexed mode (you'd set the count wrong either way). Indexed doesn't prevent under-sizing; it makes a *partial failure* legible. The guard against under-sizing is reviewing `completions` against the known work size, ideally in CI.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`spec.completions` is `1` when the work is 4 shards. A Job marks itself `Complete` the instant `succeeded` reaches `completions`<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/job/#parallel-jobs">[1]</a></sup> — so with `completions: 1` it ran one Pod, succeeded once, and declared done while shards 2–4 were never processed. Nothing failed; the spec was simply sized wrong. This is the batch analog of M01's "`Running` ≠ `Ready`": **`Complete` ≠ correct.**

**Diagnostic commands (run in this order):**

```bash
# 1. The status that lies — Complete, but is the target right?
kubectl get job usage-export -n analytics
# COMPLETIONS 1/1  Complete
```

```bash
# 2. Compare the target against the real work (4 shards) — describe shows the sizing + result
kubectl describe job usage-export -n analytics
#   Completions: 1   ← should be 4
#   Pods Statuses: 0 Active / 1 Succeeded / 0 Failed
```

```bash
# 3. Confirm only one pod ran — no hidden failures, just under-sized work
kubectl get pods -n analytics -l app=usage-export   # one Completed pod, 0 restarts
kubectl logs job/usage-export -n analytics          # one shard processed
```

**Exact fix:**

`completions` is immutable. Delete and recreate sized to the real work:

```bash
kubectl delete job usage-export -n analytics
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: usage-export
  namespace: analytics
  labels: { app: usage-export, plane: control, tier: lab }
spec:
  completions: 4
  parallelism: 2
  backoffLimit: 4
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: usage-export, plane: control, tier: lab }
    spec:
      restartPolicy: OnFailure
      containers:
        - name: export
          image: busybox:1.36
          command: ["/bin/sh","-c","echo '[usage-export] processing a usage shard'; sleep 4; echo '[usage-export] shard complete'"]
EOF
```

**Verify:**

```bash
kubectl wait --for=condition=complete job/usage-export -n analytics --timeout=60s
kubectl get job usage-export -n analytics
# COMPLETIONS 4/4  Complete
```

**Production thinking:**

This is the most dangerous failure in the module because it's invisible to every health check — the Job is `Complete`, so liveness of the *pipeline* looks fine. Detection has to come from the *output*, not the Job: reconcile row counts (does the export have 4 partitions?), or assert the expected `completions` in a policy check before deploy. The durable fix corrects `completions` in `platform-gitops`; the real deliverable is a data-completeness check so "the job is green but the data is short" can't reach finance again. Consider Indexed mode so future partial failures name the missing shard.

</details>

---

# `m02-images-registries/` — M02 — Container Images & Registries

**Category:** Container images & registries

Concept reading: `m02-images-registries/LESSON.md`

## Break/fix 01 — ErrImageNeverPull

**Symptom — what you'd actually see:**

`metrics-aggregator` in `analytics` never starts after a deploy. `kubectl logs` is empty (the container never ran). Status is **`ErrImageNeverPull`** — not `ImagePullBackOff`.

**Think about this before you open the answer:**

Telling "wouldn't pull" from "couldn't pull." Self-grading questions:

- Did you notice the status was `ErrImageNeverPull`, not `ImagePullBackOff` — and know that means *no pull was attempted*?
- Did you check *both* `imagePullPolicy` and whether the image was cached, rather than fixing one half?
- Did you avoid wasting time on registry/credentials/network (none of which were involved)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The container has `imagePullPolicy: Never` *and* an image (`nginx:1.27`) that isn't cached on the node — the fleet only ever pulled `nginx:1.25`. `Never` forbids contacting a registry, so with nothing cached the kubelet refuses to start the pod<sup><a href="https://kubernetes.io/docs/concepts/containers/images/#image-pull-policy">[3]</a></sup>. No registry was contacted; this is the one differential branch where *no pull is attempted*.

**Diagnostic commands (run in this order):**

```bash
# 1. The status itself is the first clue — Never, not BackOff
kubectl get pods -n analytics
# 2. The event confirms no pull was tried (Events: section at the bottom of describe)
kubectl describe pod -n analytics -l app=metrics-aggregator
#    "Container image \"nginx:1.27\" is not present with pull policy of Never"
# 3. The two fields that cause it, together (describe hides pull policy → read the yaml)
kubectl get deploy metrics-aggregator -n analytics -o yaml
#    image: nginx:1.27  /  imagePullPolicy: Never
```

**Exact fix:**

Let the kubelet pull (the right fix when the image is meant to come from a registry):

```bash
kubectl patch deployment metrics-aggregator -n analytics \
  --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
```

For a genuinely air-gapped node, the opposite fix: keep `Never`, but pre-load the image (`ctr image import`) or pin a tag already cached (`nginx:1.25`).

**Verify:**

```bash
kubectl get pods -n analytics   # metrics-aggregator Running 1/1
```

**Production thinking:**

`imagePullPolicy: Never` belongs to air-gapped or pre-baked-node setups, where images are side-loaded and pulling is deliberately disabled. The failure here is a process gap: a tag bumped without the matching image being loaded onto every node. The durable fix is either to drop `Never` (pull normally) or to make image pre-loading part of the node-provisioning pipeline so a new tag can't be referenced before it's present.

</details>

---

## Break/fix 02 — Registry Unreachable

**Symptom — what you'd actually see:**

`account-provisioner` in `provisioning` is in `ImagePullBackOff`; tenant onboarding stalled.

**Think about this before you open the answer:**

Classifying a pull failure by its message instead of assuming the pull secret. Self-grading questions:

- Did you read the event and see `no such host`, rather than jumping to "it's an auth problem"?
- Did you identify the *registry* portion of the reference as wrong (vs the repository or tag)?
- Did you understand that `no such host` means it never reached the registry — so auth and manifest are irrelevant?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The image reference names a registry host that doesn't resolve — `registry.polyphone.example/library/nginx:1.25`. The kubelet tries to pull, but DNS can't resolve the host, so containerd never opens a connection<sup><a href="https://kubernetes.io/docs/concepts/containers/images/">[1]</a></sup>. The repository and tag are fine; the *registry* portion of the reference is wrong.

**Diagnostic commands (run in this order):**

```bash
# 1. Status says pull problem — category, not cause
kubectl get pods -n provisioning
# 2. The event message is the diagnosis: "no such host" (Events: section of describe)
kubectl describe pod -n provisioning -l app=account-provisioner
#    Failed to pull ... dial tcp: lookup registry.polyphone.example ... no such host
# 3. Read the reference; the registry host is the broken part (Pod Template's Image: line)
kubectl describe deploy account-provisioner -n provisioning
#    Image:  registry.polyphone.example/library/nginx:1.25
```

**Exact fix:**

Point the reference at a registry that resolves (for this image, Docker Hub):

```bash
kubectl set image deployment/account-provisioner app=nginx:1.25 -n provisioning
```

**Verify:**

```bash
kubectl get pods -n provisioning   # account-provisioner Running 1/1
```

**Production thinking:**

`no such host` / `i/o timeout` in the real world is rarely a typo — it's a decommissioned registry, broken cluster DNS, or egress blocked by a NetworkPolicy or firewall (NetworkPolicy is M14). The fix follows the cause: correct the host, restore DNS, or open the path. A pull-through cache or per-region mirror reduces the blast radius when a central registry is the unreachable thing.

</details>

---

## Break/fix 03 — 401 Unauthorized

**Symptom — what you'd actually see:**

`media-recorder` in `media` is in `ImagePullBackOff`; call recording degraded.

**Think about this before you open the answer:**

Recognizing an auth failure and wiring an `imagePullSecret` correctly. Self-grading questions:

- Did the `401` (vs `no such host` / `manifest unknown`) tell you this was auth, reached-and-rejected?
- Did you get *both* the namespace and the `--docker-server` host right (a mismatch on either silently fails)?
- Did you remember that creating the secret isn't enough — it must be referenced by the pod or ServiceAccount?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`media-recorder` pulls from the authenticated private registry at `localhost:5000` but has no `imagePullSecret`, and no `regcred` secret exists in `media`. The kubelet's pull is anonymous, and the registry rejects it with `401 Unauthorized`<sup><a href="https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/">[2]</a></sup>. The host resolved and the registry answered — the credentials are the missing piece.

**Diagnostic commands (run in this order):**

```bash
# 1. The event message: 401, not "no such host" or "manifest unknown" (Events: in describe)
kubectl describe pod -n media -l app=media-recorder
#    ... unexpected status from HEAD request: 401 Unauthorized
# 2. Prove it's an auth gate, not a broken registry
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:5000/v2/                  # 401
curl -s -o /dev/null -w "%{http_code}\n" -u polyphone:reg-pass http://localhost:5000/v2/   # 200
# 3. Confirm no pull secret is wired and none exists
kubectl get pod -n media -l app=media-recorder -o yaml   # no imagePullSecrets: field in spec
kubectl get secret -n media                              # no regcred row
```

**Exact fix:**

Create a `docker-registry` secret in the pod's namespace, matched to the registry host, and attach it:

```bash
kubectl create secret docker-registry regcred \
  --docker-server=localhost:5000 \
  --docker-username=polyphone --docker-password=reg-pass -n media
kubectl patch deployment media-recorder -n media \
  -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}}}'
```

(Attaching the secret to the namespace's ServiceAccount instead makes every pod inherit it.)

**Verify:**

```bash
kubectl get pods -n media -l app=media-recorder   # Running 1/1
```

**Production thinking:**

This is the failure that hits a fleet *all at once*. A rotated credential breaks nothing while pods run on cached images — then a node reboot or rollout triggers re-pulls and a swath of workloads wedge together. Detection: alert on `ImagePullBackOff` rate across the fleet, not per-pod. Remediation: store the pull secret in your secret manager (M11) and roll credential changes ahead of restarts, not after. The durable source of the secret belongs in `platform-gitops`, not a hand-run `kubectl create`.

</details>

---

## Break/fix 04 — Digest Mismatch

**Symptom — what you'd actually see:**

`directory` in `app-services` is in `ImagePullBackOff`; the contacts service is down.

**Think about this before you open the answer:**

Reading `manifest unknown` as a bad-reference failure, and understanding digests. Self-grading questions:

- Did the message (`manifest unknown`, not `401` or `no such host`) tell you the registry was reachable and authenticated, but the reference resolved to nothing?
- Did you recognize the `@sha256:` pin and target the *digest* as wrong (vs the repository)?
- Did you re-pin a real digest (preserving reproducibility) rather than reflexively dropping to a tag?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`directory` is pinned by digest to `nginx@sha256:0000…0000`, a manifest that doesn't exist in the registry. The host resolves and the pull is authenticated (public nginx), but the registry has no manifest for that digest, so the pull fails closed with `manifest unknown`<sup><a href="https://github.com/opencontainers/image-spec/blob/main/spec.md">[4]</a></sup>. A wrong digest can never silently run the wrong image — it refuses to run at all.

**Diagnostic commands (run in this order):**

```bash
# 1. The event message: manifest unknown / not found (Events: section of describe)
kubectl describe pod -n app-services -l app=directory
#    failed to resolve reference ... nginx@sha256:0000...: not found
# 2. The reference is digest-pinned; the digest is the wrong part (Pod Template's Image: line)
kubectl describe deploy directory -n app-services
#    Image:  nginx@sha256:0000000000…0000
# 3. Find a digest that actually exists
crane digest nginx:1.25
```

**Exact fix:**

Re-pin to a digest that resolves (keeps immutability):

```bash
kubectl set image deployment/directory app=nginx@$(crane digest nginx:1.25) -n app-services
# or fall back to the tag if digest-pinning isn't required here:
kubectl set image deployment/directory app=nginx:1.25 -n app-services
```

**Verify:**

```bash
kubectl get pods -n app-services -l app=directory   # Running 1/1
```

**Production thinking:**

A bad digest is almost always a *promotion* bug: a stage→prod promotion referenced the wrong sha, or a manifest was hand-edited. The fail-closed behavior is the system protecting you — far better than silently running the wrong image. The durable practice is to promote the *same* digest across environments mechanically (M16–M19), so the digest that passed stage is byte-for-byte what reaches prod, and never retype a sha by hand. Pinning by digest is also the foundation that signed-image admission (M20) verifies against.

</details>

---

# `m03-configuration/` — M03 — Configuration

**Category:** ConfigMaps & Secrets (config wiring)

Concept reading: `m03-configuration/LESSON.md`

## Break/fix 01 — CreateContainerConfigError

**Symptom — what you'd actually see:**

`session-broker` in `media` won't start after a change; `kubectl logs` is empty (the container never ran). Status is **`CreateContainerConfigError`** — not a crash, not a pull error.

**Think about this before you open the answer:**

Reading a config-key failure from the status and event. Self-grading questions:

- Did the `CreateContainerConfigError` status (vs `CrashLoopBackOff` or `ImagePullBackOff`) tell you this was config, not code or image?
- Did you let the event name the exact key (`couldn't find key MAX_CONNECTIONS`) instead of guessing?
- Did you check *both* sides — the reference and the ConfigMap's actual keys — before deciding which one to fix?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The container has a required `env.valueFrom.configMapKeyRef` pointing at key `MAX_CONNECTIONS` in the `app-config` ConfigMap, and that key doesn't exist (the map has `LOG_LEVEL` and `MAX_SESSIONS`). The kubelet schedules the Pod, tries to assemble the container's environment, can't find the key, and fails container creation<sup><a href="https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/">[1]</a></sup>. This is the env-injection branch — the Pod got far enough to attempt container creation.

**Diagnostic commands (run in this order):**

```bash
# 1. The status itself is the first clue — a config error, not a crash or pull
kubectl get pods -n media
# 2. The event names the exact missing key (Events: at the bottom of describe)
kubectl describe pod -n media -l app=session-broker
#    Error: couldn't find key MAX_CONNECTIONS in ConfigMap media/app-config
# 3. Confirm both sides — the env reference in the Deployment yaml (find env:)…
kubectl get deploy session-broker -n media -o yaml
#    env: … configMapKeyRef → key: MAX_CONNECTIONS
# 4. …and the ConfigMap's actual keys (describe lists the Data section)
kubectl describe configmap app-config -n media
#    Data: LOG_LEVEL=info, MAX_SESSIONS=500 — no MAX_CONNECTIONS
```

**Exact fix:**

Make the reference resolve. The intended key here is `MAX_SESSIONS`:

```bash
kubectl patch deployment session-broker -n media --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/valueFrom/configMapKeyRef/key","value":"MAX_SESSIONS"}]'
```

If the app genuinely needs a `MAX_CONNECTIONS` setting, fix the other side — `kubectl patch configmap app-config -n media -p '{"data":{"MAX_CONNECTIONS":"200"}}'` then `kubectl rollout restart deployment session-broker -n media` (env is frozen). Marking the ref `optional: true` lets the Pod start without the value — only where the app has a sane fallback.

**Verify:**

```bash
kubectl get pods -n media -l app=session-broker   # Running 1/1
```

**Production thinking:**

A `configMapKeyRef` to a non-existent key is usually a rename gone half-done — the manifest was updated to a new key name, the ConfigMap wasn't (or vice-versa). The durable fix keeps the two in lockstep: template the env reference and the ConfigMap from the same source (Kustomize/Helm), so a key rename touches both at once. `optional: true` is a deliberate choice, not a default — it trades a loud `CreateContainerConfigError` for a silent missing value, which is the right call only when the app degrades gracefully.

</details>

---

## Break/fix 02 — stuck ContainerCreating (FailedMount)

**Symptom — what you'd actually see:**

`portal-ui` in `admin-portal` is stuck `0/1` `ContainerCreating` and never goes `Ready`; the admin portal is down. No logs, no config error.

**Think about this before you open the answer:**

Recognizing a stuck-`ContainerCreating` as a volume problem, not a config-error or scheduling one. Self-grading questions:

- Did `ContainerCreating` + no logs + no `CreateContainerConfigError` lead you to a *mount*, not an env reference?
- Did you read the `FailedMount` event for the exact missing object rather than assuming a node/scheduling issue?
- Did you remember Secrets are namespaced — that the fix has to land in `admin-portal`, not wherever the Secret might already exist?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The Pod mounts a Secret named `portal-secrets` as a volume, but that Secret was never created in the namespace. Volume setup is a precondition to container creation, so the container is never attempted — the Pod sits in `ContainerCreating` while the kubelet retries the mount<sup><a href="https://kubernetes.io/docs/concepts/configuration/secret/">[2]</a></sup>. Same family of root cause as break/fix 01 (a referenced object that isn't there) but a different consumption mode, caught at a different phase.

**Diagnostic commands (run in this order):**

```bash
# 1. Stuck ContainerCreating (not a config error, not a crash) → suspect a volume
kubectl get pods -n admin-portal
# 2. The FailedMount event names the missing object (Events: in describe)
kubectl describe pod -n admin-portal -l app=portal-ui
#    Warning  FailedMount  ... secret "portal-secrets" not found
# 3. Confirm both sides — the volume the pod mounts (find volumes: in the yaml)…
kubectl get deploy portal-ui -n admin-portal -o yaml
#    volumes: … secret → secretName: portal-secrets
# 4. …and whether the Secret exists
kubectl get secret -n admin-portal
#    no portal-secrets row
```

**Exact fix:**

Create the missing Secret in the Pod's namespace; the kubelet's retry loop finishes the mount and the Pod starts — no manual restart needed:

```bash
kubectl create secret generic portal-secrets \
  --from-literal=SESSION_SECRET=s3ssion-signing-key \
  --from-literal=ADMIN_API_KEY=adm-9f2a1c7e \
  -n admin-portal
```

**Verify:**

```bash
kubectl get pods -n admin-portal -l app=portal-ui   # both Running 1/1
```

**Production thinking:**

A missing mounted Secret is rarely "it never existed" — it's applied to the wrong namespace, renamed, or dropped from a manifest set during a refactor. The hand-run `kubectl create` recovers the incident, but the durable fix restores it from the source of truth (a sealed-secret in Git, or a sync from your secret manager — M11), so a redeploy can't lose it again. Alerting on Pods stuck in `ContainerCreating` beyond a threshold catches this class before a human notices the outage.

</details>

---

## Break/fix 03 — config edited, nothing changed

**Symptom — what you'd actually see:**

Someone raised `session-broker`'s log level to `debug` by editing the `app-config` ConfigMap. `kubectl get configmap` confirms `debug`, but the workload's logs never changed. The Pod is `Running` and `Ready`; nothing looks broken.

**Think about this before you open the answer:**

Knowing that a config edit doesn't propagate to env consumers on its own. Self-grading questions:

- When "the change didn't take," did you compare the ConfigMap value against the *running container's* value, rather than re-checking the ConfigMap (which looked fine)?
- Did you know *why* — env frozen at start, no auto-rollout on a config edit — rather than just blindly restarting?
- Could you say what would have been different if the value were a mounted file (live-updated, except `subPath`)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`session-broker` consumes `app-config` via `envFrom`, as environment variables. Env vars are materialized once, at container start, and never update; and a ConfigMap edit doesn't restart any consumers<sup><a href="https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically">[3]</a></sup>. So the edit updated the object in etcd while the running Pod kept the `info` value it was born with. (Had the value been a *mounted file*, the kubelet would have refreshed it within ~the sync period — env is the mode with no live-update path.)

**Diagnostic commands (run in this order):**

```bash
# 1. The source of truth — the ConfigMap holds the new value (Data section)
kubectl describe configmap app-config -n media                        # LOG_LEVEL: debug
# 2. The running container — still the old value
kubectl exec deploy/session-broker -n media -- printenv LOG_LEVEL                  # info
# 3. The pod is healthy and old — it never restarted to pick up the edit
kubectl get pods -n media -l app=session-broker   # Running 1/1, AGE predates the edit
```

**Exact fix:**

Restart the consumers so they re-read the config at start:

```bash
kubectl rollout restart deployment session-broker -n media
kubectl rollout status deployment session-broker -n media
```

**Verify:**

```bash
kubectl exec deploy/session-broker -n media -- printenv LOG_LEVEL   # debug
```

**Production thinking:**

`rollout restart` is the right incident tool, but it's imperative and invisible to Git. The durable pattern is a **config-hash annotation** on the Pod template — a checksum of the ConfigMap/Secret, so any config change changes the template hash and rolls the Deployment automatically<sup><a href="https://helm.sh/docs/howto/charts_tips_and_tricks/#automatically-roll-deployments">[4]</a></sup>. Kustomize and Helm config generators do this for you; pairing it with `immutable` + hashed-name config objects makes "change config" mean "create a new object and roll," which can't silently fail to propagate. To detect the stale ones, you'd compare consumed config against current — non-trivial for env, which is why the hash pattern (prevention) beats detection.

</details>

---

## Break/fix 04 — Running, but the credential is wrong

**Symptom — what you'd actually see:**

`account-provisioner` in `provisioning` is `Running` and `Ready`, but can't authenticate to its database — provisioning is failing. No crash, no restart, no error event.

**Think about this before you open the answer:**

Finding a green-but-wrong config by reading the injected value, and understanding the base64 boundary. Self-grading questions:

- With every status green, did you think to read the *value* (`printenv`) rather than trusting `Running`/`Ready`?
- Did you recognize a password-shaped-like-base64 as a double-encoding tell, and decode to confirm?
- Did you fix the encoding *and* roll the consumer — knowing the Secret fix alone wouldn't reach the running Pod (the break/fix 03 lesson)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `database-creds` Secret's `DB_PASSWORD` was base64-encoded twice. A Secret's `data` is already base64, and the kubelet decodes it once before injecting — so a double-encoded value arrives at the container still encoded: the env `DB_PASSWORD` is the literal string `Y2hhbmdlbWU=` (base64 of `changeme`) instead of `changeme`<sup><a href="https://kubernetes.io/docs/concepts/configuration/secret/">[2]</a></sup>. The reference resolved and a value was injected, so every status is green; the value is just wrong.

**Diagnostic commands (run in this order):**

```bash
# 1. The pod is healthy — the problem is the value, not the state
kubectl get pods -n provisioning   # Running 1/1
# 2. Read the value the container actually got — it looks like base64, not a password
kubectl exec deploy/account-provisioner -n provisioning -- printenv DB_PASSWORD
#    Y2hhbmdlbWU=
# 3. Decode it — that's the intended password, encoded one extra time
echo 'Y2hhbmdlbWU=' | base64 -d; echo        # changeme
# 4. The Secret's data is double-encoded: one decode leaves it still base64
kubectl get secret database-creds -n provisioning -o yaml   # data: DB_PASSWORD: WTJoaGJtZGxiV1U9
#    WTJoaGJtZGxiV1U9   → base64 -d → Y2hhbmdlbWU=  → base64 -d → changeme
```

**Exact fix:**

Recreate the Secret with the value encoded exactly once — let the tooling encode it instead of doing it by hand — then roll the consumer (env is frozen):

```bash
kubectl create secret generic database-creds \
  --from-literal=DB_HOST=postgres.polyphone.example \
  --from-literal=DB_PASSWORD=changeme \
  -n provisioning --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment account-provisioner -n provisioning
```

(Authoring YAML directly? Put the plaintext in `stringData` and let the API server encode it once.)

**Verify:**

```bash
kubectl exec deploy/account-provisioner -n provisioning -- printenv DB_PASSWORD   # changeme
```

**Production thinking:**

Hand-base64'ing is the root mistake — `stringData`, `kubectl create --from-literal`, and every secret-management tool exist so a human never types base64. A green-but-wrong credential is dangerous precisely because nothing pages: the catch is upstream. A schema/lint check in CI that rejects a `data` value which is itself valid base64 of valid base64, or smoke-testing a real auth after a secret change, catches it before prod. And because env is frozen, any secret rotation needs a consumer roll — automate the roll with the config-hash pattern so a rotated-but-not-restarted fleet doesn't keep running on the old credential.

</details>

---

# `m04-networking-services-dns/` — M04 — Networking I: Services & DNS

**Category:** Services & DNS (networking)

Concept reading: `m04-networking-services-dns/LESSON.md`

## Break/fix 01 — DNS: cross-namespace short name

**Symptom — what you'd actually see:**

`account-provisioner` in `provisioning` is configured to call the session broker at `http://session-broker/`, and reports it can't reach the upstream. The Pod itself is `Running` — this is a name-resolution failure, not a crash.

**Think about this before you open the answer:**

Understanding the Service DNS scheme and that short names are namespace-scoped. Self-grading questions:

- Did you reproduce the failure from the *caller's* namespace, not a random one? (A `busybox` in `media` would have resolved the short name and hidden the bug.)
- Did you reach for `nslookup` / the name, rather than assuming the Service was down or the pull was broken?
- Did you qualify the name (`<svc>.<ns>` or FQDN) instead of moving the workload or duplicating the Service into `provisioning`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The endpoint uses the **bare** Service name `session-broker`, but the target Service lives in the `media` namespace while the caller is in `provisioning`. A short name resolves only within the caller's own namespace, because the Pod's DNS search domains are built from *its* namespace (`provisioning.svc.cluster.local`, …). So the lookup becomes `session-broker.provisioning.svc.cluster.local` → NXDOMAIN. The Service is fine; the name is unqualified<sup><a href="https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/">[4]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. The configured endpoint — the bare name is the clue
kubectl describe deploy account-provisioner -n provisioning
#    Environment: BROKER_ENDPOINT: http://session-broker/

# 2. Reproduce resolution from the CALLER's namespace — NXDOMAIN
kubectl run dns-test --rm -i --restart=Never --image=busybox:1.36 -n provisioning -- \
  nslookup session-broker
#    ** server can't find session-broker...: NXDOMAIN

# 3. Prove the Service exists — just in another namespace
kubectl get svc session-broker -n media          # it's there, with a ClusterIP

# 4. Resolve it qualified — works
kubectl run dns-test --rm -i --restart=Never --image=busybox:1.36 -n provisioning -- \
  nslookup session-broker.media.svc.cluster.local
#    → the session-broker ClusterIP
```

**busybox caveat, worth knowing:** `session-broker.media` is the form application config normally carries, and a glibc-based image resolves it — `ndots:5` means a 1-dot name gets the search domains appended first, which completes it to `session-broker.media.svc.cluster.local`. busybox does not do that: it queries any name containing a dot literally, so `nslookup session-broker.media` returns NXDOMAIN from a busybox probe even though the Service is reachable. Use the FQDN in throwaway busybox clients, or you'll misdiagnose a healthy name as broken.

**Exact fix:**

Qualify the name with the target namespace (or the full FQDN):

```bash
kubectl set env deployment/account-provisioner -n provisioning \
  BROKER_ENDPOINT=http://session-broker.media.svc.cluster.local/
# (session-broker.media also works for a glibc-based app image — the search list completes it)
```

**Verify:**

```bash
kubectl describe deploy account-provisioner -n provisioning     # Environment: the qualified name
kubectl run dns-test --rm -i --restart=Never --image=busybox:1.36 -n provisioning -- \
  wget -qO- -T3 http://session-broker.media.svc.cluster.local/ | head -4   # nginx HTML
```

**Production thinking:**

Cross-namespace calls should use `<svc>.<ns>` (or the FQDN) as a convention, set in config, so a namespace split never silently breaks resolution. The bare-name habit works right up until a caller and callee stop sharing a namespace — then it fails for a subset of traffic in a way that looks like an outage of the callee. If real DNS resolution is failing *everywhere* (not just cross-namespace), that's a different incident: check CoreDNS in `kube-system` and the `kube-dns` Service's endpoints before touching app config.

</details>

---

## Break/fix 02 — Selector mismatch: the empty EndpointSlice

**Symptom — what you'd actually see:**

Calls to `route-engine` in `call-routing` fail — the connection hangs or is refused. `route-engine`'s Pods are all `Running` and `Ready`, and `kubectl get svc route-engine` shows a normal ClusterIP. Nothing looks wrong at the top line.

**Think about this before you open the answer:**

The single most important Service-debugging reflex — checking `get endpointslice` before anything else. Self-grading questions:

- Was `kubectl get endpointslice`  one of your first three commands?
- Did you compare the Service's `selector` to the Pods' actual labels, rather than restarting or scaling the Pods (which were never unhealthy)?
- Did you recognize that `get svc` looking normal proves nothing about reachability?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `route-engine` Service's selector was changed to `app: route-enginev2`, but the Pods are labeled `app: route-engine`. The selector matches nothing, so the endpoints controller writes an **empty** EndpointSlice<sup><a href="https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/">[2]</a></sup>, and kube-proxy has no backend to send the ClusterIP's traffic to — it rejects the connection<sup><a href="https://kubernetes.io/docs/reference/networking/virtual-ips/">[3]</a></sup>. The Service exists and looks healthy; it just routes to nothing.

**Diagnostic commands (run in this order):**

```bash
# 1. The Service exists and looks fine
kubectl get svc route-engine -n call-routing            # ClusterIP, 80/TCP — normal

# 2. The diagnosis: NO endpoints behind it
kubectl get endpointslice -n call-routing \
  -l kubernetes.io/service-name=route-engine   # no endpoint addresses

# 3. Why empty? Compare the selector to the Pods' labels
kubectl describe svc route-engine -n call-routing
#    Selector:   app=route-enginev2
#    Endpoints:  <none>          ← the query and its answer, one screen
kubectl get pods -n call-routing --show-labels
#    app=route-engine   (and the Pods are Running + Ready)
```

The mismatch — selector `route-enginev2` vs label `route-engine` — is the whole bug. Endpoints are empty for one of two reasons; this is the selector one. (The other is "Pods matched but none are `Ready`" — there `get pods` would show them not-Ready.)

**Exact fix:**

Make the selector match the Pods (or, equivalently, fix whichever side drifted):

```bash
kubectl patch svc route-engine -n call-routing \
  -p '{"spec":{"selector":{"app":"route-engine"}}}'
# or: kubectl edit svc route-engine -n call-routing   → set selector.app: route-engine
```

**Verify:**

```bash
kubectl get endpointslice -n call-routing \
  -l kubernetes.io/service-name=route-engine   # now lists Pod addresses on :80
kubectl run net-test --rm -i --restart=Never --image=busybox:1.36 -n call-routing -- \
  wget -qO- --timeout=3 http://route-engine/             # nginx HTML
```

**Production thinking:**

This is the failure a label rename ships silently: someone updates the `app` label on a Deployment's Pod template and the Service's selector drifts out of sync, or vice-versa. No Pod is unhealthy, nothing logs an error, and the Service empties. Detect it by alerting on a Service with zero `Ready` endpoints (the `kube_endpoint_address_available`-style metric), not on Pod health — Pod health is green throughout. The durable fix is to keep selector and Pod labels in one templated source (Kustomize/Helm, M16–M17) so they can't drift independently.

</details>

---

## Break/fix 03 — Port mismatch: refused, with endpoints

**Symptom — what you'd actually see:**

Calls to `portal-ui` in `admin-portal` come back `connection refused` immediately. Unlike breakfix-02, the EndpointSlice for `portal-ui` is **populated** — the Pods are there, Ready, and in the EndpointSlice. The connection is reaching a Pod and getting rejected.

**Think about this before you open the answer:**

Telling a port failure from an endpoint failure, and the `port`/`targetPort`/`containerPort` distinction. Self-grading questions:

- Did the **populated** EndpointSlice stop you from chasing the selector (the breakfix-02 reflex), and point you at the port instead?
- Did you compare `targetPort` to what the process actually binds — not to `containerPort`, which is just documentation?
- Did you read `connection refused` (reached a Pod, rejected) as different from the black hole's hang/reject-with-no-endpoints?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `portal-ui` Service forwards `port: 80` to `targetPort: 8080`, but the container (nginx) listens on **80**, not 8080. Nothing is bound to 8080, so the Pod's kernel answers the forwarded connection with a RST → `connection refused`. The selector and endpoints are correct; the *port* the traffic is delivered to is wrong. `containerPort` declaring 8080 changes nothing — it never opened a listener<sup><a href="https://kubernetes.io/docs/concepts/services-networking/service/#defining-a-service">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Endpoints ARE present — this is NOT the black-hole case
kubectl get endpointslice -n admin-portal \
  -l kubernetes.io/service-name=portal-ui   # lists Pod addresses on :8080

# 2. The connection is refused, not hung — something is rejecting it
kubectl run net-test --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -qO- --timeout=3 http://portal-ui/
#    wget: can't connect ... Connection refused

# 3. Read the Service's targetPort and compare to the real listener
kubectl describe svc portal-ui -n admin-portal
#    Port: 80/TCP   TargetPort: 8080/TCP   Endpoints: <PodIP>:8080
# nginx serves on 80 — prove it directly against the Pod:
kubectl run net-test --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  sh -c 'wget -qO- --timeout=3 http://<a-portal-ui-pod-ip>:80 && echo OK-on-80'
```

The endpoints listing showing `:8080` while nginx serves `:80` is the discriminator: a populated EndpointSlice plus a refused connection equals a `targetPort` problem, never a selector one.

**Exact fix:**

Point `targetPort` at the port the process actually listens on:

```bash
kubectl patch svc portal-ui -n admin-portal \
  -p '{"spec":{"ports":[{"port":80,"targetPort":80}]}}'
# or: kubectl edit svc portal-ui -n admin-portal   → targetPort: 80
```

**Verify:**

```bash
kubectl get endpointslice -n admin-portal \
  -l kubernetes.io/service-name=portal-ui   # now shows the address on :80
kubectl run net-test --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -qO- --timeout=3 http://portal-ui/                # nginx HTML
```

**Production thinking:**

Port mismatches usually ship from a Service and a container image that were edited by different people or at different times — the app moved its listener, or a copy-pasted Service kept a `targetPort` from another workload. Named ports (`targetPort: http`, with the container declaring a `ports: [{name: http, containerPort: 80}]`) make this class of bug far rarer, because the Service references the port *by name* and the number lives in one place. Readiness probes help too: a probe against the real port fails the Pod out of the EndpointSlice, converting a silent refused-with-endpoints into a visible not-Ready Pod.

</details>

---

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

# `m06-scheduling/` — M06 — Scheduling

**Category:** Scheduler (Pending pods, taints, resources)

Concept reading: `m06-scheduling/LESSON.md`

## Break/fix 01 — Insufficient Resources

**Symptom — what you'd actually see:**

`stream-analyzer` in `analytics` has zero available replicas; its Pod is `Pending` with no assigned node and never starts. No logs (the container never ran), nothing to restart.

**Think about this before you open the answer:**

The most basic scheduling reflex — a `Pending` Pod means read `describe` / the `FailedScheduling` event, not the logs. Self-grading:

- Did you go to the event, not `kubectl logs` (which is empty — the Pod never ran)?
- Did you read past the expected control-plane taint line to the worker's `Insufficient memory`?
- Did you fix the *request* (the thing scheduling fits), not the image, the node, or the limit?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The container's memory **request** was fat-fingered from `256Mi` to `256Gi` (a Mi→Gi unit slip). The scheduler places a Pod by summing its **requests** and checking them against each node's **Allocatable**; no node has 256Gi, so every node fails the resource-fit filter and the Pod stays `Pending` with `Insufficient memory`<sup><a href="https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/">[1]</a></sup>. Limits are irrelevant to this — only requests are fit.

**Diagnostic commands (run in this order):**

```bash
# 1. Pending, no NODE
kubectl get pods -n analytics -o wide

# 2. The whole diagnosis is one event
kubectl describe pod -n analytics -l app=stream-analyzer | grep -A6 Events
#    FailedScheduling ... 1 node(s) had untolerated taint {control-plane}, 1 Insufficient memory
#    (skip the control-plane line; the worker's reason is "Insufficient memory")

# 3. What is it asking for, vs. what a node has?
kubectl get pod -n analytics -l app=stream-analyzer \
  -o jsonpath='{.items[0].spec.containers[0].resources.requests}'; echo   # memory:256Gi
kubectl get nodes -o custom-columns='NODE:.metadata.name,MEM:.status.allocatable.memory'
```

**Exact fix:**

Right-size the memory request (and its matching limit):

```bash
kubectl set resources deployment/stream-analyzer -n analytics \
  --requests=memory=256Mi --limits=memory=512Mi
# or: kubectl edit deployment stream-analyzer -n analytics  → requests.memory 256Gi → 256Mi
```

**Verify:**

```bash
kubectl get deploy stream-analyzer -n analytics                       # 1/1 available
kubectl describe pod -n analytics -l app=stream-analyzer | grep -A3 Events  # Scheduled … assigned to <worker>
```

**Production thinking:**

Unit slips (`Mi`↔`Gi`, `m`↔whole cores) are a top cause of "won't schedule" and of silent over-reservation — a Pod that requests `4` CPUs instead of `4m` reserves four whole cores and quietly starves a node. Guard it with admission policy (a `LimitRange` capping per-container requests, or an OPA/Kyverno rule — M20) and by templating requests in one place (Kustomize/Helm — M16–M17) rather than hand-editing YAML. If the request is *genuinely* too big for any node and not a typo, that's a capacity or a right-sizing conversation (M09's VPA), not a scheduling bug.

</details>

---

## Break/fix 02 — Untolerated Taint

**Symptom — what you'd actually see:**

`pstn-probe` in `edge` is `Pending`. No node is short on CPU or memory, and the rest of the fleet is `Running` normally on the same cluster.

**Think about this before you open the answer:**

Recognizing a taint as the cause and knowing taints live on the node. Self-grading:

- Did you read the event's `untolerated taint` and then look at the *node's* Taints, not keep inspecting the Pod?
- Did you match the toleration's key/value/effect to the taint (not a partial match that still won't satisfy it)?
- Did you understand *why* the rest of the fleet wasn't evicted (`NoSchedule` ≠ `NoExecute`)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The worker node was tainted `dedicated=telephony:NoSchedule` (a dedicated node pool), and `pstn-probe` has no matching **toleration**. A taint repels every Pod that doesn't tolerate it; with the worker carrying `dedicated=telephony` and the control-plane carrying its built-in taint, `pstn-probe` fits on no node and stays `Pending` with `untolerated taint`<sup><a href="https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/">[4]</a></sup>. The running fleet stayed put because `NoSchedule` blocks only *new* scheduling — it doesn't evict Pods already on the node (a `NoExecute` taint would have).

**Diagnostic commands (run in this order):**

```bash
# 1. Pending — read the reason
kubectl describe pod -n edge -l app=pstn-probe | grep -A6 Events
#    ... 1 node(s) had untolerated taint {dedicated: telephony}, 1 ... {control-plane}

# 2. Taints live on the NODE, not the Pod — read them there
kubectl describe node -l '!node-role.kubernetes.io/control-plane' | grep -A2 Taints
#    Taints: dedicated=telephony:NoSchedule

# 3. The Pod tolerates nothing; contrast with sbc-edge, which reaches the tainted control-plane
kubectl get deploy pstn-probe -n edge -o jsonpath='{.spec.template.spec.tolerations}'; echo   # empty
kubectl get ds sbc-edge -n edge -o jsonpath='{.spec.template.spec.tolerations}'; echo          # control-plane toleration
```

**Exact fix:**

Add a toleration matching the taint's key, value, and effect:

```bash
kubectl patch deployment pstn-probe -n edge --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"dedicated","value":"telephony","operator":"Equal","effect":"NoSchedule"}]}]'
# or: kubectl edit deployment pstn-probe -n edge  → add the tolerations block
```

**Verify:**

```bash
kubectl get deploy pstn-probe -n edge                                   # 1/1 available
kubectl describe pod -n edge -l app=pstn-probe | grep -A3 Events        # Scheduled … assigned to <worker>
```

**Production thinking:**

Node taints usually arrive from something automated — a node pool provisioned as `dedicated=`, a cordon (`node.kubernetes.io/unschedulable`), a drain for maintenance, or the node controller's `NoExecute` on `not-ready`/`unreachable`<sup><a href="https://kubernetes.io/docs/reference/labels-annotations-taints/">[7]</a></sup>. When a whole workload suddenly can't schedule after a cluster change, `kubectl describe node | grep Taints` across the pool is the fast check. Tolerations are a *permission*, not a *requirement* — a toleration lets a Pod onto a tainted node but doesn't pull it there; pair it with a `nodeSelector`/nodeAffinity if you actually want the Pod *on* that pool.

</details>

---

## Break/fix 03 — Anti-affinity Unschedulable

**Symptom — what you'd actually see:**

`sip-director` in `signaling` wants 3 replicas but reports `1/3` — one Pod `Running`, two `Pending`. No resource shortfall, no taint blocking it, and the one running replica proves the workload schedules.

**Think about this before you open the answer:**

Reading a partial-scheduling failure as a placement-rule problem, and the hard-vs-soft trade-off. Self-grading:

- Did "some schedule, some don't" point you at an affinity/spread rule rather than resources or a taint?
- Did you connect the rule (`required`, per-hostname) to the count of schedulable nodes, and see *why* two replicas are stuck?
- Did you recognize that softening to `preferred` trades the HA guarantee for schedulability — and note it (all three now share a node)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`sip-director` sets a `requiredDuringSchedulingIgnoredDuringExecution` **pod anti-affinity** on `topologyKey: kubernetes.io/hostname` — a hard "no two replicas on the same node." A required per-hostname anti-affinity needs at least as many schedulable nodes as replicas. This cluster has one schedulable node (the control-plane is tainted), so the first replica takes the worker and the other two have no distinct node to land on — they stay `Pending` with `didn't match pod anti-affinity rules`<sup><a href="https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/">[5]</a></sup>. The rule is doing exactly what it says; the cluster can't satisfy it.

**Diagnostic commands (run in this order):**

```bash
# 1. Some scheduled, some not — a relative placement rule
kubectl get pods -n signaling -l app=sip-director -o wide             # 1 Running, 2 Pending

# 2. Why the Pending ones fail
kubectl describe pod -n signaling -l app=sip-director | grep -A6 Events
#    ... 1 node(s) didn't match pod anti-affinity rules, 1 ... {control-plane}

# 3. The rule, and the count of nodes it needs
kubectl get deploy sip-director -n signaling \
  -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity}'; echo  # required…, topologyKey hostname
kubectl get nodes                                                     # 2 nodes, only 1 schedulable
```

**Fix (canonical — soften to best-effort spread):**

```bash
kubectl patch deployment sip-director -n signaling --type=json -p '[
  {"op":"remove","path":"/spec/template/spec/affinity/podAntiAffinity/requiredDuringSchedulingIgnoredDuringExecution"},
  {"op":"add","path":"/spec/template/spec/affinity/podAntiAffinity/preferredDuringSchedulingIgnoredDuringExecution","value":[{"weight":100,"podAffinityTerm":{"labelSelector":{"matchLabels":{"app":"sip-director"}},"topologyKey":"kubernetes.io/hostname"}}]}
]'
```

Alternatives: add schedulable nodes (or tolerate more) so the `required` rule *can* be met, or `kubectl scale deploy sip-director -n signaling --replicas=1` to fit the schedulable node count.

**Exact fix:**

**Verify:**

```bash
kubectl get pods -n signaling -l app=sip-director -o wide   # all Running (on the worker)
kubectl get deploy sip-director -n signaling                # 3/3 available
```

**Production thinking:**

This is the classic "HA rule wedges the Deployment during a node event." A `required` anti-affinity or a `DoNotSchedule` topology spread is exactly as available as the number of schedulable domains — drain a node or lose a zone and surplus replicas go `Pending`, turning a redundancy feature into an outage during scale-up<sup><a href="https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/">[6]</a></sup>. Prefer topology spread with `whenUnsatisfiable: ScheduleAnyway` (or `preferred` anti-affinity) for graceful degradation, and reserve the hard form for cases where co-location is genuinely unacceptable *and* you keep enough domains (plus headroom for one to fail). Alert on `Pending` Pods with an anti-affinity/spread reason so a drain doesn't silently under-replicate a service.

</details>

---

## Break/fix 04 — OOMKilled

**Symptom — what you'd actually see:**

`media-buffer` in `media` schedules onto a node (unlike the first three) but won't stay up — `CrashLoopBackOff`, restart count climbing.

**Think about this before you open the answer:**

Telling a runtime failure from a scheduling one, and the request-vs-limit distinction. Self-grading:

- Did the Pod *having a node* stop you from treating this as a scheduling problem, and send you to Last State / `OOMKilled` / exit 137?
- Did you fix the **limit** (the runtime ceiling), not the request (which was fine — the Pod scheduled)?
- Did you avoid "just remove the limit," which makes the Pod BestEffort and the first thing evicted under node pressure?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The container pre-allocates a ~60Mi in-memory buffer at startup, but its memory **limit** is set to `48Mi`. The **request** (`32Mi`) was small enough to schedule, so placement succeeded; at runtime the buffer exceeds the 48Mi limit and the kernel OOM-kills the container — `Last State: Terminated, Reason: OOMKilled`, exit code 137 (128 + SIGKILL) — which restarts into `CrashLoopBackOff`<sup><a href="https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/">[1]</a></sup>. QoS is `Burstable` (request below limit). Requests fit; the limit didn't hold.

**Diagnostic commands (run in this order):**

```bash
# 1. It HAS a node — not a scheduling failure. It's crashing.
kubectl get pods -n media -l app=media-buffer -o wide       # Running/CrashLoopBackOff, restarts climbing

# 2. What killed it — the last terminated state, not the FailedScheduling event
kubectl describe pod -n media -l app=media-buffer | grep -A5 'Last State'
#    Reason: OOMKilled   Exit Code: 137

# 3. The limit that's too low, and the QoS
kubectl get deploy media-buffer -n media \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo         # limits.memory: 48Mi
kubectl get pod -n media -l app=media-buffer -o jsonpath='{.items[0].status.qosClass}'; echo  # Burstable
```

**Exact fix:**

Raise the memory limit above the working set:

```bash
kubectl set resources deployment/media-buffer -n media --limits=memory=128Mi
# or: kubectl edit deployment media-buffer -n media  → limits.memory 48Mi → 128Mi
```

**Verify:**

```bash
kubectl get deploy media-buffer -n media                                  # 1/1 available
kubectl describe pod -n media -l app=media-buffer | grep -A3 'State:'      # State: Running, no OOMKilled
```

**Production thinking:**

OOMKills are usually one of: a limit set too low for the real working set, a genuine leak, or a workload that spikes above its steady state (a big request, a batch, a cache warm). Set limits from *observed* peak usage plus headroom, not from steady-state — a limit pinned to steady-state OOMs the first time the workload does something bigger. In-place Pod resize (GA in v1.35) can widen a too-tight limit without recreating the Pod<sup><a href="https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/">[8]</a></sup>, but it treats the symptom — the durable fix is right-sizing (VPA recommendations, M09) and alerting on `OOMKilled` counts, which a bare `CrashLoopBackOff` alert can miss. Don't confuse this with **eviction**: OOMKill is the kernel on one container over its own limit; eviction is the kubelet on whole Pods when the *node* is out of memory, in QoS order<sup><a href="https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/">[3]</a></sup>.

</details>

---

# `m07-workloads-ii/` — M07 — Workloads II: StatefulSets & DaemonSets

**Category:** StatefulSets & DaemonSets

Concept reading: `m07-workloads-ii/LESSON.md`

## Break/fix 01 — Headless Service Missing

**Symptom — what you'd actually see:**

`session-store` (a 3-replica StatefulSet in `app-services`) has all three Pods `Running`, `READY 3/3`, correctly named — but its members can't reach each other, and `nslookup session-store-0.session-store.app-services.svc.cluster.local` returns NXDOMAIN.

**Think about this before you open the answer:**

Knowing that a StatefulSet's network identity is a Service you own, and that "Pods Running" ≠ "identity working." Self-grading:

- Did you check the *name resolution*, not just `get pods` (which looked healthy)?
- Did you find the missing Service via `serviceName` + `get svc`, rather than assuming the Pods or DNS were broken?
- Did you create it **headless** (`clusterIP: None`) — knowing a normal ClusterIP Service wouldn't publish the per-Pod records?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The StatefulSet's governing Service — named in `spec.serviceName: session-store` — was never created. A StatefulSet does **not** create its governing Service; you must, and it must be **headless** (`clusterIP: None`)<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/">[1]</a></sup>. Without a headless Service selecting the Pods, cluster DNS has no basis to publish the per-Pod A records `<pod>.<serviceName>.<ns>.svc.cluster.local`<sup><a href="https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/">[2]</a></sup>. Ordinal identity and storage are intact — only the network identity is missing — so the Pods look perfectly healthy.

**Diagnostic commands (run in this order):**

```bash
# 1. Pods are up and correctly named — this is NOT a crash or scheduling problem
kubectl get statefulset session-store -n app-services       # READY 3/3
kubectl get pods -n app-services -l app=session-store       # -0, -1, -2 all Running

# 2. The per-Pod name doesn't resolve
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n app-services -- \
  nslookup session-store-0.session-store.app-services.svc.cluster.local   # NXDOMAIN

# 3. The governing Service the StatefulSet expects — and its absence
kubectl get statefulset session-store -n app-services -o jsonpath='{.spec.serviceName}'; echo  # session-store
kubectl get svc -n app-services                              # no session-store Service
```

**Exact fix:**

Create the headless governing Service the StatefulSet points at:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: session-store
  namespace: app-services
  labels: { app: session-store, plane: app, tier: lab }
spec:
  clusterIP: None
  selector: { app: session-store }
  ports: [{ port: 80, name: http }]
EOF
```

**Verify:**

```bash
kubectl get svc session-store -n app-services               # CLUSTER-IP None
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n app-services -- \
  nslookup session-store-0.session-store.app-services.svc.cluster.local   # resolves to Pod-0 IP
```

**Production thinking:**

This is the single most common StatefulSet mistake — the manifest ships the StatefulSet and forgets (or misnames, or gives a ClusterIP to) the governing Service. It passes every "are the Pods up?" check and fails only when peers try to find each other, which may be minutes into a cluster bootstrap. Guard it by templating the StatefulSet and its headless Service together (one Helm chart / Kustomize base — M16–M17) so they can't drift apart, and by adding a readiness or startup check in the app that actually resolves a peer name, turning a silent DNS gap into a failing probe.

</details>

---

## Break/fix 02 — Ordered Rollout Stall

**Symptom — what you'd actually see:**

`session-store` (declared `replicas: 3`, headless Service present this time) is stuck at `READY 0/3`, and only `session-store-0` exists — `Running` but `0/1` ready. `session-store-1` and `-2` were never created.

**Think about this before you open the answer:**

Reading the ordered lifecycle — recognizing that missing higher ordinals are a *symptom* of an un-ready lower one, not a separate failure. Self-grading:

- Did you notice only Pod-0 existed and read that as "the gate never opened," rather than looking for three failed Pods?
- Did you diagnose Pod-0's readiness (probe port vs. container port), not restart the whole set blindly?
- Do you understand *why* a Deployment wouldn't fail this way (parallel creation, no ordering gate)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`session-store-0`'s **readiness probe** targets port `8080`, but the container serves on port `80`; the probe is refused every time, so the kubelet never marks Pod-0 Ready. Under the default `podManagementPolicy: OrderedReady`, the controller creates ordinals one at a time and will not create Pod `N+1` until Pod `N` is Running **and** Ready<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/">[1]</a></sup>. Pod-0 never goes Ready, so ordinals 1 and 2 are never created. A Deployment would have created all three replicas at once and left the two healthy ones serving — the ordered lifecycle is what makes one un-ready Pod a whole-set stall.

**Diagnostic commands (run in this order):**

```bash
# 1. Only Pod-0 exists, and the set is 0/3 — a StatefulSet-shaped stall
kubectl get statefulset session-store -n app-services       # READY 0/3
kubectl get pods -n app-services -l app=session-store       # only session-store-0, 0/1 Running

# 2. Pod-0 is Running but not Ready — the probe is failing
kubectl describe pod session-store-0 -n app-services | grep -A8 Conditions   # Ready: False
kubectl describe pod session-store-0 -n app-services | grep -A6 Events        # Readiness probe failed: connection refused

# 3. The probe's port vs. the container's port
kubectl get statefulset session-store -n app-services \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet}'; echo   # port 8080
kubectl get statefulset session-store -n app-services \
  -o jsonpath='{.spec.template.spec.containers[0].ports}'; echo                    # containerPort 80
```

**Exact fix:**

Point the readiness probe at the port the container serves (80):

```bash
kubectl patch statefulset session-store -n app-services --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'
# The RollingUpdate recreates Pod-0 with the corrected probe. If it doesn't re-roll promptly:
kubectl delete pod session-store-0 -n app-services   # comes back with the same name + PVC
```

**Verify:**

```bash
kubectl rollout status statefulset/session-store -n app-services --timeout=120s
kubectl get statefulset session-store -n app-services       # READY 3/3
kubectl get pods -n app-services -l app=session-store       # -0, -1, -2 all 1/1 Running
```

**Production thinking:**

`OrderedReady` is a feature for apps that must bootstrap a seed member before peers join — and a foot-gun when a health check is wrong, because it converts one Pod's misconfiguration into a total rollout stall. Know the escape hatches: `podManagementPolicy: Parallel` drops the ordering gate (keeping stable names and storage) for apps that don't need sequential startup; and for updates, `partition` lets you canary a new revision to the top ordinals only, so a bad rollout is contained to a few Pods instead of stopping at ordinal 0. Either way, get the readiness probe right — in a StatefulSet it gates far more than one Pod.

</details>

---

## Break/fix 03 — DaemonSet Node Coverage

**Symptom — what you'd actually see:**

`rtp-probe`, a DaemonSet in `edge` meant to run on every node, reports `DESIRED 1` on a 2-node cluster. Its one Pod runs on the worker; the control-plane node has no `rtp-probe` Pod. Nothing is `Pending`, no event or error appears.

**Think about this before you open the answer:**

Reading `desiredNumberScheduled` as a coverage check, and knowing DaemonSet eligibility includes taint tolerations. Self-grading:

- Did you notice `DESIRED` was below the node count and treat *that* as the bug, rather than looking for a crashed or `Pending` Pod (there isn't one)?
- Did you find the uncovered node's taint and compare tolerations between the two DaemonSets?
- Did you match the toleration to the taint (key/effect), rather than guess at resources or affinity?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`rtp-probe`'s Pod template is missing a toleration for the control-plane taint `node-role.kubernetes.io/control-plane:NoSchedule`. A DaemonSet counts a node in `desiredNumberScheduled` only if the Pod matches the node's selectors/affinity **and** tolerates its taints<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/">[4]</a></sup><sup><a href="https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/">[3]</a></sup>. The control-plane node is tainted, `rtp-probe` doesn't tolerate it, so that node is ineligible — not counted, never scheduled, and silent (there's no rejected Pod to leave a `Pending` trail). The fleet's `sbc-edge` DaemonSet reaches both nodes precisely because it *does* carry that toleration.

**Diagnostic commands (run in this order):**

```bash
# 1. DESIRED is the coverage number, and it's short of the node count
kubectl get daemonset -n edge                # sbc-edge DESIRED 2; rtp-probe DESIRED 1
kubectl get nodes                            # 2 nodes
kubectl get pods -n edge -o wide             # rtp-probe only on the worker; control-plane uncovered

# 2. The uncovered node is tainted
kubectl describe node -l node-role.kubernetes.io/control-plane | grep -A2 Taints
#    node-role.kubernetes.io/control-plane:NoSchedule

# 3. sbc-edge tolerates it; rtp-probe tolerates nothing
kubectl get ds sbc-edge  -n edge -o jsonpath='{.spec.template.spec.tolerations}'; echo   # control-plane toleration
kubectl get ds rtp-probe -n edge -o jsonpath='{.spec.template.spec.tolerations}'; echo   # empty
```

**Exact fix:**

Add the control-plane toleration (the same form `sbc-edge` uses):

```bash
kubectl patch daemonset rtp-probe -n edge --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]'
# or: kubectl edit daemonset rtp-probe -n edge  → add the tolerations block
```

**Verify:**

```bash
kubectl get daemonset rtp-probe -n edge      # DESIRED 2 CURRENT 2 READY 2
kubectl get pods -n edge -o wide -l app=rtp-probe   # a Pod now on the control-plane node too
```

**Production thinking:**

This is how node-local agents (log shippers, security agents, CNI/CSI plugins, node exporters) silently miss nodes — a taint added to a node pool after the DaemonSet shipped, or a DaemonSet that never tolerated the control-plane/dedicated taints in the first place. Because it's silent, add a check that compares each critical DaemonSet's `desiredNumberScheduled` (or `numberReady`) against the node count and alerts on a gap — the control-plane and any tainted pools are where coverage quietly disappears. When you *do* want an agent everywhere including tainted nodes, the blunt instrument is `tolerations: [{ operator: Exists }]` (tolerate everything); prefer specific tolerations so you don't accidentally schedule onto nodes cordoned or under-pressure for a reason.

</details>

---

# `m08-crds-operators/` — M08 — CRDs & Operators

**Category:** CRDs & Operators

Concept reading: `m08-crds-operators/LESSON.md`

## Break/fix 01 — Custom Resource Rejected by Schema

**Symptom — what you'd actually see:**

A product team's new tenant, `vega`, never appears. `kubectl get mediatenants -A` lists only `orion` and `lyra`, and there's no `vega-media` Deployment. The operator is healthy — nothing crashed, nothing logged an error about `vega`. The manifest is at `/root/vega-tenant.yaml`.

**Think about this before you open the answer:**

Understanding that a CRD's schema is real, API-server-enforced validation, and that a rejected resource fails silently downstream. Self-grading:

- Did you read the *admission error* (by applying the manifest), rather than hunting for a crash or an operator log that doesn't exist?
- Did you find the constraint in the CRD's schema (`explain` / the enum), not guess?
- Do you see *why* there was no operator involvement — the resource was never stored, so the loop never saw it?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The manifest sets `spec.tier: platinum`, but the CRD's structural schema constrains `spec.tier` to the enum `["gold","silver","bronze"]`. The API server validates every custom resource against the CRD's schema at admission, so it **rejects** the resource — `vega` is never stored<sup><a href="https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/">[2]</a></sup>. The operator only reconciles resources that exist, so a rejected CR produces no child and no error: the failure is upstream of the operator entirely.

**Diagnostic commands (run in this order):**

```bash
# 1. vega isn't there — and there's no child for it either
kubectl get mediatenants -A                       # only orion, lyra
kubectl get deployments -n media -l managed-by=tenant-operator   # only orion-media, lyra-media

# 2. Apply the manifest and read the API server's rejection
kubectl apply -f /root/vega-tenant.yaml
#   The MediaTenant "vega" is invalid: spec.tier: Unsupported value: "platinum":
#   supported values: "gold", "silver", "bronze"

# 3. Read the schema you have to satisfy
kubectl explain mediatenant.spec.tier
kubectl get crd mediatenants.polyphone.example \
  -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.tier.enum}'; echo  # [gold silver bronze]
grep tier /root/vega-tenant.yaml                  # tier: platinum
```

**Exact fix:**

Correct `spec.tier` to a valid enum value (confirm with the team which tier they meant; assume `gold`) and re-apply:

```bash
sed -i 's/tier: platinum/tier: gold/' /root/vega-tenant.yaml
kubectl apply -f /root/vega-tenant.yaml           # mediatenant.polyphone.example/vega created
```

**Verify:**

```bash
kubectl get mediatenants -A                       # vega now listed
kubectl get deployment vega-media -n media        # operator provisioned it
kubectl get mediatenant vega -n media -o jsonpath='{.status.phase}'; echo   # Ready
```

**Production thinking:**

This is the everyday CRD failure — a custom resource that a schema refuses. The API server's message names the field and the rule, so it's fast to fix once you apply and read it. Guard against it earlier: validate manifests in CI against the CRD's schema (`kubectl apply --dry-run=server`, or a schema linter) so a bad enum or missing required field fails the pipeline, not a 2 a.m. apply — and keep the schema tight, because a permissive schema pushes the same validation into the operator, where it's harder to see.

</details>

---

## Break/fix 02 — Reconciliation Stuck (Operator RBAC)

**Symptom — what you'd actually see:**

Both MediaTenants applied cleanly and show in `kubectl get mediatenants`, but neither reaches `Ready`: `PHASE Provisioning`, `READY 0`, and there are **no** child media Deployments. The `tenant-operator` Pod is `Running` with 0 restarts.

**Think about this before you open the answer:**

Reading operator-managed state (`.status` + logs) instead of trusting Pod status, and knowing RBAC is the usual reason a healthy-looking operator does nothing. Self-grading:

- Did you treat "Pod Running" as *not* proof the operator works, and go to `.status` + logs?
- Did the operator's own logs (the `Forbidden` line) point you at the permission, rather than guessing at the CRD or the CRs?
- Did you confirm with `auth can-i --as=<the operator's SA>` and grant *only* the needed verbs, not `*`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The operator's ClusterRole grants only `get`/`list`/`watch` on `deployments` — not `create`. The operator's reconcile loop reads both tenants and tries to create their child Deployments, but the API server denies each attempt `403 Forbidden` because the ServiceAccount it authenticates as (`system:serviceaccount:platform:tenant-operator`) lacks the verb<sup><a href="https://kubernetes.io/docs/concepts/architecture/controller/">[3]</a></sup>. The loop runs (the process is alive) but makes no progress (it can't perform its write), so every tenant stays `Provisioning`. The Pod's status says nothing is wrong — the signal is in `.status` and the operator's logs.

**Diagnostic commands (run in this order):**

```bash
# 1. Stuck status, and nothing built
kubectl get mediatenants -A                       # both PHASE Provisioning, READY 0
kubectl get deployments -n media -l managed-by=tenant-operator   # (none)

# 2. The operator is Running — so this isn't a crash
kubectl get pods -n platform                       # tenant-operator Running, 0 restarts

# 3. Ask the operator what's failing
kubectl logs deployment/tenant-operator -n platform --tail=12
#   Error from server (Forbidden): deployments.apps is forbidden: User
#   "system:serviceaccount:platform:tenant-operator" cannot create resource
#   "deployments" in API group "apps" in the namespace "media"

# 4. Confirm the missing permission from the identity's side
kubectl auth can-i create deployments -n media \
  --as=system:serviceaccount:platform:tenant-operator          # no
kubectl get clusterrole tenant-operator \
  -o jsonpath='{range .rules[?(@.resources[0]=="deployments")]}{.verbs}{"\n"}{end}'  # ["get","list","watch"]
```

**Exact fix:**

Grant the operator the write verbs its loop needs on `deployments` (re-apply the ClusterRole with the full set):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tenant-operator
  labels: { plane: platform, tier: lab }
rules:
  - apiGroups: ["polyphone.example"]
    resources: ["mediatenants"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["polyphone.example"]
    resources: ["mediatenants/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
```

No restart is needed — the loop is level-triggered and retries every few seconds.

**Verify:**

```bash
kubectl auth can-i create deployments -n media \
  --as=system:serviceaccount:platform:tenant-operator          # yes
kubectl get mediatenants -A                       # both move to PHASE Ready
kubectl get deployments -n media -l managed-by=tenant-operator   # orion-media, lyra-media appear
kubectl logs deployment/tenant-operator -n platform --tail=6     # Forbidden gone; phase=Ready
```

**Production thinking:**

RBAC is the number-one reason an operator silently stalls — a new controller version needs a verb its shipped ClusterRole didn't include, or an aggregation/label change breaks its access. Because the Pod stays healthy, alert on the *outcome*, not the process: a custom resource whose `.status` hasn't reached its ready phase within an SLO, or a rising count of `Forbidden` events for the operator's ServiceAccount. And scope the operator's role to exactly the resources and verbs it uses — broad `*` grants hide these gaps and widen blast radius (full RBAC discipline: M10).

</details>

---

## Break/fix 03 — Orphaned Child (Missing Owner Reference)

**Symptom — what you'd actually see:**

`vega-media` is `Running` in `media` (2 replicas), but there's no `vega` MediaTenant — the tenant was offboarded weeks ago. The operator is healthy (`orion`/`lyra` `Ready`) and doesn't touch `vega-media`. Cascading deletion should have removed it when `vega` was deleted.

**Think about this before you open the answer:**

Owner references as the thread cascading deletion follows, and identifying an orphan by comparison. Self-grading:

- Did you diagnose by *comparing* `vega-media`'s ownerReferences to a properly-managed child's, rather than just deleting the odd Deployment out?
- Do you understand *why* it wasn't collected — no ownerReference means the garbage collector can't associate it with the deleted CR?
- Did you leave the legitimate, owned children (`orion-media`, `lyra-media`) intact?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`vega-media` has **no** `ownerReferences`. Cascading deletion works by the garbage collector finding every object whose `ownerReferences` names a deleted owner<sup><a href="https://kubernetes.io/docs/concepts/architecture/garbage-collection/">[5]</a></sup>. `vega-media` was created out-of-band (by an older operator that didn't stamp owner references), so it never had a link to the `vega` MediaTenant — when `vega` was deleted, the collector had nothing to follow and left the child running. It's now a permanent **orphan**<sup><a href="https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/">[4]</a></sup>. The current operator only manages children of tenants that exist, so with no `vega` CR it ignores the orphan.

**Diagnostic commands (run in this order):**

```bash
# 1. A child with no living parent
kubectl get mediatenants -A                       # no vega
kubectl get deployments -n media -l managed-by=tenant-operator   # vega-media still Running

# 2. Compare owner references: a healthy child vs. the orphan
kubectl get deployment orion-media -n media -o jsonpath='{.metadata.ownerReferences}'; echo  # MediaTenant/orion, controller:true
kubectl get deployment vega-media  -n media -o jsonpath='{.metadata.ownerReferences}'; echo  # (empty)
```

`orion-media` points back at its MediaTenant; `vega-media` points nowhere. That absence is why the garbage collector never reclaimed it.

**Exact fix:**

The parent is already gone, so there's no cascade left to trigger — delete the orphan directly to reclaim its capacity:

```bash
kubectl delete deployment vega-media -n media
```

**Verify:**

```bash
kubectl get deployments -n media -l managed-by=tenant-operator   # vega-media gone; orion-media, lyra-media remain
kubectl get deployment orion-media -n media \
  -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'; echo  # MediaTenant/orion
```

The live children still carry their owner references, so *they* will cascade correctly when their tenants are offboarded — only the un-owned orphan needed manual removal.

**Production thinking:**

Orphans accumulate silently and cost real money — capacity for tenants, customers, or environments that no longer exist. Two habits catch them: when you adopt owner-reference stamping (or migrate to an operator that does), sweep once for pre-existing un-owned children, because only *new* resources get the link; and periodically reconcile "children whose owner no longer exists" as a cleanup job or an alert. The related failure worth knowing is the opposite — a **finalizer** on a CR whose operator is gone wedges deletion in `Terminating`; the safe fix is to restore the controller so it completes cleanup, with force-removing the finalizer as a last resort<sup><a href="https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/">[6]</a></sup>.

</details>

---

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

# `m10-security-rbac/` — M10 — Security I: RBAC & Pod Security

**Category:** RBAC & Pod Security (403 Forbidden)

Concept reading: `m10-security-rbac/LESSON.md`

## Break/fix 01 — RBAC: a missing verb

**Symptom — what you'd actually see:**

`endpoint-watcher` in `media` is a discovery reader that lists Service endpoints. Its Pod is in `CrashLoopBackOff` with the restart count climbing. This is not an app crash — the container's own logs show `GET /api/v1/namespaces/media/endpoints -> HTTP 403` and a `Forbidden` Status object, then the process exits non-zero.

**Think about this before you open the answer:**

Parsing a `Forbidden` and reading a Role's `rules`, plus the `get`-vs-`list` distinction. Self-grading questions:

- Did you read the logs and treat the CrashLoop as a *permission* failure, not reach for `--previous`, image, or scheduling checks?
- Did you notice the verb was `list` (a collection GET), not `get`, and match it against the Role's `Verbs: [get watch]`?
- Did you fix the Role rather than "solve" it by granting the SA `cluster-admin` or a wildcard verb?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `endpoint-reader` Role grants `verbs: ["get", "watch"]` on `endpoints` but not `list`. The reader does a `GET` on the endpoints *collection* URL, and a collection GET is governed by the **`list`** verb (a GET on a single named object is `get`). No rule reachable from the SA matches `list endpoints`, so RBAC — which is additive and has no explicit deny — simply fails to allow, and the API server returns 403. The identity, the RoleBinding, and the app are all correct; the Role is one verb too narrow<sup><a href="https://kubernetes.io/docs/reference/access-authn-authz/rbac/">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. It's crashing, but the Pod started — not an image/scheduling problem
kubectl get pods -n media -l app=endpoint-watcher            # CrashLoopBackOff

# 2. The logs are the diagnosis: read the Forbidden like a sentence
kubectl logs -n media deploy/endpoint-watcher --tail=8
#    ... "system:serviceaccount:media:endpoint-watcher" cannot LIST resource
#        "endpoints" in API group "" in the namespace "media"
#    identity = the SA we intended | verb = list | resource = endpoints | scope = namespace media

# 3. Reproduce as a yes/no, then see what the SA actually holds
kubectl auth can-i list endpoints -n media \
  --as=system:serviceaccount:media:endpoint-watcher          # no
kubectl auth can-i --list -n media \
  --as=system:serviceaccount:media:endpoint-watcher | grep -i endpoints
#    endpoints … [get watch]   — no list

# 4. Read the Role that identity is bound to
kubectl describe role endpoint-reader -n media               # Verbs: [get watch]
```

The identity in the message is the SA you meant (not `default`), so the caller is right — the permission is what's short. `list` is missing.

**Exact fix:**

Add the `list` verb to the Role (no restart needed for the *authorization* to flip; RBAC changes take effect immediately):

```bash
kubectl patch role endpoint-reader -n media --type=json \
  -p '[{"op":"replace","path":"/rules/0/verbs","value":["get","list","watch"]}]'
# or: kubectl edit role endpoint-reader -n media   → verbs: ["get","list","watch"]
```

**Verify:**

```bash
kubectl auth can-i list endpoints -n media \
  --as=system:serviceaccount:media:endpoint-watcher          # yes
# The Pod is still backing off from earlier failures — nudge it rather than wait
kubectl rollout restart deployment endpoint-watcher -n media
kubectl rollout status  deployment endpoint-watcher -n media --timeout=60s
kubectl logs -n media deploy/endpoint-watcher --tail=4       # HTTP 200 with the endpoints list
```

**Production thinking:**

Near-miss RBAC is the common case — a controller that was granted `get` and then started paging a collection, or `endpoints` vs. `endpointslices` after an API migration. Grant the exact verbs a workload uses (`kubectl auth can-i --list` on the running SA tells you what it exercises), and prefer a built-in ClusterRole like `view` per namespace over hand-written rules where you can, since the built-ins track new resource types and encode escalation boundaries (like excluding Secrets) that are easy to get wrong by hand. A wildcard verb "to make it work" turns a one-verb reader into something that can `delete` and `patch` — the opposite of least privilege.

</details>

---

## Break/fix 02 — ServiceAccount: the default identity

**Symptom — what you'd actually see:**

`route-watcher` in `call-routing` is the same kind of endpoint reader, and it too is in `CrashLoopBackOff` with a 403. Same shape as break/fix 01 — but read *who* the 403 names.

**Think about this before you open the answer:**

Reading *which identity* a Forbidden names, and fixing the Pod instead of the RBAC. Self-grading questions:

- Did the `…:default` in the message tell you the caller was wrong before you touched the Role or RoleBinding?
- Did you confirm the Pod's actual `serviceAccountName` was unset, rather than assuming the binding was broken?
- Critically: did you resist "fixing" it by granting `default` the permission? What would that have handed every *other* Pod in `call-routing` that also runs as `default`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The RBAC is correct: there is a `route-watcher` ServiceAccount, a `route-endpoint-reader` Role granting `get`/`list`/`watch` on endpoints, and a RoleBinding tying them together. The bug is on the Pod — its template omits `serviceAccountName`, so the Pod runs as the namespace **`default`** SA, which is bound to nothing. The reader authenticates as `system:serviceaccount:call-routing:default` and is denied. The permission is right; the caller isn't who you think<sup><a href="https://kubernetes.io/docs/concepts/security/service-accounts/">[3]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Crashing again
kubectl get pods -n call-routing -l app=route-watcher        # CrashLoopBackOff

# 2. Read the identity in the 403 — this is the whole diagnosis
kubectl logs -n call-routing deploy/route-watcher --tail=8
#    ... "system:serviceaccount:call-routing:DEFAULT" cannot list resource "endpoints" ...
#    same verb/resource as bf01, but the identity is :default, not route-watcher

# 3. Prove the RBAC is fine and that default is the unbound one
kubectl auth can-i list endpoints -n call-routing \
  --as=system:serviceaccount:call-routing:route-watcher      # yes  (the grant works)
kubectl auth can-i list endpoints -n call-routing \
  --as=system:serviceaccount:call-routing:default            # no   (default is bound to nothing)

# 4. Confirm which SA the Pod actually runs as
kubectl get deploy route-watcher -n call-routing \
  -o jsonpath='{.spec.template.spec.serviceAccountName}'; echo   # empty → default
```

`route-watcher` is authorized and `default` is not, yet the Pod runs as `default` — so the grant is correct and the Pod simply never adopted it.

**Exact fix:**

Point the Pod at its intended SA (this changes the template, so the Deployment rolls a new Pod that authenticates as `route-watcher`):

```bash
kubectl set serviceaccount deployment route-watcher route-watcher -n call-routing
# or: kubectl edit deployment route-watcher -n call-routing
#     under spec.template.spec:  serviceAccountName: route-watcher
```

**Verify:**

```bash
kubectl get deploy route-watcher -n call-routing \
  -o jsonpath='{.spec.template.spec.serviceAccountName}'; echo   # route-watcher
kubectl rollout status deployment route-watcher -n call-routing --timeout=60s
kubectl logs -n call-routing deploy/route-watcher --tail=4       # HTTP 200
```

**Production thinking:**

Granting `default` a permission is the seductive wrong fix — it clears the error and silently widens access to every unconfigured Pod in the namespace, since they all share `default`. The right pattern is one dedicated SA per workload, named in the Pod template, bound to exactly what it needs. Make it a review rule that any Deployment calling the API sets `serviceAccountName`, and consider `automountServiceAccountToken: false` on workloads that never talk to the API so there's no token to leak in the first place. The `default` SA is best left bound to nothing precisely so a forgotten `serviceAccountName` fails loudly here instead of quietly inheriting privilege.

</details>

---

## Break/fix 03 — RBAC: cluster scope

**Symptom — what you'd actually see:**

`node-inspector` in `analytics` reads the node inventory and is in `CrashLoopBackOff` with a 403. The verb it needs *is* granted and the identity is the one you intended — so read the message to its very last words.

**Think about this before you open the answer:**

The scope distinction — that cluster-scoped resources need a ClusterRole + ClusterRoleBinding, and that a namespaced grant for them is silently inert. Self-grading questions:

- Did the `at the cluster scope` ending (vs. `in the namespace …`) point you at scope rather than at the verb, which was already granted?
- Did you confirm `nodes` is cluster-scoped with `api-resources --namespaced=false` instead of guessing?
- Did you drop the `-n` when reproducing with `auth can-i`, since the question isn't about a namespace?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`nodes` are a **cluster-scoped** resource — they don't live in any namespace. The grant was written as a namespaced **Role** + **RoleBinding**, which RBAC accepts as valid YAML, but a namespaced binding only grants within its own namespace and can never reach a resource that lives outside every namespace. So the grant is inert: the request is denied, and the message ends `at the cluster scope` rather than `in the namespace "analytics"`. A cluster-scoped resource can only be granted by a **ClusterRole** through a **ClusterRoleBinding**<sup><a href="https://kubernetes.io/docs/reference/access-authn-authz/rbac/">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Crashing
kubectl get pods -n analytics -l app=node-inspector          # CrashLoopBackOff

# 2. The last words of the message are the tell — "at the cluster scope"
kubectl logs -n analytics deploy/node-inspector --tail=8
#    ... "system:serviceaccount:analytics:node-inspector" cannot list resource
#        "nodes" in API group "" AT THE CLUSTER SCOPE
#    identity right, verb (list) granted — but scope is cluster, not namespace

# 3. Prove the namespaced grant does nothing (no -n: the question is cluster-scoped)
kubectl auth can-i list nodes \
  --as=system:serviceaccount:analytics:node-inspector        # no

# 4. Confirm the grant is namespaced, and that nodes really are cluster-scoped
kubectl get role,rolebinding -n analytics | grep node        # a Role + a RoleBinding (both namespaced)
kubectl api-resources --namespaced=false | grep -E 'NAME|nodes'   # nodes → NAMESPACED false
```

The YAML parsed and the objects exist — but a namespaced RoleBinding for a cluster-scoped resource grants nothing. The word `scope` in the error is the whole diagnosis.

**Exact fix:**

Re-grant `list nodes` with a ClusterRole and a ClusterRoleBinding:

```bash
kubectl create clusterrole node-reader \
  --verb=get,list,watch --resource=nodes
kubectl create clusterrolebinding node-inspector \
  --clusterrole=node-reader \
  --serviceaccount=analytics:node-inspector
# the old namespaced Role/RoleBinding are inert — leave them or tidy up:
kubectl delete role node-reader rolebinding node-inspector-binding -n analytics
```

**Verify:**

```bash
kubectl auth can-i list nodes \
  --as=system:serviceaccount:analytics:node-inspector        # yes  (no -n — cluster-scoped)
kubectl rollout restart deployment node-inspector -n analytics
kubectl rollout status  deployment node-inspector -n analytics --timeout=60s
kubectl logs -n analytics deploy/node-inspector --tail=4     # HTTP 200 with the node list
```

**Production thinking:**

This is the grant that passes review and does nothing — YAML is valid, `kubectl apply` succeeds, and the failure only shows at runtime as a 403. It bites hardest for controllers and monitoring agents that read `nodes`, `persistentvolumes`, `namespaces`, or `storageclasses`. Scope a ClusterRole to exactly the cluster-scoped resources a workload needs, bind it with a ClusterRoleBinding, and remember the reach is cluster-wide — there is no "this ClusterRole but only for one namespace" for a cluster-scoped resource. When you only need a *namespaced* resource across namespaces, a RoleBinding that references a ClusterRole still confines the grant to that one namespace; that trick does not exist for `nodes`.

</details>

---

## Break/fix 04 — PodSecurity: restricted admission

**Symptom — what you'd actually see:**

The `payments-api` Deployment in the hardened `payments` namespace sits at `0/1` ready with **no Pods at all** — not `Pending`, not `CrashLoopBackOff`, nothing to describe. A Pod that merely failed to schedule would at least exist as `Pending`; here none was ever created.

**Think about this before you open the answer:**

Recognizing an admission rejection (zero Pods, not `Pending`) and writing a `restricted`-compliant `securityContext`. Self-grading questions:

- Did the absence of any Pod — not even `Pending` — tell you this was admission, not scheduling or a crash?
- Did you find the reason on the ReplicaSet's `FailedCreate` event rather than looking (in vain) for a Pod to describe?
- Did you set both levels — pod-level `runAsNonRoot`/`runAsUser`/`seccompProfile` and container-level `allowPrivilegeEscalation: false`/`capabilities.drop: [ALL]` — matching every line of the violation?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `payments` namespace enforces the `restricted` Pod Security Standard (`pod-security.kubernetes.io/enforce=restricted`). The Deployment's Pod template sets no `securityContext`, so every Pod its ReplicaSet tries to create is rejected at **admission** — the gate that runs before a Pod is persisted. Because enforcement rejects at *creation*, the caller the API server refuses is the ReplicaSet controller, not you, and no Pod object is ever written. The Deployment itself was admitted (it isn't a Pod); the failure surfaces as a `FailedCreate` event on the ReplicaSet<sup><a href="https://kubernetes.io/docs/concepts/security/pod-security-admission/">[5]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. 0/1, a ReplicaSet wanting 1 with 0 current, and NO Pods — upstream of scheduling
kubectl get deploy,rs,pods -n payments

# 2. The rejection is a FailedCreate event on the ReplicaSet, and it's a checklist
kubectl get events -n payments | grep -i -E 'failed|forbidden'
#    Error creating: pods "payments-api-..." is forbidden: violates PodSecurity
#    "restricted:latest": allowPrivilegeEscalation != false (...), unrestricted
#    capabilities (...), runAsNonRoot != true (...), seccompProfile (...)

# 3. Confirm the namespace enforces restricted
kubectl get ns payments -o jsonpath='{.metadata.labels}'; echo
#    ... pod-security.kubernetes.io/enforce: restricted ...
```

No Pod to `logs` or `describe` is itself the signal: an empty Pod list under a `0/N` Deployment means admission, and the reason lives on the controller<sup><a href="https://kubernetes.io/docs/concepts/security/pod-security-standards/">[4]</a></sup>.

**Exact fix:**

Give the Pod template a `securityContext` that satisfies every line of the violation — exactly the `restricted` fields:

```bash
kubectl patch deployment payments-api -n payments -p '{
  "spec": {"template": {"spec": {
    "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "app", "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]
  }}}
}'
# strategic-merge: the containers entry merges into the container named "app" by name,
# keeping its image/command and only adding the container-level securityContext.
```

**Verify:**

```bash
kubectl rollout status deployment payments-api -n payments --timeout=60s
kubectl get pods  -n payments                                # a Pod now exists and is Running
kubectl get deploy payments-api -n payments                  # 1/1 available
```

**Production thinking:**

Enforce gates *creation*, so turning `enforce=restricted` on a namespace that already runs workloads doesn't kill the running Pods — it fails their *next* deploy, which is a latent outage waiting for a rollout. Sequence the rollout: set `warn` and `audit` to `restricted` first to learn what would break without blocking anything, fix each workload's `securityContext`, then flip `enforce`. Bake the `restricted` fields into your base manifests (Kustomize/Helm) so every workload ships compliant and a hardened namespace is a no-op rather than a wall. And read the violation as the checklist it is — the message names the exact standard and every field to set.

</details>

---

# `m11-secrets-at-scale/` — M11 — Security II: Secrets at Scale

**Category:** External secrets pipelines

Concept reading: `m11-secrets-at-scale/LESSON.md`

## Break/fix 01 — SecretSync SyncError (Missing Source Key)

**Symptom — what you'd actually see:**

`partner-connector` (`media`) is in `CreateContainerConfigError` and its `partner-api` Secret doesn't exist, while `billing-processor`/`db-credentials` are healthy. The operator is Running; nothing crashed.

**Think about this before you open the answer:**

That a derived Secret's failure story lives in the object that produces it. Self-grading:

- Did you go to the SecretSync's `.status` after seeing the Secret was missing, instead of hand-creating the Secret (which the operator would overwrite)?
- Did you diagnose by *comparing* the sync's `sourceKey` to the store's actual keys, rather than guessing?
- Did you fix the *source* (the SecretSync) and understand why editing the derived Secret directly wouldn't hold?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `partner-api` SecretSync names `sourceKey: api-tokn`, but the store's key is `api-token` (a typo). The operator reads the store fine, but the named key resolves to nothing, so it sets the SecretSync to `reason=SyncError` and — by design — refuses to materialize a partial Secret. No `partner-api` Secret is ever created, so its consumer, referencing a Secret that never existed, can't build its container environment (the M03 `CreateContainerConfigError` shape). Because only one SecretSync is wrong, only one consumer is affected — this is a single-reference failure, not a store-wide one.

**Diagnostic commands (run in this order):**

```bash
# 1. The consumer can't start, and its Secret is absent
kubectl get pods -n media -l app=partner-connector          # CreateContainerConfigError
kubectl describe pod -n media -l app=partner-connector | grep -i 'secret'   # secret "partner-api" not found
kubectl get secret partner-api -n media                      # NotFound

# 2. The Secret is derived — read the producing object's status, don't hand-create it
kubectl get secretsync -A                                    # partner-api: READY False, REASON SyncError (db-credentials Synced)
kubectl get secretsync partner-api -n media -o jsonpath='{.status.message}'; echo
#   source keys not found in store: api-tokn

# 3. Compare what the sync asks for against what the store has
kubectl get secretsync partner-api -n media -o jsonpath='{.spec.data}'; echo   # sourceKey: api-tokn
kubectl get secret vault-backend -n secrets-source -o jsonpath='{.data}'; echo # keys: db-password, api-token, signing-key
```

**Exact fix:**

Correct the `sourceKey` in the SecretSync (the source of truth), not the Secret. Re-apply it:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: polyphone.example/v1
kind: SecretSync
metadata: { name: partner-api, namespace: media, labels: { plane: media, tier: lab } }
spec:
  storeRef: { name: vault-backend }
  target:   { name: partner-api }
  data:
    - { secretKey: API_TOKEN, sourceKey: api-token }
EOF
```

**Verify:**

```bash
kubectl get secretsync partner-api -n media                  # READY True, REASON Synced
kubectl get secret partner-api -n media                      # now exists, managed-by=secret-operator
kubectl get pods -n media -l app=partner-connector           # Running 1/1 (kubelet retries the config error on a backoff)
kubectl exec deploy/partner-connector -n media -- printenv API_TOKEN   # the store's token
```

**Production thinking:**

This is the everyday sync failure — a reference that names something the store doesn't have, or a key renamed on the store side without updating the ExternalSecret. The operator names the failing key in `.status`, so it's fast once you look there. Guard against it earlier: validate that referenced keys exist against the store in CI, and alert on any ExternalSecret whose `Ready` condition has been `False` past a short threshold — the Secret is only missing until the next Pod reschedule, so a silent SyncError is a latent outage.

</details>

---

## Break/fix 02 — Store Access Denied (SecretStore Not Ready)

**Symptom — what you'd actually see:**

Both `billing-processor` (`provisioning`) and `partner-connector` (`media`) are in `CreateContainerConfigError`, and neither `db-credentials` nor `partner-api` Secret exists. Every SecretSync reads `StoreNotReady`. The operator Pod is Running, 0 restarts.

**Think about this before you open the answer:**

Recognizing a fan-out as one store-level problem and proving the store's identity lost access with `auth can-i --as`. Self-grading:

- Did the pattern — many syncs failing identically, all naming one store — send you to the store layer instead of opening two investigations?
- Did you use `kubectl auth can-i … --as=<the operator's SA>` to turn "why is nothing syncing" into a yes/no, rather than guessing?
- Did you fix the binding's subject and grant store-read to *only* the operator's SA, not widen access?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `secret-operator-store` RoleBinding in `secrets-source` — the grant that lets the operator read the backing store — names the wrong subject: `secret-operator-ro`, a ServiceAccount that doesn't exist, instead of the operator's real identity `secret-operator`. So the operator's ServiceAccount has no read access in `secrets-source`; its attempt to read `vault-backend` is denied, and it sets *every* SecretSync to `StoreNotReady` and materializes nothing. Because all syncs depend on the one store, one mis-subjected binding takes the whole pipeline offline — a fan-out from a single shared dependency<sup><a href="https://external-secrets.io/latest/provider/kubernetes/">[3]</a></sup>. The RBAC parses fine and the operator process is healthy; the signal is in the syncs' `.status` and an access check, not the Pod (RBAC in full: M10<sup><a href="https://kubernetes.io/docs/reference/access-authn-authz/rbac/">[7]</a></sup>).

**Diagnostic commands (run in this order):**

```bash
# 1. Two consumers down in two namespaces, and every sync fails the same way → shared dependency
kubectl get secretsync -A                                    # BOTH READY False, REASON StoreNotReady
kubectl get secretsync db-credentials -n provisioning -o jsonpath='{.status.message}'; echo
#   cannot read backing store secrets-source/vault-backend
kubectl get secrets -A -l managed-by=secret-operator         # none produced

# 2. Operator Running → this is access, not a crash. Prove it as the operator (M10)
kubectl get pods -n secrets-system                           # secret-operator Running, 0 restarts
kubectl auth can-i get secrets -n secrets-source \
  --as=system:serviceaccount:secrets-system:secret-operator  # no

# 3. Read the store binding — it grants the wrong identity
kubectl get rolebinding secret-operator-store -n secrets-source -o jsonpath='{.subjects}'; echo
#   name: secret-operator-ro  (a ServiceAccount that doesn't exist)
```

**Exact fix:**

Point the RoleBinding at the operator's real ServiceAccount and re-apply:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: secret-operator-store, namespace: secrets-source, labels: { plane: security, tier: lab } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: secret-operator-secrets }
subjects:
  - { kind: ServiceAccount, name: secret-operator, namespace: secrets-system }
EOF
```

No restart is needed — the loop is level-triggered and retries every few seconds.

**Verify:**

```bash
kubectl auth can-i get secrets -n secrets-source \
  --as=system:serviceaccount:secrets-system:secret-operator  # yes
kubectl get secretsync -A                                    # both move to Synced
kubectl get secrets -A -l managed-by=secret-operator         # db-credentials, partner-api appear
kubectl get pods -n provisioning -l app=billing-processor    # Running 1/1
kubectl get pods -n media -l app=partner-connector           # Running 1/1
```

**Production thinking:**

A `SecretStore`'s identity is a shared dependency, so its failures are the widest-blast-radius secret failures you have — a rotated store credential or a revoked binding fails every ExternalSecret under it at once. Because existing Pods keep running on their already-materialized Secrets, nothing is *down* until the first reschedule — so alert on the store's `Ready` condition and on a rising count of `StoreNotReady`/`Denied` syncs, not on Pod health, which lags the outage by hours. And scope store access to exactly the operator's identity; broad grants hide these gaps and widen the blast radius.

</details>

---

## Break/fix 03 — Rotation Not Propagated (Stale Consumer)

**Symptom — what you'd actually see:**

`billing-processor` is failing its database auth, but the whole pipeline is green: every SecretSync `Synced`, the operator healthy, and the `db-credentials` Secret holds the current (rotated) password. Nothing is red anywhere.

**Think about this before you open the answer:**

Catching the failure that no pipeline status shows — a healthy supply chain above a workload still running on the old value — by reading what the process actually holds. Self-grading:

- When every status was green, did you read the *injected value* (`exec … printenv`) instead of trusting `Synced`?
- Can you explain why the Secret updated but the process didn't — env frozen at start, and nothing rolls a Pod on a Secret change?
- Did you fix it by rolling the *consumer* (not re-syncing the already-correct Secret), and can you name the durable version (config-hash annotation / reloader)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The store's `db-password` was rotated to a new value (`R0tated-prod-8842`), and the operator synced it into the `db-credentials` Secret — so the Secret is correct. But `billing-processor` consumes `DB_PASSWORD` as an **environment variable**, and env vars are materialized once at container start and then frozen for the life of the container (M03<sup><a href="https://kubernetes.io/docs/concepts/configuration/secret/">[5]</a></sup>). The Pod started before the rotation and captured the old value (`S3cure-prod-4417`); the Secret updating underneath it changed nothing in the running process, and no controller watches a Secret to restart its consumers. The rotation reached the Secret and stopped there — a green pipeline above a stale consumer. This is the same "the headline status lies" theme as `Running` ≠ `Ready`, now `Synced` ≠ *adopted*.

**Diagnostic commands (run in this order):**

```bash
# 1. The pipeline is genuinely healthy — the Secret holds the current value
kubectl get secretsync -A                                    # both Synced, READY True
echo "store : $(kubectl get secret vault-backend -n secrets-source -o jsonpath='{.data.db-password}' | base64 -d)"
echo "secret: $(kubectl get secret db-credentials -n provisioning -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)"
#   both R0tated-prod-8842

# 2. Read what the PROCESS holds — the gap the status can't show
kubectl exec deploy/billing-processor -n provisioning -- printenv DB_PASSWORD   # S3cure-prod-4417 (OLD)

# 3. Confirm nothing rolled the Pod since the rotation
kubectl get pods -n provisioning -l app=billing-processor    # old AGE, 0 restarts
```

**Exact fix:**

The Secret is already correct — roll the consumer so a fresh container re-reads it:

```bash
kubectl rollout restart deployment/billing-processor -n provisioning
kubectl rollout status  deployment/billing-processor -n provisioning
```

**Verify:**

```bash
echo "store: $(kubectl get secret vault-backend -n secrets-source -o jsonpath='{.data.db-password}' | base64 -d)"
echo "proc : $(kubectl exec deploy/billing-processor -n provisioning -- printenv DB_PASSWORD)"
#   both R0tated-prod-8842 — the rotation reached the process
```

**Production thinking:**

Rotation is the reason to run any of this, and it's a two-step operation that reads like one: change the value, *and* roll every consumer. Miss the second step and you get the worst kind of incident — no alert fires (nothing crashed, nothing is `False`), and the fleet drifts onto two different credentials as Pods slowly reschedule, half on each. Couple the two by construction: a checksum of the Secret in the Pod-template annotations so a change triggers a rolling update, or a reloader controller that watches the Secret and restarts consumers. And to find who's still stale, compare the value each running Pod holds against the store — the pipeline's `Synced` won't tell you.

</details>

---

# `m12-pki-tls/` — M12 — PKI & TLS

**Category:** PKI / TLS / cert-manager

Concept reading: `m12-pki-tls/LESSON.md`

## Break/fix 01 — Issuance: a Certificate that won't issue

**Symptom — what you'd actually see:**

`config-api` in `media` is stuck `ContainerCreating`, `0/1`, and never serves HTTPS. The rest of the fleet is healthy.

**Think about this before you open the answer:**

Climbing the issuance ladder instead of debugging the Pod. Self-grading questions:

- Did the `FailedMount` send you to the *Secret*, and the missing Secret to the *Certificate*, rather than to the Pod's image or command?
- Did you read the `CertificateRequest` (not just the `Certificate`) to get the actual reason issuance failed<sup><a href="https://cert-manager.io/docs/troubleshooting/">[2]</a></sup>?
- Did you recognize that a `Ready: False` cert writes no Secret, so the Pod *couldn't* start — the two symptoms have one cause?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `config-api-tls` `Certificate`'s `issuerRef` names `polyphone-ca-typo`, an issuer that doesn't exist. cert-manager has nothing to sign with, so the `Certificate` sits `Ready: False`, the `kubernetes.io/tls` Secret<sup><a href="https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets">[4]</a></sup> `config-api-tls` is **never written**, and the Pod that mounts that Secret can't start — a `FailedMount` for a Secret that isn't there<sup><a href="https://cert-manager.io/docs/concepts/">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Stuck, not crashing — it can't even start
kubectl get pods -n media -l app=config-api               # ContainerCreating, 0/1

# 2. What is it waiting on? A Secret that doesn't exist
kubectl describe pod -n media -l app=config-api | sed -n '/Events:/,$p'
#    Warning FailedMount ... secret "config-api-tls" not found

# 3. That Secret is written by a Certificate — is it Ready?
kubectl get certificate config-api-tls -n media           # READY False

# 4. WHY isn't it? The reason is on the child CertificateRequest
kubectl describe certificaterequest -n media -l cert-manager.io/certificate-name=config-api-tls | sed -n '/Status:/,$p'
#    Referenced "ClusterIssuer" not found: ... "polyphone-ca-typo" not found

kubectl get clusterissuers                                # the real one is polyphone-ca
```

**Exact fix:**

Repoint the `Certificate` at the real internal-CA issuer.

```bash
kubectl patch certificate config-api-tls -n media --type=merge \
  -p '{"spec":{"issuerRef":{"name":"polyphone-ca"}}}'
```

**Verify:**

```bash
kubectl wait --for=condition=Ready certificate/config-api-tls -n media --timeout=90s   # True
kubectl get secret config-api-tls -n media                                             # now exists
kubectl rollout restart deployment/config-api -n media                                 # nudge the stuck Pod
kubectl rollout status  deployment/config-api -n media --timeout=90s
```

**Production thinking:**

A single wrong `issuerRef` in a manifest takes a service fully offline, and the failure surfaces as a stuck Pod that looks nothing like a cert problem. Two guards: an admission check (or CI lint) that every `issuerRef` resolves to an existing issuer before merge; and an alert on `Certificate` objects that are `Ready: False` for more than a few minutes, which catches issuance failures — bad issuer, RBAC on the issuer, an unreachable CA — before a rollout mounts the missing Secret.

</details>

---

## Break/fix 02 — Identity: a cert valid for the wrong name

**Symptom — what you'd actually see:**

`config-api` is `Running 1/1`, its `Certificate` is `Ready`, the Secret exists — but `config-client`'s mTLS call fails: `curl: (60) SSL: no alternative certificate subject name matches target host name 'config-api.media.svc.cluster.local'`.

**Think about this before you open the answer:**

Splitting a handshake failure into identity vs trust from the error text, and reading a cert's SANs. Self-grading questions:

- Did the error's wording (`subject name matches`, not `local issuer certificate`) tell you this was identity, not trust?
- Did you decode the served cert and compare its SANs to the exact name the client dialed, rather than assuming the `Ready` cert was correct?
- Did you fix `dnsNames` **and** roll the server (cert-manager reissues, but nginx won't reload a mounted cert on its own)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The server cert's Subject Alternative Names list only `config-api-legacy.media.svc.cluster.local`, but clients reach the Service at `config-api.media.svc.cluster.local`. Modern TLS verifies the connection's target host against the cert's **SANs** (the Common Name doesn't count), so a valid, trusted cert is rejected because its identity doesn't cover the name dialed<sup><a href="https://cert-manager.io/docs/usage/certificate/">[3]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — read WHICH check failed
kubectl exec -n app-services deploy/config-client -- \
  curl -sS --cert /etc/tls/id/tls.crt --key /etc/tls/id/tls.key \
       --cacert /etc/tls/trust/ca.crt https://config-api.media.svc.cluster.local/
#    (60) ... no alternative certificate subject name matches target host name  → identity, not trust

# 2. The app is fine; a green Certificate says "issued", not "correct"
kubectl get pods -n media -l app=config-api               # Running 1/1
kubectl get certificate config-api-tls -n media           # READY True

# 3. Read the served cert's SANs, and the dnsNames driving them
kubectl get secret config-api-tls -n media -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -ext subjectAltName                # DNS:config-api-legacy.media.svc.cluster.local
kubectl get certificate config-api-tls -n media -o jsonpath='{.spec.dnsNames}{"\n"}'
```

**Exact fix:**

Put every name clients use back into `dnsNames`, let cert-manager reissue, and roll nginx so it loads the new cert.

```bash
kubectl patch certificate config-api-tls -n media --type=merge -p \
  '{"spec":{"dnsNames":["config-api.media.svc.cluster.local","config-api.media.svc","config-api"]}}'
kubectl wait --for=condition=Ready certificate/config-api-tls -n media --timeout=90s
kubectl rollout restart deployment/config-api -n media       # nginx loaded the OLD cert at startup
```

**Verify:**

```bash
kubectl get secret config-api-tls -n media -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -ext subjectAltName                  # now includes config-api.media.svc.cluster.local
kubectl exec -n app-services deploy/config-client -- \
  curl -sS --cert /etc/tls/id/tls.crt --key /etc/tls/id/tls.key \
       --cacert /etc/tls/trust/ca.crt https://config-api.media.svc.cluster.local/   # config-api: mTLS OK
```

**Production thinking:**

A missing SAN is a deterministic bug that *looks* intermittent — same-namespace callers using the short name may pass while cross-namespace callers using the FQDN fail, or vice-versa, depending on which names made it into the cert. Generate `dnsNames` from the Service's real names (or let a mesh/ingress integration derive them) so the cert and the Service can't drift, and remember `CN` is legacy: put every name in the SANs.

</details>

---

## Break/fix 03 — Trust: the client trusts the wrong CA

**Symptom — what you'd actually see:**

`config-api`'s cert is issued, `Ready`, and correctly named — but `config-client`'s mTLS call fails: `curl: (60) SSL certificate problem: unable to get local issuer certificate`.

**Think about this before you open the answer:**

Recognizing a trust failure and fixing it by distributing the right CA — not by disabling verification. Self-grading questions:

- Did `unable to get local issuer certificate` read as *trust* (the client's CA), sending you to compare the server's *issuer* against the CA the client holds?
- Did you find the mismatch by reading both certs (`-issuer` on the server cert, `-subject` on the client's mounted CA), not by guessing?
- Did you fix it by mounting the correct CA bundle, and explicitly **not** by adding `--insecure` / `insecureSkipVerify`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`config-client` mounts the wrong trust bundle. Its `/etc/tls/trust` volume points at `legacy-ca-bundle` — an unrelated CA (`polyphone-legacy-ca`) — while the server's cert is signed by `polyphone-internal-ca`. The client can't chain the server's cert up to any CA it holds, so it rejects a perfectly valid certificate. This is a *trust* failure, not a bad cert<sup><a href="https://cert-manager.io/docs/configuration/ca/">[5]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — the error is trust, not identity
kubectl exec -n app-services deploy/config-client -- \
  curl -sS --cert /etc/tls/id/tls.crt --key /etc/tls/id/tls.key \
       --cacert /etc/tls/trust/ca.crt https://config-api.media.svc.cluster.local/
#    (60) ... unable to get local issuer certificate   → the client doesn't trust the signer

# 2. Who signed the server's cert?
kubectl get secret config-api-tls -n media -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -issuer                         # issuer=CN=polyphone-internal-ca

# 3. Which CA is the client actually trusting?
kubectl exec -n app-services deploy/config-client -- \
  openssl x509 -in /etc/tls/trust/ca.crt -noout -subject # subject=CN=polyphone-legacy-ca  ← mismatch

# 4. Where does the wrong bundle come from?
kubectl get deploy config-client -n app-services \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="trust")].secret.secretName}{"\n"}'   # legacy-ca-bundle
```

**Exact fix:**

Mount the correct trust bundle (the internal CA's public cert). A strategic-merge patch updates the `trust` volume by name and leaves the identity volume alone.

```bash
kubectl patch deployment config-client -n app-services -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"trust","secret":{"secretName":"internal-ca-bundle"}}]}}}}'
kubectl rollout status deployment/config-client -n app-services --timeout=90s
```

**Verify:**

```bash
kubectl exec -n app-services deploy/config-client -- \
  openssl x509 -in /etc/tls/trust/ca.crt -noout -subject   # subject=CN=polyphone-internal-ca
kubectl exec -n app-services deploy/config-client -- \
  curl -sS --cert /etc/tls/id/tls.crt --key /etc/tls/id/tls.key \
       --cacert /etc/tls/trust/ca.crt https://config-api.media.svc.cluster.local/   # config-api: mTLS OK
```

**Production thinking:**

`curl --insecure` makes this error vanish by making verification meaningless — the client will now accept *any* cert, including an attacker's, so a trust bug becomes a silent MITM hole. The real fix is trust *distribution*: get the correct `ca.crt` (public, safe to spread) to every client. Copy-per-namespace doesn't scale; **trust-manager** syncs a CA bundle into every namespace and lets you hold two CAs during a root rotation so the swap doesn't cause a fleet-wide outage. Ban `insecureSkipVerify` in review — a passing test with verification off is worse than a failing one.

</details>

---

# `m13-observability/` — M13 — Observability

**Category:** Logs, events, metrics

Concept reading: `m13-observability/LESSON.md`

## Break/fix 01 — Logs: an app that writes to a file

**Symptom — what you'd actually see:**

`session-logger` in `app-services` is `Running 1/1`, no restarts — healthy by every status check — but `kubectl logs deploy/session-logger` returns a single startup line and nothing else. The workload is obviously doing work (it was deployed to record per-session activity), yet its log is empty.

**Think about this before you open the answer:**

Recognizing that an empty log on a healthy Pod is a *logging-contract* problem, and bridging file output to stdout. Self-grading questions:

- Did you read the Pod as healthy (Running, 0 restarts) and treat the empty log as "not logging to stdout," rather than assuming a crash?
- Did the startup banner (or an `exec … ls /var/log`) lead you to the file, instead of concluding "this app has no logs"?
- Did you fix it by getting output to stdout (reconfigure or sidecar), rather than telling people to `exec` in and `tail` the file forever?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The container writes its real output to a file *inside* the container, `/var/log/app/session.log`, instead of to stdout. The kubelet's logging pipeline captures **stdout/stderr only**, so `kubectl logs` sees only the one banner line the app prints to stdout at startup. The app is logging correctly *to the wrong place*; nothing is broken except the logging contract<sup><a href="https://kubernetes.io/docs/concepts/cluster-administration/logging/">[2]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Healthy Pod — not a crash, not scheduling
kubectl get pods -n app-services -l app=session-logger            # Running 1/1, 0 restarts

# 2. The log is nearly empty — and the one line it prints is the clue
kubectl logs -n app-services deploy/session-logger
#    [session-logger] starting; writing session events to /var/log/app/session.log
#    ^ it told you where it logs: a FILE, not stdout

# 3. Confirm the output is on disk, not on stdout
kubectl exec -n app-services deploy/session-logger -- ls -l /var/log/app
kubectl exec -n app-services deploy/session-logger -- tail -5 /var/log/app/session.log
#    a growing session.log full of "session sess-N established ..." lines
```

A `Running` Pod with an empty log is not a dead end — it means the app isn't writing to stdout. Read the banner (it often names the file); confirm with `exec`.

**Exact fix:**

Get that output onto stdout. Either reconfigure the app (preferred when you own it), or add a streaming sidecar (when you can't change it — the file already lives on a shared `emptyDir`):

```bash
# Option A — log to stdout (the twelve-factor default)
kubectl edit deployment session-logger -n app-services
#   in containers[0].args, drop the "  >> /var/log/app/session.log" redirect → echo to stdout

# Option B — streaming sidecar that tails the file to its stdout
kubectl patch deployment session-logger -n app-services --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/-","value":{
    "name":"log-stream","image":"busybox:1.36",
    "command":["/bin/sh","-c","touch /var/log/app/session.log; exec tail -f /var/log/app/session.log"],
    "volumeMounts":[{"name":"logs","mountPath":"/var/log/app"}]}}]'
```

**Verify:**

```bash
kubectl rollout status deployment session-logger -n app-services --timeout=60s
kubectl logs -n app-services deploy/session-logger --all-containers=true --tail=6
#    the "session sess-N established ..." lines are now visible via kubectl logs
```

Use `--all-containers` — after the sidecar fix the lines come from `log-stream`, not `app`.

**Production thinking:**

The whole log stack keys on stdout/stderr — a node-level collector (Fluent Bit/Vector as a DaemonSet) tails every container's stdout and ships it centrally. An app that logs to a file is invisible to all of it, so its logs never leave the node and vanish when the Pod is replaced. Standardize on "log to stdout"; reserve the streaming sidecar for vendored binaries you genuinely can't change, and know it costs a container and some memory per Pod.

</details>

---

## Break/fix 02 — Logs & Events: a crashlooping sidecar

**Symptom — what you'd actually see:**

`sip-monitor` in `signaling` sits at `1/2` with a climbing restart count and `STATUS CrashLoopBackOff`. The SIP monitoring app itself serves fine; one of its two containers keeps dying, and nothing paged because the app never went down.

**Think about this before you open the answer:**

Isolating one failing container in a multi-container Pod, and the `-c` + `--previous` pair. Self-grading questions:

- Did the `1/2` push you to find *which* container (per-container status / the `BackOff` event) before touching anything?
- Did you reach for `--previous` — because the current instance is mid-restart and only the dead one carries the error — rather than reading empty live logs?
- Did you read `-c metrics-agent` specifically, not the default (`app`) container that was fine all along?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The Pod runs two containers — `app` (nginx, healthy) and `metrics-agent` (a telemetry sidecar). The sidecar's command execs `/usr/local/bin/metrics-agent`, a binary that isn't present in its `busybox` image, so it exits 127 immediately and the kubelet restarts it forever. The Pod can never be Ready (readiness requires *all* containers), so it stays `1/2` and that workload's telemetry export is dark<sup><a href="https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/">[3]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. 1/2 and CrashLoopBackOff — one of two containers is down
kubectl get pods -n signaling -l app=sip-monitor            # READY 1/2, RESTARTS climbing

# 2. WHICH container? Per-container status names it
kubectl get pod -n signaling -l app=sip-monitor -o \
  custom-columns='CONTAINER:.status.containerStatuses[*].name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'
#    app=true, metrics-agent=false (restarts climbing)

# 3. The event stream names it too
kubectl describe pod -n signaling -l app=sip-monitor | sed -n '/Events:/,$p'
#    Warning  BackOff  ...  Back-off restarting failed container=metrics-agent

# 4. Read the DEAD instance's logs — the live one is mid-backoff
kubectl logs -n signaling deploy/sip-monitor -c metrics-agent --previous
#    [metrics-agent] starting; exporting sip-monitor telemetry
#    /bin/sh: exec: line 3: /usr/local/bin/metrics-agent: not found     (exit 127)
```

`get pods` aggregates; the per-container status and the `BackOff` event name the failing container; `-c … --previous` reads why the dead instance died.

**Exact fix:**

Correct the sidecar's command so it runs something the image can execute (in production you'd fix the image or the binary path). `metrics-agent` is container index `1`:

```bash
kubectl patch deployment sip-monitor -n signaling --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/1/args/0",
   "value":"echo \"[metrics-agent] starting; exporting sip-monitor telemetry\"\nwhile true; do echo \"[metrics-agent] exported telemetry batch\"; sleep 30; done\n"}]'
```

**Verify:**

```bash
kubectl rollout status deployment sip-monitor -n signaling --timeout=90s
kubectl get pods -n signaling -l app=sip-monitor                 # READY 2/2, Running
kubectl logs -n signaling deploy/sip-monitor -c metrics-agent --tail=3   # exporting again
```

**Production thinking:**

Sidecars *are* the observability topology — log shippers, metrics agents, mesh proxies all ride alongside the app. When one dies quietly, the app keeps serving and no alert fires, but you go blind on that workload. Alert on Pods that are `Ready < desired` for more than a few minutes (not just on Pods that are fully down), and treat a crashlooping telemetry sidecar as an incident, because the thing that would normally tell you something is wrong is itself the thing that's broken.

</details>

---

## Break/fix 03 — Metrics: a scrape target that's DOWN

**Symptom — what you'd actually see:**

`call-metrics` in `analytics` is `Running 1/1`, `kubectl top` shows it consuming CPU/memory normally, and its `/metrics` endpoint serves fine — but every dashboard and alert built on its metrics has gone flat. No new data is arriving.

**Think about this before you open the answer:**

The two-pipelines distinction, and fixing a scrape target rather than the app. Self-grading questions:

- Did a healthy `kubectl top` tell you the app and metrics-server were fine, steering you to the scrape rather than the workload?
- Did you prove the app exposes `/metrics` on its real port *before* concluding the app was fine — so the fault had to be in discovery/scraping?
- Did you compare the advertised scrape port to the serving port, and fix the annotation (or ServiceMonitor), not the app?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

Two separate metrics pipelines. The **resource metrics** pipeline (metrics-server → `kubectl top`) is healthy, which is why `top` still works. The **application metrics** pipeline is broken: the Pod's `prometheus.io/port` annotation advertises `9090`, but the container serves `/metrics` on `80`. A Prometheus discovers the Pod by its annotations and scrapes `podIP:9090`, gets connection-refused, and marks the target **DOWN** — so the metric never arrives and the graph flatlines<sup><a href="https://prometheus.io/docs/concepts/data_model/">[6]</a></sup>. The app is healthy; the scrape target is misconfigured.

**Diagnostic commands (run in this order):**

```bash
# 1. App healthy, and the OTHER pipeline (kubectl top) works
kubectl get pods -n analytics -l app=call-metrics          # Running 1/1
kubectl top  pod  -n analytics -l app=call-metrics          # CPU/mem returned → pipeline 1 fine

# 2. The app really exposes /metrics — on its real port (80)
POD_IP=$(kubectl get pod -n analytics -l app=call-metrics -o jsonpath='{.items[0].status.podIP}')
kubectl run obs-curl --rm -i --restart=Never --image=curlimages/curl:8.11.1 -n analytics \
  -- curl -s http://$POD_IP:80/metrics                      # exposition output returns

# 3. But the scrape annotation points elsewhere
kubectl get pod -n analytics -l app=call-metrics \
  -o jsonpath='{.items[0].metadata.annotations.prometheus\.io/port}{"\n"}'   # 9090

# 4. Reproduce the scrape at the advertised port → refused
kubectl run obs-curl --rm -i --restart=Never --image=curlimages/curl:8.11.1 -n analytics \
  -- curl -s -m 5 -o /dev/null -w "HTTP %{http_code}\n" http://$POD_IP:9090/metrics   # HTTP 000
```

A healthy `kubectl top` with flat app dashboards is the tell: pipeline 1 is fine, so the fault is in pipeline 2 — the scrape.

**Exact fix:**

Point the scrape port at the port `/metrics` is actually served on (80). With annotations:

```bash
kubectl patch deployment call-metrics -n analytics -p \
  '{"spec":{"template":{"metadata":{"annotations":{"prometheus.io/port":"80"}}}}}'
# With the Prometheus Operator, you'd fix the ServiceMonitor's `port` instead — same mismatch.
```

**Verify:**

```bash
kubectl rollout status deployment call-metrics -n analytics --timeout=60s
kubectl get deploy call-metrics -n analytics \
  -o jsonpath='{.spec.template.metadata.annotations.prometheus\.io/port}{"\n"}'   # 80
POD_IP=$(kubectl get pod -n analytics -l app=call-metrics -o jsonpath='{.items[0].status.podIP}')
kubectl run obs-curl --rm -i --restart=Never --image=curlimages/curl:8.11.1 -n analytics \
  -- curl -s -o /dev/null -w "HTTP %{http_code}\n" http://$POD_IP:80/metrics        # HTTP 200
```

**Production thinking:**

A one-digit port typo silently drops an entire workload from monitoring — no error on the app, no failed deploy, just a target that reads DOWN in Prometheus and graphs that go flat. This is why teams alert on `up == 0` (the scrape-health metric Prometheus records for every target) in addition to app-level metrics: it catches the workload that fell out of monitoring before someone notices the dashboard is blank during an incident. Bake the scrape port into the same manifest as the container port so the two can't drift, and prefer a ServiceMonitor that references the port *by name* over a hard-coded number.

</details>

---

# `m14-networking-policy-ingress/` — M14 — Networking II: Policy & Ingress

**Category:** NetworkPolicy & Ingress

Concept reading: `m14-networking-policy-ingress/LESSON.md`

## Break/fix 01 — NetworkPolicy default-deny

**Symptom — what you'd actually see:**

`session-broker` in `media` is unreachable — callers hang and time out. Its Pods are `Running` and `Ready`, `kubectl get endpoints session-broker -n media` lists the Pod IPs, and DNS for `session-broker.media` resolves. Nothing is refused, nothing is `NXDOMAIN`, nothing logs an error.

**Think about this before you open the answer:**

Recognizing the silent-timeout signature and the default-deny model. Self-grading questions:

- Did you read the **hang** (vs `NXDOMAIN` / `connection refused`) as a policy drop, rather than restarting the healthy Pods?
- Did you rule out endpoints and DNS *before* concluding "policy," so it was a diagnosis and not a guess?
- Did you **add an allow** rather than delete the deny — keeping the namespace isolated?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

A `default-deny-ingress` policy (empty `podSelector`, `policyTypes: [Ingress]`, no rules) selects every pod in `media` and denies all ingress. It is the *only* policy present — the companion allow that the baseline had is missing. Selecting a pod flips it to default-deny, and with no allow, every caller (including ones in `media` itself) is dropped<sup><a href="https://kubernetes.io/docs/concepts/services-networking/network-policies/">[1]</a></sup>. Ingress-only policies don't touch egress, so DNS still works — which is why the path looks healthy right up to the silent drop.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — a hang, not a refusal or NXDOMAIN
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  wget -qO- --timeout=5 http://session-broker.media/     # times out

# 2. Rule out the M04 layers: endpoints present, DNS resolves
kubectl get endpoints session-broker -n media            # lists PodIPs:80
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  nslookup session-broker.media                          # resolves

# 3. A silent drop with a healthy path == NetworkPolicy
kubectl get networkpolicy -n media                       # only default-deny-ingress
kubectl describe networkpolicy default-deny-ingress -n media
#    PodSelector: <none>   policyTypes: Ingress   (no allow rules) → deny all ingress
```

**Exact fix:**

Add an allow that selects `session-broker` and permits its callers — do **not** delete the deny (the lockdown is intended):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-session-broker-internal, namespace: media }
spec:
  podSelector: { matchLabels: { app: session-broker } }
  policyTypes: [Ingress]
  ingress:
    - from: [ { podSelector: {} } ]          # any pod in this namespace
      ports: [ { protocol: TCP, port: 80 } ]
EOF
```

**Verify:**

```bash
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  wget -qO- --timeout=5 http://session-broker.media/     # nginx HTML
# and the isolation you kept is intact — a caller from outside still can't:
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n signaling -- \
  wget -qO- --timeout=5 http://session-broker.media/     # still times out
```

**Production thinking:**

This ships the moment someone applies a hardening `default-deny` and forgets the allows, or deletes an allow during a refactor. No Pod is unhealthy and nothing logs an error, so alert on it at the connectivity layer — synthetic probes between the pairs that are *supposed* to talk, not Pod health. And prefer ingress-only lockdowns first: an egress `default-deny` additionally breaks the namespace's DNS, turning one outage into two.

</details>

---

## Break/fix 02 — NetworkPolicy cross-namespace

**Symptom — what you'd actually see:**

`sip-app` in `app-services` can't reach `session-broker` in `media` — the call times out, the same hang as breakfix-01. But an allow policy *exists* (`allow-broker-from-app`) and it names `sip-app`. On paper the traffic is permitted.

**Think about this before you open the answer:**

Peer-selector semantics — `podSelector` vs `namespaceSelector`, and the AND-in-one-element rule. Self-grading questions:

- Did you reproduce from the **caller's** namespace and label, not a random client? (A test from the wrong place would mislead.)
- Did you spot that the `from` peer had no `namespaceSelector`, and know that makes it namespace-local?
- Did you put both selectors in **one** `from` element (AND), understanding that splitting them into two elements would be a looser OR?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The allow's `from` peer is a bare `podSelector: { app: sip-app }` with **no `namespaceSelector`**. A `podSelector` on its own is evaluated in the policy's *own* namespace — here `media` — so it means "pods labeled `app=sip-app` in `media`," of which there are none. The allow matches an empty set; the `default-deny-ingress` denies everything else; the cross-namespace caller is dropped<sup><a href="https://kubernetes.io/docs/concepts/services-networking/network-policies/">[1]</a></sup>. The policy looks correct and allows nothing.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce AS the caller — sip-app's namespace and label
kubectl run sip-app --rm -i --restart=Never --labels app=sip-app \
  --image=busybox:1.36 -n app-services -- \
  wget -qO- --timeout=5 http://session-broker.media/     # times out

# 2. An allow exists — read its peer
kubectl get networkpolicy allow-broker-from-app -n media -o yaml | grep -A8 ingress:
#    from:
#      - podSelector: { matchLabels: { app: sip-app } }   # no namespaceSelector!

# 3. Prove the peer matches nothing: no sip-app pod in the policy's namespace
kubectl get pods -n media -l app=sip-app                 # none
kubectl get pods -n app-services -l app=sip-app          # the real one is here
```

**Exact fix:**

Add a `namespaceSelector` so the peer reaches into `app-services`. Combine it with the `podSelector` in **one** `from` element (an AND — "`sip-app` pods in `app-services`"):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-broker-from-app, namespace: media }
spec:
  podSelector: { matchLabels: { app: session-broker } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: app-services } }
          podSelector:       { matchLabels: { app: sip-app } }
      ports: [ { protocol: TCP, port: 80 } ]
EOF
```

**Verify:**

```bash
kubectl run sip-app --rm -i --restart=Never --labels app=sip-app \
  --image=busybox:1.36 -n app-services -- \
  wget -qO- --timeout=5 http://session-broker.media/     # nginx HTML
# precision check — an app-services client WITHOUT the label is still denied:
kubectl run other --rm -i --restart=Never --image=busybox:1.36 -n app-services -- \
  wget -qO- --timeout=5 http://session-broker.media/     # still times out
```

**Production thinking:**

This is the most common NetworkPolicy authoring bug, and it fails *open-looking but closed* — the policy is present, so a reviewer skims past it. Two guards: templatize cross-namespace allows (Kustomize/Helm, M16–M17) so the `namespaceSelector` can't be dropped by hand, and test policies with a real cross-namespace probe in CI, since the object applying cleanly proves nothing about whether it allows the intended traffic. Mind the AND/OR shape too — one misplaced list dash turns a scoped allow into a namespace-wide one, which is a silent widening of a security boundary.

</details>

---

## Break/fix 03 — Ingress misrouting

**Symptom — what you'd actually see:**

`portal.polyphone.example` returns `503 Service Temporarily Unavailable` from outside. But `portal-ui` in `admin-portal` is healthy: Pods `Running`/`Ready`, a ClusterIP, and `kubectl get endpoints portal-ui` lists the Pod IPs on `:80`. Reached directly by its Service, `portal-ui` answers fine.

**Think about this before you open the answer:**

Telling an Ingress backend failure (`503`) from a routing miss (`404`), and reading the rule's `backend.service.port` against the Service. Self-grading questions:

- Did the **`503`** (vs `404`) tell you the rule matched and the *backend* was the problem, so you inspected the Service/port rather than the host/path?
- Did you prove `portal-ui` was healthy directly before touching the Ingress, so you knew the break was in the rule?
- Did you compare `backend.service.port` to the Service's actual `ports`, rather than assuming the Service or its endpoints were down?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `portal` Ingress rule forwards to `portal-ui` on port **8080**, but the Service exposes only **80**. The controller claims the Ingress (class `nginx`)<sup><a href="https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/">[3]</a></sup> and matches the host — so routing works — but it resolves the backend `portal-ui:8080` to *zero* endpoints and has nothing to forward to, returning `503`<sup><a href="https://kubernetes.io/docs/concepts/services-networking/ingress/">[2]</a></sup>. The Service, Pods, and endpoints are all healthy on 80; only the port the rule names is wrong. (A `404` would be the other failure — no rule matched the host/path at all.)

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce through the controller — a 503 (rule matched, backend didn't resolve)
CIP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.clusterIP}')
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -O- --timeout=5 --header "Host: portal.polyphone.example" "http://$CIP/"
#    wget: server returned error: HTTP/1.1 503 Service Temporarily Unavailable

# 2. Prove the backend is healthy — this is NOT a Service/endpoints outage
kubectl get endpoints portal-ui -n admin-portal          # PodIPs:80
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -qO- --timeout=5 http://portal-ui.admin-portal/   # nginx HTML

# 3. Read the rule against the Service — the port doesn't line up
kubectl describe ingress portal -n admin-portal          # backend portal-ui:8080
kubectl get svc portal-ui -n admin-portal                # PORT(S): 80/TCP only
```

**Exact fix:**

Point the backend port at 80 (what the Service exposes):

```bash
kubectl patch ingress portal -n admin-portal --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":80}]'
# or: kubectl edit ingress portal -n admin-portal   → backend.service.port.number: 80
```

**Verify:**

```bash
CIP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.clusterIP}')
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -qO- --timeout=5 --header "Host: portal.polyphone.example" "http://$CIP/"   # nginx HTML
```

**Production thinking:**

Port mismatches ship when an Ingress and a Service are edited by different people or at different times — the app moved its listener, or a copied Ingress kept another workload's port. Named ports remove the class of bug: have the Service declare `ports: [{ name: http, port: 80 }]` and the Ingress reference `port: { name: http }`, so the number lives in one place. And distinguish a **steady** `503` (config: wrong port/service) from a **transient** `503` right after a deploy (the backend's endpoints briefly empty during a rollout) — the second self-heals via readiness (M04, M09) and is not an Ingress bug.

</details>

---

# `m15-service-mesh/` — M15 — Service Mesh

**Category:** Service mesh (Istio-style)

Concept reading: `m15-service-mesh/LESSON.md`

## Break/fix 01 — Sidecar not injected

**Symptom — what you'd actually see:**

Callers of `session-broker` in `media` get `HTTP 503`. Its Pod is `Running`/`Ready`, `kubectl get endpoints session-broker -n media` lists the Pod IP on `:80`, and DNS resolves. Nothing logs an error; the app container is serving.

**Think about this before you open the answer:**

Reading `2/2` vs `1/1` as a mesh-membership check, and knowing a sidecar-less pod is entirely outside the mesh. Self-grading questions:

- Did you check the container count and `proxy-status` before assuming the app or the Service was broken?
- Did you connect "no sidecar" to "no mTLS terminator" as the reason for the `503`, rather than blaming the DestinationRule?
- Did you fix by **re-enrolling** the workload, leaving `STRICT` mTLS intact — not by weakening the server to accept plaintext?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `session-broker` Deployment's pod template carries `sidecar.istio.io/inject: "false"`, which overrides the namespace's `istio-injection=enabled` and admits the pod **without a sidecar** — it comes up `1/1` and is not in the mesh<sup><a href="https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/">[1]</a></sup>. Every caller's sidecar is told by the `session-broker` DestinationRule to originate `ISTIO_MUTUAL` mTLS. With no sidecar on `session-broker` to terminate that mTLS, the caller's Envoy can't complete the connection and returns `503`. The workload is healthy; only its mesh membership is missing.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce from the in-mesh client — a 503
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 503

# 2. Rule out the Service layer — endpoints present, DNS resolves
kubectl get endpoints session-broker -n media                     # PodIP:80
kubectl exec -n media deploy/mesh-client -c curl -- nslookup session-broker.media

# 3. Count containers — the tell
kubectl get pods -n media                                         # session-broker is 1/1, siblings 2/2
istioctl proxy-status | grep session-broker                       # absent — no sidecar registered with istiod
kubectl get pod -n media -l app=session-broker -o yaml | grep -A2 'annotations:'
#    sidecar.istio.io/inject: "false"
```

**Exact fix:**

Re-enroll the workload — set injection back on and let the Deployment roll a new, injected pod. Do **not** touch mTLS:

```bash
kubectl patch deployment session-broker -n media \
  -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}}}'
kubectl rollout status deployment session-broker -n media
# or: kubectl edit deployment session-broker -n media  → delete the inject: "false" annotation
```

**Verify:**

```bash
kubectl get pods -n media -l app=session-broker                   # now 2/2
istioctl proxy-status | grep session-broker                       # now listed, SYNCED
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 200
kubectl get peerauthentication default -n media -o jsonpath='{.spec.mtls.mode}{"\n"}'        # still STRICT
```

**Production thinking:**

This ships whenever a workload is templated with injection disabled, or deployed into a namespace before it was labeled. The loud `503` here is a lucky consequence of the explicit `ISTIO_MUTUAL` DestinationRule; under *automatic* mTLS the same missing sidecar would silently downgrade the hop to plaintext — an unencrypted security hole with no error. Alert on it structurally: a check that every pod in a meshed namespace is `2/2`, and mesh telemetry showing the workload is absent, catch it before a caller does.

</details>

---

## Break/fix 02 — VirtualService subset

**Symptom — what you'd actually see:**

`session-broker` returns `HTTP 503`, but every `media` pod is `2/2` and in the mesh (`istioctl proxy-status` lists `session-broker` as `SYNCED`), the Service has endpoints, and mTLS is healthy. The workload is fine.

**Think about this before you open the answer:**

Debugging a mesh `503` in the compiled Envoy config rather than in `kubectl get pods`, and knowing a subset can be valid but empty. Self-grading questions:

- Did the `2/2` pods steer you away from "the workload is down" and toward the route?
- Did you use `istioctl proxy-config routes` then `endpoints` to see the route landing on an empty cluster, instead of guessing?
- Did you connect the empty cluster to the VirtualService `subset` and the absence of `version: canary` pods?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `session-broker` VirtualService routes to `subset: canary`. The DestinationRule defines `canary` as `labels: { version: canary }` — a version nobody deployed — so istiod compiles it into an Envoy cluster (`outbound|80|canary|session-broker.media.svc.cluster.local`) with **zero endpoints**. The route matches, Envoy selects the canary cluster, finds no healthy upstream, and returns `503`<sup><a href="https://istio.io/latest/docs/concepts/traffic-management/">[2]</a></sup>. The `stable` subset has the running pods; the route just aims at the empty one.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — 503
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 503

# 2. Rule out the workload — all 2/2, endpoints present (NOT breakfix-01)
kubectl get pods -n media
kubectl get endpoints session-broker -n media                     # PodIP:80

# 3. Follow the route in Envoy — the caller's sidecar routes it
POD=$(kubectl get pod -n media -l app=mesh-client -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config routes "$POD" -n media --name 80 -o json | grep -i '"cluster"'
#    ...|canary|session-broker...   ← route targets the canary subset
istioctl proxy-config endpoints "$POD" -n media | grep session-broker
#    |stable| cluster has PodIPs:80 ; |canary| cluster is EMPTY

# 4. Confirm the source
kubectl get virtualservice session-broker -n media -o yaml | grep -A3 route:   # subset: canary
kubectl get pods -n media -l version=canary                       # none
```

**Exact fix:**

Point the route at a subset that has pods (`stable`); the canary build doesn't exist to deploy:

```bash
kubectl patch virtualservice session-broker -n media --type=json \
  -p '[{"op":"replace","path":"/spec/http/0/route/0/destination/subset","value":"stable"}]'
# or: kubectl edit virtualservice session-broker -n media  → subset: canary → stable
```

**Verify:**

```bash
POD=$(kubectl get pod -n media -l app=mesh-client -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config routes "$POD" -n media --name 80 -o json | grep -i '"cluster"'   # ...|stable|...
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 200
```

**Production thinking:**

This is the classic canary footgun: shift traffic to `version: canary` *before* the canary pods are `Ready`, and every routed request falls into an empty cluster. A VirtualService applying cleanly proves nothing about whether its subset has backends. Guard it by ordering the rollout (pods `Ready` before the traffic shift) and by testing routing with a real request in CI — and remember that a *partial* traffic split turns this into a *fractional* `503` that's easy to misread as flakiness.

</details>

---

## Break/fix 03 — mTLS mode mismatch

**Symptom — what you'd actually see:**

`session-broker` returns `HTTP 503`. Every pod is `2/2`, the VirtualService routes to `stable`, `istioctl proxy-config endpoints` shows that cluster with healthy endpoints — and it still fails. Neither of the previous two causes applies.

**Think about this before you open the answer:**

Recognizing mTLS as a two-sided contract and reading the server policy against the client policy. Self-grading questions:

- Did you rule out breakfix-01 (`2/2`) and breakfix-02 (endpoints present) before concluding "mTLS"?
- Did you read **both** the PeerAuthentication and the DestinationRule, rather than trusting either in isolation?
- Did you fix by raising the **client** to mTLS, keeping `STRICT`, instead of dropping the server to `PERMISSIVE` (which would silently make the hop plaintext)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

mTLS is configured on both sides and they **disagree**. The namespace `PeerAuthentication default` is `mtls.mode: STRICT` — `session-broker`'s sidecar accepts only mTLS. The `session-broker` DestinationRule sets `trafficPolicy.tls.mode: DISABLE` — callers' sidecars send **plaintext**. The caller sends plaintext into a server that rejects everything but mTLS; the server's sidecar resets the connection and the caller's Envoy returns `503`<sup><a href="https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/">[3]</a></sup>. Both ends are healthy and in the mesh; only the transport policies conflict.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — 503
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 503

# 2. Rule out 01 and 02 — sidecar present, route lands on endpoints
kubectl get pods -n media                                         # all 2/2 (not breakfix-01)
POD=$(kubectl get pod -n media -l app=mesh-client -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config endpoints "$POD" -n media | grep 'session-broker' | grep ':80'   # stable has endpoints (not breakfix-02)

# 3. Read both halves of mTLS
kubectl get peerauthentication default -n media -o yaml | grep -A2 mtls:            # mode: STRICT   (server)
kubectl get destinationrule session-broker -n media -o yaml | grep -A2 'tls:'       # mode: DISABLE  (client)
#    server requires mTLS, client sends plaintext → mismatch
```

**Exact fix:**

Align the client to the server. Raise the DestinationRule to `ISTIO_MUTUAL`; keep the server `STRICT`:

```bash
kubectl patch destinationrule session-broker -n media --type=json \
  -p '[{"op":"replace","path":"/spec/trafficPolicy/tls/mode","value":"ISTIO_MUTUAL"}]'
# or: kubectl edit destinationrule session-broker -n media  → mode: DISABLE → ISTIO_MUTUAL
# (removing the tls block entirely also works — automatic mTLS then negotiates it)
```

**Verify:**

```bash
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 200
kubectl get peerauthentication default -n media -o jsonpath='{.spec.mtls.mode}{"\n"}'        # still STRICT
```

**Production thinking:**

With no DestinationRule `tls` block, automatic mTLS would have negotiated this correctly — so an explicit `DISABLE` against a `STRICT` server is a self-inflicted mismatch, usually a copy-pasted rule or a leftover from a plaintext migration. Roll `STRICT` out the safe way: set `PERMISSIVE` first, let workloads gain sidecars and traffic become mTLS, confirm with telemetry, then flip to `STRICT`. And treat "fix by dropping to `PERMISSIVE`" as a regression, not a fix — it re-opens the plaintext path the mesh existed to close.

</details>

---

# `m16-kustomize/` — M16 — Kustomize Bases & Overlays

**Category:** Kustomize bases/overlays

Concept reading: `m16-kustomize/LESSON.md`

## Break/fix 01 — Patch Target Mismatch

**Symptom — what you'd actually see:**

The `edge-relay` prod promotion isn't landing; the deploy job running `kubectl apply -k overlays/prod` exits non-zero, and there is no `edge-relay` Deployment in `edge` at all — not crashing, absent. The rest of the fleet is healthy.

**Think about this before you open the answer:**

- When `apply -k` produces *nothing*, did you run `kubectl kustomize` and read the build error — instead of poking a cluster that had nothing to show? A build error is a first-class diagnosis, not a mystery.
- Did you read the error literally? It names the target identity (`Deployment/edge-relayer`) that couldn't be matched.
- Do you understand that a `patches:` entry selects its target by the patch's own name, so `metadata.name` must match a real resource?

The anti-pattern: run `kubectl describe`/`logs` against a workload that was never created, then conclude the cluster is broken.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The prod overlay's replicas patch (`overlays/prod/replicas-patch.yaml`) names its target `edge-relayer`, but the base Deployment is `edge-relay`. A `patches:` entry with a `path:` and no explicit `target:` selects by the patch's own `apiVersion`/`kind`/`metadata.name`; when nothing matches, Kustomize fails the whole build rather than skip the patch<sup><a href="https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/patches/">[1]</a></sup>. `apply -k` never sends anything to the API server, so nothing exists to describe.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm the workload is absent, not broken — nothing to run the normal loop on
kubectl get deploy -n edge
kubectl get pods -n edge -l app=edge-relay
# No edge-relay. When apply -k yields nothing, suspect the build.

# 2. Run the build half yourself and READ the error
cd /root/edge-relay
kubectl kustomize overlays/prod
# Error: ... no matches for Id Deployment.v1.apps/edge-relayer...;
#        failed to find unique target for patch ...

# 3. Line up what the patch targets against what the base names
cat overlays/prod/replicas-patch.yaml            # metadata.name: edge-relayer
kubectl kustomize base | grep -E '^kind:|  name:'  # base Deployment is edge-relay
```

**Exact fix:**

```bash
# Point the patch at the name that exists
sed -i 's/name: edge-relayer/name: edge-relay/' overlays/prod/replicas-patch.yaml
# (Mirror-image fix: if the BASE was renamed and everything else expects
#  edge-relayer, rename the base instead. Fix whichever side drifted.)
```

**Verify:**

```bash
kubectl kustomize overlays/prod | grep -E 'kind: Deployment|replicas:'   # builds now; replicas: 3
kubectl apply -k overlays/prod
kubectl rollout status deployment/edge-relay -n edge --timeout=90s
kubectl get deploy edge-relay -n edge                                    # READY 3/3
```

**Production thinking:**

This entire class of failure is a CI gate. Running `kustomize build` (or `kubectl kustomize`) on every overlay in the pipeline and failing on error catches bad patch targets, missing `resources:` paths, and duplicate ids *before* a human waits on a deploy. The fix also belongs in git, not in a live `sed` — a GitOps controller (M18) would re-render the committed overlay; an out-of-band edit is overwritten on the next reconciliation.

</details>

---

## Break/fix 02 — Generator Name Mismatch

**Symptom — what you'd actually see:**

The prod overlay built cleanly and `apply -k` reported success, but `edge-relay` is `0/3`: its Pod is stuck in `CreateContainerConfigError`.

**Think about this before you open the answer:**

- When a generated object seems "missing," did you compare the *render* to the *cluster*? `kubectl kustomize` shows the hashed name Kustomize created and the exact reference it wrote (or didn't).
- Do you understand that reference rewriting is a name match — not magic — and that a four-character drift silently disables it?
- Did you resist "just create the missing ConfigMap by hand"? That treats the symptom; the next render would regenerate the hashed name and drift again.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The base Deployment's `envFrom` references `edge-relay-conf`, while the `configMapGenerator` is named `edge-relay-config`. Kustomize rewrites a reference to a generated object only when the reference's name matches the generator's declared name<sup><a href="https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/">[2]</a></sup>. They differ, so the reference is left as the bare `edge-relay-conf`; the render emits a ConfigMap named `edge-relay-config-<hash>` and a Deployment pointing at a name that doesn't exist. The object is valid, so admission accepts it; the kubelet then can't find the ConfigMap and fails container creation.

**Diagnostic commands (run in this order):**

```bash
# 1. The object exists, so the normal loop works this time
kubectl get pods -n edge -l app=edge-relay          # 0/1 CreateContainerConfigError
kubectl describe pod -n edge -l app=edge-relay | grep -A3 Events
#   Error: configmap "edge-relay-conf" not found

# 2. What ConfigMaps actually exist?
kubectl get configmap -n edge | grep edge-relay
#   edge-relay-config-<hash>  exists; edge-relay-conf does not

# 3. Read the render to see WHY the reference wasn't rewritten
cd /root/edge-relay
kubectl kustomize overlays/prod | grep -E 'kind: ConfigMap|name: edge-relay|configMapRef'
#   generator produced edge-relay-config-<hash>; Deployment asks for bare edge-relay-conf

# 4. Line up the two names
grep -A1 configMapRef base/deployment.yaml          # edge-relay-conf
grep -A1 configMapGenerator base/kustomization.yaml # edge-relay-config
```

**Exact fix:**

```bash
# Make the reference match the generator name so Kustomize rewrites it to the hashed object
sed -i 's/name: edge-relay-conf }/name: edge-relay-config }/' base/deployment.yaml
# (Mirror-image fix: rename the generator to edge-relay-conf instead. Either
#  way the two names must be identical — that match is what triggers the rewrite.)
```

**Verify:**

```bash
kubectl kustomize overlays/prod | grep -A1 configMapRef   # now edge-relay-config-<hash>
kubectl apply -k overlays/prod
kubectl rollout status deployment/edge-relay -n edge --timeout=90s
kubectl get pods -n edge -l app=edge-relay                # Running, 1/1
```

**Production thinking:**

The hash-and-rewrite machinery is what makes config changes roll a workload automatically — that's why you keep it rather than hand-writing ConfigMaps. Two operational corollaries: run `apply -k --prune` (or let a GitOps controller GC) so superseded `*-<hash>` ConfigMaps don't accumulate, and remember that `secretGenerator` behaves identically but only base64-encodes — encrypting secrets for git is a separate concern (M11).

</details>

---

## Break/fix 03 — commonLabels vs the Immutable Selector

**Symptom — what you'd actually see:**

`edge-relay` is running and healthy on the *lab* spec (one replica, the lab image). Promoting the same base to prod fails: `kubectl apply -k overlays/prod` exits non-zero and the prod spec never lands.

**Think about this before you open the answer:**

- When an apply is rejected for an immutable field, did you diff the live object against the render? The rejection names the field; the render shows what your overlay tried to put there.
- Did you connect the injected selector label back to `commonLabels` — and know that `labels:` with `includeSelectors: false` is the surgical alternative?
- Did you understand *why* this passed in the baseline (fresh create) but failed here (promotion over a live object)? The bug only exists relative to an already-running selector.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The prod overlay uses `commonLabels: {tier: prod}`. `commonLabels` applies its labels to metadata, Pod templates, **and every selector** — including the Deployment's `spec.selector`, which is immutable after creation<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#selector">[3]</a></sup>. The build is valid, but applying it onto the already-running Deployment tries to change the selector from `{app: edge-relay}` to `{app: edge-relay, tier: prod}`, and the API server rejects it: `spec.selector ... field is immutable`. (The lab overlay avoided this by using the modern `labels:` transformer with `includeSelectors: false`<sup><a href="https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/labels/">[4]</a></sup>.)

**Diagnostic commands (run in this order):**

```bash
# 1. Which spec is live? (prod should be 3 replicas)
kubectl get deploy edge-relay -n edge               # READY 1/1 — still the lab spec

# 2. Reproduce the rejection and read the field the API server names
cd /root/edge-relay
kubectl apply -k overlays/prod
#   The Deployment "edge-relay" is invalid: spec.selector: ... field is immutable

# 3. Diff the live selector against what the overlay renders
kubectl get deploy edge-relay -n edge -o jsonpath='{.spec.selector.matchLabels}{"\n"}'  # {"app":"edge-relay"}
kubectl kustomize overlays/prod | grep -A2 matchLabels                                   # app + tier: prod

# 4. Find the transformer that reached into the selector
grep -A1 commonLabels overlays/prod/kustomization.yaml
```

**Exact fix:**

Replace `commonLabels` with the `labels:` transformer set to leave selectors alone.

```bash
# In overlays/prod/kustomization.yaml, replace:
#   commonLabels:
#     tier: prod
# with:
#   labels:
#     - pairs: { tier: prod }
#       includeSelectors: false
awk '
  /^commonLabels:/ { print "labels:"; print "  - pairs: { tier: prod }"; print "    includeSelectors: false"; skip=1; next }
  skip==1 && /^[[:space:]]+tier: prod[[:space:]]*$/ { skip=0; next }
  { print }
' overlays/prod/kustomization.yaml > /tmp/prod.yaml && mv /tmp/prod.yaml overlays/prod/kustomization.yaml
```

If the label genuinely must be *in* the selector, the only path is to delete and recreate the Deployment (`kubectl delete deploy edge-relay -n edge`, then apply) — an outage — which is exactly why you keep selector-touching labels out of promotions.

**Verify:**

```bash
kubectl kustomize overlays/prod | grep -A2 matchLabels    # selector back to app only
kubectl apply -k overlays/prod
kubectl rollout status deployment/edge-relay -n edge --timeout=90s
kubectl get deploy edge-relay -n edge -o jsonpath='selector={.spec.selector.matchLabels}  meta-tier={.metadata.labels.tier}{"\n"}'
# selector={"app":"edge-relay"}  meta-tier=prod  — label applied, selector untouched, READY 3/3
```

**Production thinking:**

`commonLabels` is deprecated precisely because of this footgun; prefer the explicit `labels:` transformer and reserve `includeSelectors: true` for greenfield resources. More broadly: a change that's valid in isolation can still be rejected by the state already in the cluster, which is why promotion pipelines apply to a canary/stage environment before prod — the immutable-field rejection surfaces one environment earlier, where the blast radius is small.

</details>

---

# `m17-helm/` — M17 — Helm Fundamentals

**Category:** Helm charts & releases

Concept reading: `m17-helm/LESSON.md`

## Break/fix 01 — Values Key Ignored

**Symptom — what you'd actually see:**

The `voicemail` release was installed from a values file that sets 3 replicas, `helm install` exited 0, and `helm list` shows `deployed`. But the Deployment runs one pod. The override appears in `helm get values` yet has no effect.

**Think about this before you open the answer:**

- Did you distinguish `helm get values` (what you asked for) from `helm get manifest` (what rendered)? The gap between them *is* the bug.
- Did you reach for `helm get values -a` to see the effective merged values, where the stray key and the real key sit side by side?
- Do you know Helm keeps unknown override keys silently — so "the value is in the release" doesn't mean "the template uses it"?

The anti-pattern: trust `helm get values` alone, see `replicas: 3`, and conclude Helm is broken — instead of checking what rendered.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The values file sets `replicas: 3`. The chart's Deployment template reads `.Values.replicaCount`, not `.Values.replicas`. Helm does not validate override keys against the chart, so it keeps the unknown `replicas` key in the release's values and renders the chart's default `replicaCount: 1`<sup><a href="https://helm.sh/docs/chart_template_guide/values_files/">[1]</a></sup>. Right value, wrong key path.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm the gap: what you asked for vs what's running
helm get values voicemail -n app-services      # shows replicas: 3 (what you supplied)
kubectl get deployment voicemail -n app-services   # READY 1/1

# 2. Read what actually rendered — the authoritative output
helm get manifest voicemail -n app-services | grep -E "replicas:"
# replicas: 1  -> the override never reached the manifest

# 3. See the merged/effective values — the wrong key sits next to the real one
helm get values voicemail -n app-services -a
# replicaCount: 1   <- what the template reads (default)
# replicas: 3       <- what you set (nothing reads this)

# 4. Confirm the key the chart actually consumes
helm show values /root/voicemail | grep -i replica   # replicaCount
```

**Exact fix:**

Set the value at the key the chart reads. `--reuse-values` preserves the required `sipRealm`:

```bash
helm upgrade voicemail /root/voicemail \
  --namespace app-services \
  --reuse-values \
  --set replicaCount=3
```

**Verify:**

```bash
helm get manifest voicemail -n app-services | grep -E "replicas:"   # replicas: 3
kubectl get deployment voicemail -n app-services                    # READY 3/3
```

**Production thinking:**

The `--set` fixes the live release; the values *file* on disk still has the wrong key, so the next install repeats the bug. The durable fix corrects the file in git (a reviewed commit) so the source of truth is right. Better still, ship a `values.schema.json` with the chart: it rejects unknown/mistyped keys at install time, converting this silent no-op into a hard error for every consumer.

</details>

---

## Break/fix 02 — Bad Upgrade, Rollback

**Symptom — what you'd actually see:**

A `helm upgrade` bumped the `voicemail` image tag, exited 0, and `helm status` reports `deployed`, revision 2. But the rollout won't finish: two pods `Running`, one stuck `ImagePullBackOff`, and `kubectl get deployment` shows `UP-TO-DATE 1` against a replica count of 2.

**Think about this before you open the answer:**

- Did you read past `helm status: deployed` to `kubectl get pods` / `rollout status`? Helm "deployed" means manifest applied, not workload healthy.
- Did you use `helm history` to find a known-good revision instead of hand-reconstructing the fix?
- Did you recover *through Helm* (`helm rollback`) rather than `kubectl rollout undo` or `kubectl edit`?

The anti-pattern: `kubectl rollout undo deployment/voicemail`. It fixes the live object but leaves Helm's stored release on the broken revision 2 — so the next `helm upgrade` (or a GitOps reconcile) re-applies the break, and now the release record and the cluster disagree.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The upgrade set `image.tag` to `1.25-eol-removed`, a tag that doesn't exist. The rendered manifest is valid, so Helm applied it and recorded revision 2 as `deployed` — Helm grades the apply, not Pod readiness (no `--wait` was passed)<sup><a href="https://helm.sh/docs/intro/using_helm/">[2]</a></sup>. The Deployment's rolling update creates one new-image pod that can't pull, and (with default `maxUnavailable`) keeps the old pods serving, so the rollout wedges rather than taking the app fully down.

**Diagnostic commands (run in this order):**

```bash
# 1. Helm's view vs the workload's view
helm status voicemail -n app-services            # STATUS: deployed, REVISION: 2
kubectl get pods -n app-services -l app=voicemail # 2 Running + 1 ImagePullBackOff
kubectl get deployment voicemail -n app-services  # UP-TO-DATE 1 -> rollout stuck

# 2. Confirm the cause
kubectl describe pod -n app-services -l app=voicemail | grep -A3 Failed
# Failed to pull image "nginx:1.25-eol-removed"

# 3. Read the history for the recovery target
helm history voicemail -n app-services            # rev 1 superseded (good), rev 2 deployed (bad)
helm get values voicemail -n app-services --revision 1 -a | grep -A2 image  # rev 1 used nginx:1.25
```

**Exact fix:**

Roll back to the last good revision through Helm:

```bash
helm rollback voicemail 1 -n app-services
```

**Verify:**

```bash
helm history voicemail -n app-services   # revision 3, "Rollback to 1", deployed
kubectl get deployment voicemail -n app-services \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # nginx:1.25
kubectl get deployment voicemail -n app-services                 # UP-TO-DATE matches replicas
```

**Production thinking:**

`helm rollback` is the right *incident* action. The durable fix corrects the image tag in the values in git and rolls *forward* (a new, good revision) so the release history reflects intent. To make this class of failure loud instead of silent, pipelines should run `helm upgrade --atomic --wait --timeout 5m`: the upgrade then waits for readiness and auto-rolls-back on failure, so a bad tag never reports `deployed`. Note Helm 4's `--wait` needs the `watch` RBAC verb on the release's resources.

</details>

---

## Break/fix 03 — Render Required Value

**Symptom — what you'd actually see:**

A deploy job ran `helm install voicemail` and failed non-zero. Nothing deployed — `helm list` shows no release, and there are no `voicemail` objects in the namespace. There's no Pod to inspect.

**Think about this before you open the answer:**

- Did you recognize a *render-stage* failure — no release, no objects — as different from a runtime failure, and stop looking for a Pod?
- Did you read the render error, which names the template and the exact value?
- Did you use `helm template` to reproduce and iterate offline instead of repeatedly hitting the cluster?

The anti-pattern: treat "nothing deployed" as a cluster/RBAC/scheduling problem and dig through events and nodes — when the failure was client-side, in the render, and the error message already named the cause.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The install omitted `config.sipRealm`. The Deployment template wraps that value in `required`, which aborts the *render* when it's empty<sup><a href="https://helm.sh/docs/chart_template_guide/functions_and_pipelines/">[3]</a></sup>. Render happens client-side, before anything is applied, so the failure never reaches the cluster: no release is recorded, no objects are created.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm the release is genuinely absent (not half-installed)
helm list -n app-services
helm list -A --all --pending --failed | grep voicemail || echo "no release in any state"
kubectl get all -n app-services -l app=voicemail   # nothing

# 2. Make the failure show itself — re-run the install
helm install voicemail /root/voicemail --namespace app-services --set replicaCount=2
# Error: execution error at (voicemail/templates/deployment.yaml:NN:MM):
#        voicemail: .Values.config.sipRealm is required (the SIP realm to register under)

# 3. Reproduce offline — no cluster needed to debug a render error
helm template voicemail /root/voicemail --set replicaCount=2   # same error

# 4. Confirm the chart's expectation
helm show values /root/voicemail | grep -A2 "config:"   # sipRealm: "" (empty default)
```

**Exact fix:**

Supply the required value (render clean first if you like):

```bash
helm install voicemail /root/voicemail \
  --namespace app-services \
  --set replicaCount=2 \
  --set config.sipRealm=polyphone.example
```

**Verify:**

```bash
helm list -n app-services                          # voicemail, deployed
kubectl get deployment voicemail -n app-services   # READY 2/2
kubectl get deployment voicemail -n app-services \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SIP_REALM")].value}{"\n"}'
# polyphone.example
```

**Production thinking:**

`--set` on the command line works but relies on every caller remembering the value. The durable fix puts required inputs in a committed values file the pipeline always applies, so the install can't run without them. Chart-author's choice: `required` (hard-fail, correct when there's no safe default) versus a sensible default in `values.yaml` (convenient, correct when one exists). A value like a SIP realm that must differ per environment is a legitimate `required`; a value with an obvious default shouldn't be.

</details>

---

# `m18-flux/` — M18 — Flux (GitOps Delivery)

**Category:** Flux GitOps

Concept reading: `m18-flux/LESSON.md`

## Break/fix 01 — Source Ref Not Found

**Symptom — what you'd actually see:**

A configured Flux pipeline delivers nothing. `dialplan` and `voicemail` are absent from `app-services`, no Pod is crashing or `Pending`, and `flux get all` shows consumers that aren't ready but don't obviously *fail*.

**Think about this before you open the answer:**

- Did you read the **source** before the consumers? A pipeline delivering nothing is almost always a stalled source, and the consumers' messages point back at it.
- Did you recognize that "nothing deployed, nothing crashing" is a *reconcile* failure, not a workload failure — so there's no Pod to describe?
- Did you read the `Ready` condition message, which names the exact failing ref?

The anti-pattern: hunt through `app-services` for a broken Pod, or blame RBAC/scheduling, when the failure is one object up the chain and the message already names it.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `GitRepository` `spec.ref.branch` is `release-2024`, a branch the repo never had (it has only `main`). source-controller can't resolve `refs/heads/release-2024`, so it produces no artifact and reports `Ready: False`. Every consumer downstream (`apps` Kustomization, `voicemail` HelmRelease) has no content to apply and stalls waiting on the source<sup><a href="https://fluxcd.io/flux/components/source/gitrepositories/">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm the workloads are genuinely absent (not crashing)
kubectl get deploy -n app-services -l 'app in (dialplan,voicemail)'   # nothing

# 2. Read the SOURCE first — top of the pipeline
flux get sources git
# polyphone-config  READY False  message: couldn't find remote ref 'refs/heads/release-2024'
kubectl describe gitrepository polyphone-config -n flux-system | sed -n '/Conditions:/,$p'

# 3. Confirm consumers are only *waiting*, not independently broken
flux get kustomizations        # apps: not ready, blocked on the source
flux get helmreleases          # voicemail: not ready

# 4. Read the ref the source is pointed at
kubectl get gitrepository polyphone-config -n flux-system -o jsonpath='{.spec.ref}{"\n"}'
# {"branch":"release-2024"}  -> a branch that doesn't exist
```

**Exact fix:**

Point the source at the branch that exists, then reconcile:

```bash
kubectl patch gitrepository polyphone-config -n flux-system \
  --type=merge -p '{"spec":{"ref":{"branch":"main"}}}'
flux reconcile source git polyphone-config
flux reconcile kustomization apps --with-source
```

**Verify:**

```bash
flux get sources git                                   # READY True, stored artifact for main@sha1:...
kubectl get deploy dialplan -n app-services            # READY 2/2
```

**Production thinking:**

The `kubectl patch` fixes this cluster. In a bootstrapped setup the `GitRepository` manifest lives in git, so the durable fix is a reviewed commit correcting `spec.ref.branch` — otherwise the next reconcile of Flux's own config reapplies `release-2024`. This class of failure is invisible to Pod-level alerting (nothing crashes), so alert on Flux objects: `Ready: False` on sources, or source revision lagging git HEAD.

</details>

---

## Break/fix 02 — Kustomization Suspended

**Symptom — what you'd actually see:**

Drift that Flux corrected instantly in the baseline now persists. `dialplan` runs 5 replicas; git declares 2; Flux isn't pulling it back. The source is healthy and `flux get all` looks fine at a glance.

**Think about this before you open the answer:**

- Did you notice the `SUSPENDED` column instead of trusting a green-looking `READY`? A suspended object hides in plain sight because it reports its last state.
- Did you separate "drift not corrected" (reconciliation is off) from "source broken" (fetch failed)? Different layer, different fix.
- Did you recover with `flux resume` rather than re-scaling by hand (which suspend would just... not revert, masking the real issue)?

The anti-pattern: `kubectl scale dialplan --replicas=2` to "fix" it. It papers over the symptom while reconciliation stays off — the next drift (or a needed git change) still won't apply, and you've hidden the suspended consumer.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `apps` Kustomization has `spec.suspend: true`. A suspended object doesn't reconcile — no drift correction, no new commits applied, no pruning — and it reports its last (healthy-looking) state, so nothing errors<sup><a href="https://fluxcd.io/flux/components/kustomize/kustomizations/">[2]</a></sup>. The hand-scaled 5 replicas (an out-of-band change from an incident) is never reverted because the controller that would revert it is paused.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm the drift: live vs git
kubectl get deploy dialplan -n app-services            # READY 5/5
grep replicas /root/polyphone-config/apps/dialplan.yaml # replicas: 2

# 2. Rule out the source (top-down)
flux get sources git                                   # polyphone-config READY True

# 3. Read the consumer — the SUSPENDED column is the tell
flux get kustomizations                                # apps  SUSPENDED True
kubectl get kustomization apps -n flux-system -o jsonpath='{.spec.suspend}{"\n"}'   # true
```

**Exact fix:**

Resume reconciliation; Flux corrects the drift on the first pass:

```bash
flux resume kustomization apps
```

**Verify:**

```bash
flux get kustomizations                                # apps  SUSPENDED False  READY True
kubectl get deploy dialplan -n app-services            # READY 2/2 (drift corrected)
```

**Production thinking:**

`flux resume` is the recovery. Two durable lessons: the emergency scale to 5 was lost because it lived only in the cluster — if 5 was correct it belonged in a git commit; and `suspend` during an incident needs a tripwire (an alert on suspended Flux objects, or a runbook step to `resume`) so it isn't silently forgotten, quietly stopping all delivery for that object.

</details>

---

## Break/fix 03 — HelmRelease Dependency

**Symptom — what you'd actually see:**

The `voicemail` HelmRelease is stuck `READY False` and never installs — no `voicemail` Deployment in `app-services` — even though the source is `Ready`, the `apps` Kustomization is `Ready`, `dialplan` and `message-store` are running, and the chart renders.

**Think about this before you open the answer:**

- Did you read *why* the release said it wasn't ready (`DependencyNotReady`) instead of assuming a render or install failure? A blocked release is different from a failed one.
- Did you verify the named dependency exists (`flux get helmreleases`, since `dependsOn` is same-kind) — turning "waiting" into "waiting on nothing"?
- Did you confirm the rest of the pipeline was healthy, isolating the fault to the reference?

The anti-pattern: dig into the chart, values, or helm-controller logs looking for a render error — when the release never got as far as rendering, because its dependency gate never opened.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`spec.dependsOn` names a HelmRelease called `message-cache` that doesn't exist; the backing-store release `voicemail` should wait for is `message-store` (the store was renamed and the dependency reference never caught up). A `HelmRelease`'s `dependsOn` references other HelmReleases, and gates the release until every listed one is `Ready`; an object that doesn't exist can never be ready, so helm-controller holds the release as `DependencyNotReady` indefinitely<sup><a href="https://fluxcd.io/flux/components/helm/helmreleases/">[3]</a></sup>. This is Flux waiting correctly on a reference that happens to be wrong (a typo or a stale rename).

**Diagnostic commands (run in this order):**

```bash
# 1. Read the release's Ready condition — it says why it's waiting
flux get helmreleases
# voicemail  READY False  message: dependency 'flux-system/message-cache' is not ready
kubectl get helmrelease voicemail -n flux-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}{"\n"}'   # DependencyNotReady

# 2. Does the named dependency exist? dependsOn is same-kind, so check HelmReleases
flux get helmreleases                                  # message-store is READY True — no 'message-cache'
kubectl get helmrelease voicemail -n flux-system -o jsonpath='{.spec.dependsOn}{"\n"}'
# [{"name":"message-cache"}]  -> points at nothing

# 3. Rule out the other layers
flux get sources git                                   # READY True
kubectl get deploy dialplan -n app-services            # READY 2/2
```

**Exact fix:**

Point `dependsOn` at the release that actually exists, then reconcile:

```bash
kubectl patch helmrelease voicemail -n flux-system \
  --type=merge -p '{"spec":{"dependsOn":[{"name":"message-store"}]}}'
flux reconcile helmrelease voicemail
```

**Verify:**

```bash
flux get helmreleases                                  # voicemail READY True
helm list -n app-services                              # voicemail deployed
kubectl get deploy voicemail -n app-services           # READY 2/2
```

**Production thinking:**

The `kubectl patch` fixes this cluster; the durable fix corrects the `dependsOn` name in the `HelmRelease` in git, ideally with CI that validates references so a stale rename can't ship. And keep `dependsOn` honest — list only genuine ordering needs, because every dependency is one more thing that can block the release, and `dependsOn` waits for `Ready` at install, not for continued health afterward.

</details>

---

# `m19-multi-cluster/` — M19 — Multi-cluster Fleet

**Category:** Multi-cluster fleet config

Concept reading: `m19-multi-cluster/LESSON.md`

## Break/fix 01 — Stale Cluster Variable

**Symptom — what you'd actually see:**

`edge-relay` in `eu-central-1` is healthy and `Running`, but it emits `us-east-1` in its telemetry. The `prod-eu-central-1` cluster renders and applies cleanly; only the `REGION` value is wrong, and only for this region. The rest of the fleet is fine.

**Think about this before you open the answer:**

- When a fleet value is wrong but the workload is healthy, did you render the cluster instead of reaching for `describe`/`logs` (which have nothing to show)?
- Did you trace the value up its layer path and land on the *one* file that owns it, rather than editing the leaf or the base at random?
- Do you understand that fixing the owning layer corrects every cluster that inherits it — the payoff of one home per variable?

The anti-pattern: patch the live ConfigMap by hand. The next render regenerates the stale value and the drift returns.

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`regions/eu-central-1/kustomization.yaml` was created by cloning `regions/us-east-1/` and its `REGION` generator literal was never changed — it still reads `us-east-1`. The region overlay is the **owning layer** for `REGION` (a region-scoped cluster variable), so every cluster in `eu-central-1` inherits the stale value<sup><a href="https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/">[3]</a></sup>. The `region:` label<sup><a href="https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/labels/">[5]</a></sup> was updated in the clone; the `REGION` config literal was the one line missed. The render is valid and the workload runs — the value is simply stale in the layer that owns it.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm healthy, not crashing — this is a wrong value, not a failure
kubectl get pods -n edge -l app=edge-relay          # Running

# 2. Read what the affected cluster actually renders
cd /root/fleet
kubectl kustomize clusters/prod-eu-central-1 | grep -E 'REGION|region:'
#   region: eu-central-1  (label, correct)   REGION: us-east-1  (config, WRONG)

# 3. Trace REGION up the layer path — which layer owns it?
grep -rn REGION base regions/eu-central-1 clusters/prod-eu-central-1
#   only regions/eu-central-1 sets it, and it says us-east-1 — the owning layer is stale

# 4. See the drift against the sibling it was cloned from
diff regions/us-east-1/kustomization.yaml regions/eu-central-1/kustomization.yaml
#   differ on label + MAX_SESSIONS (correct); agree on REGION=us-east-1 (the miss)
```

**Exact fix:**

Correct the value in its owning layer.

```bash
sed -i 's/REGION=us-east-1/REGION=eu-central-1/' regions/eu-central-1/kustomization.yaml
# (us-east-1 appears only on the stale literal in this file, so the substitution is precise.
#  Fix it once here and every cluster in eu-central-1 inherits the correction.)
```

**Verify:**

```bash
kubectl kustomize clusters/prod-eu-central-1 | grep -E 'REGION|region:'   # both eu-central-1
kubectl apply -k clusters/prod-eu-central-1
kubectl rollout status deployment/edge-relay -n edge --timeout=90s
REF=$(kubectl get deploy edge-relay -n edge -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
kubectl get configmap "$REF" -n edge -o jsonpath='REGION={.data.REGION}{"\n"}'   # eu-central-1
```

**Production thinking:**

This is invisible to every runtime check — the Pod is `Ready`, events are clean, `describe` is silent. It's caught at the render, so the guard belongs in CI: assert that each `regions/<r>/` overlay renders `REGION=<r>` (the folder name and the variable must agree). A cloned overlay whose `REGION` still names the sibling then fails the pipeline instead of a customer's telemetry. The fix belongs in git, not a live `kubectl edit` — a GitOps controller (M18) re-renders the committed overlay and would overwrite an out-of-band patch on the next reconcile.

</details>

---

## Break/fix 02 — Shadowed Override

**Symptom — what you'd actually see:**

Capacity planning raised the `us-east-1` session ceiling to `8000` in the region overlay, but `prod-us-east-1` still renders `MAX_SESSIONS=5000`. The region file plainly reads `8000`; the render disagrees with it. The cluster is healthy, running on the shadowed `5000`.

**Think about this before you open the answer:**

- When editing the layer that "owns" a value doesn't change the render, did you grep the *whole* path and take the last writer — instead of assuming the region file was being ignored?
- Do you understand composition order well enough to know a cluster overlay always wins over its region, and that a stale per-cluster override therefore shadows every regional update silently?
- Did you remove the shadow rather than duplicate the region's value into the leaf (which would leave two homes for one variable and re-create the drift risk)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`clusters/prod-us-east-1/kustomization.yaml` carries a leftover per-cluster `configMapGenerator` merge pinning `MAX_SESSIONS=5000`, from before capacity moved to the region layer. Composition order is base → region → cluster, and the **last layer to set a field wins**<sup><a href="https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/">[2]</a></sup>. The cluster overlay writes after the region, so its `5000` shadows the region's new `8000`. The owning layer is correct; a more-specific layer overrides it<sup><a href="https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/">[3]</a></sup>. Editing the region changes nothing, because the shadow sits on top of it.

**Diagnostic commands (run in this order):**

```bash
# 1. The layer you'd fix is already correct; the render disagrees
cd /root/fleet
grep MAX_SESSIONS regions/us-east-1/kustomization.yaml     # 8000
kubectl kustomize clusters/prod-us-east-1 | grep MAX_SESSIONS   # 5000 — the render wins

# 2. Grep the whole path, take the last writer
grep -rn MAX_SESSIONS base regions/us-east-1 clusters/prod-us-east-1
#   base=500, region=8000, cluster=5000 — the cluster writes last, so 5000 wins

# 3. Read the shadow
cat clusters/prod-us-east-1/kustomization.yaml
#   a per-cluster configMapGenerator merge pinning MAX_SESSIONS=5000
```

**Exact fix:**

Remove the shadow so the owning layer's value flows through.

```bash
# delete the leftover per-cluster override block
sed -i '/^# Leftover/,$d' clusters/prod-us-east-1/kustomization.yaml
# (or reconcile it to 8000 if per-cluster capacity were intended — here the
#  standard is regional, so removing the shadow is the correct fix)
```

**Verify:**

```bash
kubectl kustomize clusters/prod-us-east-1 | grep MAX_SESSIONS   # 8000
kubectl apply -k clusters/prod-us-east-1
kubectl rollout status deployment/edge-relay -n edge --timeout=90s
REF=$(kubectl get deploy edge-relay -n edge -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
kubectl get configmap "$REF" -n edge -o jsonpath='MAX_SESSIONS={.data.MAX_SESSIONS}{"\n"}'   # 8000
```

**Production thinking:**

A shadow is a landmine — it silently defeats every future change to the owning layer, forever, with no error. After you move any value to a shared layer (base or region), the operational follow-up is to sweep for leftovers that still set it more specifically: `grep -rn MAX_SESSIONS clusters/` across the fleet. That's a good standing lint, not a one-time cleanup — new overlays clone old ones, and the shadow comes back. This is also the argument for keeping overlays *thin*: the less a leaf sets, the less it can shadow.

</details>

---

## Break/fix 03 — Promotion in the Wrong Overlay

**Symptom — what you'd actually see:**

`nginx:1.27` was promoted to stage, but stage still runs `1.25` while prod renders `1.27`. The promotion ladder is non-monotonic — stage is *behind* prod. Two symptoms at once: the target tier didn't advance, and a later tier overshot to a tag it was never approved for.

**Think about this before you open the answer:**

- Did you read the *ladder* rather than one tier in isolation? The bug is only visible as a relationship — stage behind prod — not as a single wrong value.
- Do you understand that the layer sets the blast radius, so a per-tier pin in the wrong tier both fails to advance the target and overshoots another?
- Did you *move* the pin (advance one, remove the other) rather than just bumping stage — which would leave prod wrongly on `1.27`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `images:` pin for `1.27` was written into `clusters/prod-us-east-1/kustomization.yaml` instead of `clusters/stage-us-east-1/`. Prod's overlay is supposed to carry no image pin and inherit the base default `1.25`<sup><a href="https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/">[4]</a></sup>; the stray pin makes it overshoot the gate to `1.27`, and stage — where the pin belonged — was left on `1.25`. The value is correct; it's in the wrong layer, and **the layer you edit is the blast radius**<sup><a href="https://fluxcd.io/flux/guides/repository-structure/">[6]</a></sup>. Promotion is *moving* a pin one tier at a time, not editing an arbitrary overlay.

**Diagnostic commands (run in this order):**

```bash
# 1. Read the ladder — it should be monotonic (no tier behind the one after it)
cd /root/fleet
for t in lab stage prod; do echo -n "$t: "; kubectl kustomize clusters/$t-us-east-1 | grep -m1 'image: nginx'; done
#   lab 1.27, stage 1.25, prod 1.27 — stage is behind prod: wrong

# 2. The applied stage cluster confirms the stall
kubectl get deploy edge-relay -n edge -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # nginx:1.25

# 3. Find where the pin actually landed
grep -rn 'newTag' clusters/lab-us-east-1 clusters/stage-us-east-1 clusters/prod-us-east-1
#   lab 1.27 (ok), stage 1.25 (never advanced), prod 1.27 (should have NO pin)
cat clusters/prod-us-east-1/kustomization.yaml   # the images: block that doesn't belong
```

**Exact fix:**

Move the pin — advance stage, unpin prod.

```bash
sed -i 's/newTag: "1.25"/newTag: "1.27"/' clusters/stage-us-east-1/kustomization.yaml
sed -i '/^images:/,/newTag/d' clusters/prod-us-east-1/kustomization.yaml
# (by hand: set stage's newTag to 1.27, and delete the whole images: block from prod)
```

**Verify:**

```bash
for t in lab stage prod; do echo -n "$t: "; kubectl kustomize clusters/$t-us-east-1 | grep -m1 'image: nginx'; done
#   lab 1.27, stage 1.27, prod 1.25 — monotonic again
kubectl apply -k clusters/stage-us-east-1
kubectl rollout status deployment/edge-relay -n edge --timeout=90s
kubectl get deploy edge-relay -n edge -o jsonpath='stage running {.spec.template.spec.containers[0].image}{"\n"}'   # nginx:1.27
```

**Production thinking:**

A monotonic-ladder check is a cheap, high-value CI gate: render every tier of a workload and assert the promotion order (prod's tag is never ahead of stage's, stage's never ahead of lab's). It catches both a stalled promotion and an overshoot in one assertion. The deeper discipline: promotion is a *move*, ideally a reviewed diff whose only change is the one pin advancing one tier — anything else in the diff is a mistake. And keep per-tier rollouts out of the base entirely; a tag in the base hands every tier the change at once and there is no gate left to catch it. Drift where someone edited a tier directly (rather than promoting into it) is exactly what M18's drift detection exists to surface.

</details>

---

# `m20-kyverno-opa/` — M20 — Policy as Code: Kyverno & OPA Gatekeeper

**Category:** Policy-as-code (Kyverno/OPA)

Concept reading: `m20-kyverno-opa/LESSON.md`

## Break/fix 01 — Validation rejects a rollout

**Symptom — what you'd actually see:**

`billing-api` in `tenant-apps` is `0/1` with **no Pods at all** — not `Pending`, not `ImagePullBackOff`, nothing to `logs` or `describe` at the Pod level. The Deployment and ReplicaSet exist; the Pod count is zero.

**Think about this before you open the answer:**

Reading a Kyverno denial and recognizing an admission rejection of controller-created Pods. Self-grading questions:

- Did you look at the **ReplicaSet's events** (where the reason lives) rather than hunting for a Pod that doesn't exist?
- Did you read the denial for the **policy and rule name**, instead of assuming a scheduling or image problem?
- Did you fix the **workload** to comply, understanding the policy was doing its job — not disable or delete the policy?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`require-resource-limits` is a Kyverno validate `ClusterPolicy` with `failureAction: Enforce`<sup><a href="https://kyverno.io/docs/policy-types/cluster-policy/validate/">[1]</a></sup>, scoped to `tenant-apps`, requiring every container to set CPU and memory `limits`. `billing-api` declares only `requests`. Because the policy disables autogen<sup><a href="https://kyverno.io/docs/policy-types/cluster-policy/autogen/">[3]</a></sup>, it guards bare `Pod` creates, so the Deployment is admitted but every Pod its ReplicaSet tries to create is rejected at admission — the `0/N`-no-Pods signature M10 taught for PodSecurity. The image is `nginx:1.25`, so `disallow-latest-tag` is satisfied; the only violation is the missing limits.

**Diagnostic commands (run in this order):**

```bash
# 1. No Pods, and the reason is on the ReplicaSet, not a Pod
kubectl get deploy,rs,pods -n tenant-apps -l app=billing-api        # deploy 0/1, rs CURRENT 0, no pods
kubectl describe rs -n tenant-apps -l app=billing-api | sed -n '/Events/,$p'
#    Error creating: admission webhook "validate.kyverno.svc-fail" denied the request:
#    ... require-resource-limits ... "Resource limits (cpu and memory) are required ..."

# 2. Read the rule against the workload
kubectl get clusterpolicy require-resource-limits -o yaml | grep -A15 'rules:'   # requires limits.cpu/memory
kubectl get deploy billing-api -n tenant-apps \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' ; echo             # requests only, no limits
```

**Exact fix:**

Make the workload comply — add the `limits` the rule requires (the policy is correct):

```bash
kubectl patch deployment billing-api -n tenant-apps --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/resources/limits",
   "value":{"cpu":"100m","memory":"64Mi"}}]'
```

**Verify:**

```bash
kubectl rollout status deployment/billing-api -n tenant-apps --timeout=60s
kubectl get pods -n tenant-apps -l app=billing-api                  # 1/1 Running
```

**Production thinking:**

This is what a new compliance policy does the first time it meets a non-compliant workload. Roll such policies out as `Audit` first<sup><a href="https://kyverno.io/docs/policy-reports/">[4]</a></sup> — read the PolicyReports to see what *would* be rejected — then flip to `Enforce`, so you find violations in a report instead of in a failed rollout. And note autogen: with it on (the default), this same violation is rejected at `kubectl apply`, which is friendlier for CI but leaves no object to inspect.

</details>

---

## Break/fix 02 — A mutation that never fired

**Symptom — what you'd actually see:**

`tenant-portal` in `tenant-apps` is `1/1` and healthy, but its Pod has no `owner` label — the one the platform's `mutate` policy is supposed to inject on every tenant Pod. Nothing was rejected, nothing logs an error; the failure is an *absence*.

**Think about this before you open the answer:**

Recognizing a mutation gap and the admission-time-only rule. Self-grading questions:

- Did you treat the **absence** of a field as the symptom, rather than looking for a crash or a rejection that isn't there?
- Did you read the policy's `match` and spot that it selected the **wrong namespace**, fixing the *policy* (not the workload)?
- Did you know that correcting the policy **doesn't** retro-fix the running Pod, and `rollout restart` to re-admit it? (Just fixing the policy and re-checking would show the label still missing.)

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`add-owner-label` is a Kyverno `mutate` policy that injects `owner=platform` when absent<sup><a href="https://kyverno.io/docs/policy-types/cluster-policy/mutate/">[2]</a></sup>. Its rule `match` names `namespaces: [tenant-app]` — a typo; the real namespace is `tenant-apps`. The selector matches nothing, so the rule never fired on `tenant-portal`'s Pods. A mutation that doesn't match simply does nothing — no error surfaces, which is why the policy *looks* fine.

**Diagnostic commands (run in this order):**

```bash
# 1. Healthy Pod, missing label
kubectl get pods -n tenant-apps -L owner                    # tenant-portal Running, OWNER empty
kubectl get clusterpolicy add-owner-label                   # READY: true — the engine is fine

# 2. Read the rule's match against the Pod's actual namespace
kubectl get clusterpolicy add-owner-label -o yaml | grep -A10 'match:'   # namespaces: [tenant-app]
kubectl get pod -n tenant-apps -l app=tenant-portal \
  -o jsonpath='{.items[0].metadata.namespace}' ; echo                    # tenant-apps  (the 's' is missing above)
```

**Exact fix:**

Correct the policy's `match` namespace, **then re-admit** the Pod — mutation happens only at admission, so fixing the policy alone doesn't relabel a running Pod:

```bash
# correct the namespace (re-apply the policy with namespaces: [tenant-apps]), then:
kubectl rollout restart deployment/tenant-portal -n tenant-apps
kubectl rollout status  deployment/tenant-portal -n tenant-apps --timeout=60s
```

**Verify:**

```bash
kubectl get pods -n tenant-apps -L owner                    # tenant-portal's new Pod now shows owner=platform
```

**Production thinking:**

Silent mutation gaps are the dangerous kind — a defaulting policy that quietly stops applying (a typo, a `match` narrowed in a refactor) leaves workloads missing a guardrail with no alarm. Alert on the *outcome* (e.g. tenant Pods lacking `owner`) rather than trusting the policy to be `READY`. And treat "does anything already running need re-admitting?" as part of every mutate-policy change — Kyverno's `mutateExisting` exists precisely because the admission rewrite doesn't reach live resources.

</details>

---

## Break/fix 03 — Image admission rejects the tag

**Symptom — what you'd actually see:**

`call-recorder` in `tenant-apps` is `0/1` with no Pods — the same shape as breakfix-01. Deployment and ReplicaSet exist; zero Pods; the reason is on the ReplicaSet.

**Think about this before you open the answer:**

Telling an image rejection from a limits rejection (both `0/N`), and reading the image rule. Self-grading questions:

- Did the **policy name in the denial** (`disallow-latest-tag`, not `require-resource-limits`) tell you it was the image, so you inspected the tag rather than the resources?
- Did you pin to an **explicit tag** rather than trying to weaken or exclude the policy?
- Did you notice the limits were fine, so you didn't waste time on a resources fix?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`disallow-latest-tag` is a Kyverno validate `ClusterPolicy` (`Enforce`, autogen off) that refuses any container image matching `*:latest`. `call-recorder` is pinned to `nginx:latest`, so every Pod its ReplicaSet creates is rejected at admission. It declares `limits`, so `require-resource-limits` passes — the only violation is the mutable tag. The denial names `disallow-latest-tag`, which is how you tell this apart from breakfix-01 at a glance. (This is the practical, always-available rung of image admission; the strongest rung is cosign signature verification via `verifyImages`<sup><a href="https://kyverno.io/docs/policy-types/cluster-policy/verify-images/">[5]</a></sup>.)

**Diagnostic commands (run in this order):**

```bash
# 1. Same 0/N-no-Pods shape; read which policy the denial names
kubectl get deploy,rs,pods -n tenant-apps -l app=call-recorder
kubectl describe rs -n tenant-apps -l app=call-recorder | sed -n '/Events/,$p'
#    ... admission webhook ... denied the request: ... disallow-latest-tag ... :latest ...

# 2. Read the offending image against the rule
kubectl get deploy call-recorder -n tenant-apps \
  -o jsonpath='{.spec.template.spec.containers[0].image}' ; echo        # nginx:latest
kubectl get clusterpolicy disallow-latest-tag -o yaml | grep -A6 'validate:'   # image: "!*:latest"
```

**Exact fix:**

Pin the image to an explicit, non-`latest` tag:

```bash
kubectl set image deployment/call-recorder app=nginx:1.25 -n tenant-apps
```

**Verify:**

```bash
kubectl rollout status deployment/call-recorder -n tenant-apps --timeout=60s
kubectl get pods -n tenant-apps -l app=call-recorder               # 1/1 Running on nginx:1.25
```

**Production thinking:**

`:latest` ships when a manifest is copied or a quick fix skips pinning, and it's a real supply-chain risk — the image under a running Pod can change with no manifest change. Pinning a tag is the floor; a digest (`@sha256:…`) is stronger, and `verifyImages` with cosign is strongest — it proves the image was signed by a key you trust, not merely that it came from somewhere. Enforce image policy at admission because it's the one place you can refuse an image *before* it's pulled onto a node.

</details>

---

# `m21-admission-control/` — M21 — Admission Control: Validating & Mutating Webhooks

**Category:** Admission webhooks

Concept reading: `m21-admission-control/LESSON.md`

## Break/fix 01 — A fail-closed webhook wedges deploys

**Symptom — what you'd actually see:**

`billing-api` in `tenant-apps` is `0/1` with **no Pods at all** — not `Pending`, not `ImagePullBackOff`, nothing to `logs` or `describe` at the Pod level. The Deployment and ReplicaSet exist; the Pod count is zero.

**Think about this before you open the answer:**

Distinguishing a failed webhook call from a policy denial, and recognizing fail-closed behavior. Self-grading questions:

- Did you read the event as **`failed calling webhook`** (infrastructure) rather than assuming a policy `denied the request`?
- Did you check the backend's **Pods and endpoints** and connect "no endpoints + `failurePolicy: Fail`" to "every call fails closed"?
- Did you fix the **backend**, understanding the webhook configuration was correct — not delete the webhook or edit the workload?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

the `admission-guard` backend is scaled to zero, so its Service has no endpoints. The webhooks' `failurePolicy` is `Fail`<sup><a href="https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/">[1]</a></sup>, so when the API server tries to call the (mutating, first-in-line) webhook for each Pod the ReplicaSet creates, the call can't complete and the request is **failed closed** — rejected. The event reads `failed calling webhook … no endpoints available for service "admission-guard"`, which is an *infrastructure* failure (the server was never reached), not a policy denial. The blast radius held to `tenant-apps` because the webhook is scoped there.

**Diagnostic commands (run in this order):**

```bash
# 1. No Pods, and the reason is on the ReplicaSet, not a Pod
kubectl get deploy,rs,pods -n tenant-apps -l app=billing-api        # deploy 0/1, rs CURRENT 0, no pods
kubectl describe rs -n tenant-apps -l app=billing-api | sed -n '/Events/,$p'
#    Error creating: Internal error occurred: failed calling webhook
#    "mutate.admission-guard.polyphone.example": ... no endpoints available for service "admission-guard"

# 2. Read it as a FAILED CALL, not a denial — then find the down backend
kubectl get pods,endpoints -n admission                            # no admission-guard pods, no endpoints
kubectl get mutatingwebhookconfiguration admission-guard \
  -o jsonpath='{.webhooks[0].failurePolicy}{"\n"}'                  # Fail  → fails closed
```

**Exact fix:**

Restore the backend so the call can complete (the configuration was never wrong):

```bash
kubectl scale deployment/admission-guard -n admission --replicas=1
kubectl rollout status deployment/admission-guard -n admission --timeout=120s
kubectl rollout restart deployment/billing-api -n tenant-apps      # re-admit now that the webhook answers
```

**Verify:**

```bash
kubectl get pods,endpoints -n admission                            # 1 Pod Ready, endpoint present
kubectl rollout status deployment/billing-api -n tenant-apps --timeout=90s
kubectl get pods -n tenant-apps -l app=billing-api -L env          # 1/1 Running, env=tenant injected
```

**Production thinking:**

This is the failure that makes `failurePolicy` a real decision. `Fail` is correct for a control you must not bypass, but a down backend then blocks every write in scope — so scope tightly (this webhook only hit `tenant-apps`) and always exclude `kube-system` so the control plane can heal itself. A webhook matching Pods cluster-wide with `Fail` and no exclusion, whose backend dies, can't create Pods anywhere — including its own backend. Run the backend with a PDB and multiple replicas, and alert on its readiness the way you would any critical-path dependency, because at admission it *is* one.

</details>

---

## Break/fix 02 — A mutating webhook that never fires

**Symptom — what you'd actually see:**

`orders-api` in `tenant-apps` is `0/1` with no Pods. The ReplicaSet's event is a genuine denial: `admission webhook "validate.admission-guard.polyphone.example" denied the request: admission-guard: object is missing required label 'env'`. But the workload's template sets no `env` label — and in the baseline that was fine.

**Think about this before you open the answer:**

Understanding the mutate-then-validate ordering and that a validating denial can be caused by an upstream mutation gap. Self-grading questions:

- Did you separate the **symptom** (a validating denial) from the **fault** (the mutating webhook not firing), and read *both* configurations?
- Did you spot that the mutating webhook matched **`UPDATE`, not `CREATE`**, so it never ran on a freshly created Pod?
- Did you fix the **mutating config's `operations`** — not add the label to the workload, and not weaken the validating rule — then re-admit to apply the mutation?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

the **mutating** webhook is supposed to inject `env=tenant` before validation runs<sup><a href="https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/">[1]</a></sup>. Its `rules[0].operations` was changed to `["UPDATE"]`, but a Pod is **created** by its ReplicaSet, so the mutating webhook never fires — the label is never injected. The **validating** webhook, which does match `CREATE` and requires `env`, then rejects the Pod. The denial names validation; the fault is the mutating webhook's `operations`. The backend is healthy (this is not break/fix 01).

**Diagnostic commands (run in this order):**

```bash
# 1. A real denial (webhook reached), for a label the author never sets
kubectl describe rs -n tenant-apps -l app=orders-api | sed -n '/Events/,$p'
#    admission webhook "validate.admission-guard..." denied the request: ... missing required label 'env'
kubectl get deploy orders-api -n tenant-apps \
  -o jsonpath='{.spec.template.metadata.labels}' ; echo                # no env — expected from mutation

# 2. Compare what each webhook matches — the mutating one doesn't match CREATE
kubectl get mutatingwebhookconfiguration  admission-guard -o jsonpath='{.webhooks[0].rules[0].operations}{"\n"}'  # [UPDATE]
kubectl get validatingwebhookconfiguration admission-guard -o jsonpath='{.webhooks[0].rules[0].operations}{"\n"}'  # [CREATE]
```

**Exact fix:**

Restore `CREATE` on the mutating webhook, then re-admit (mutation runs only on the next admission):

```bash
kubectl patch mutatingwebhookconfiguration admission-guard --type=json \
  -p '[{"op":"replace","path":"/webhooks/0/rules/0/operations","value":["CREATE"]}]'
kubectl rollout restart deployment/orders-api -n tenant-apps
```

**Verify:**

```bash
kubectl rollout status deployment/orders-api -n tenant-apps --timeout=90s
kubectl get pods -n tenant-apps -l app=orders-api -L env               # 1/1 Running, env=tenant injected
```

**Production thinking:**

A mutating webhook that doesn't match is silent — no error, no event, it simply doesn't fire, and the failure surfaces downstream as a validating denial for a "missing" default. A `CREATE`/`UPDATE` slip or a narrowed selector in a refactor is the classic "the default that stopped being applied." Alert on the *outcome* (tenant Pods lacking the injected label) rather than trusting the webhook to exist, and remember the admission rewrite never reaches already-running Pods — a policy fix takes effect on the next admission, so re-admit deliberately.

</details>

---

## Break/fix 03 — A webhook whose scope is too broad

**Symptom — what you'd actually see:**

`sip-canary` in the **`signaling`** namespace is `0/1` with no Pods. The ReplicaSet event is `admission webhook "validate.admission-guard.polyphone.example" denied the request: … object is missing required label 'env'` — the same message as break/fix 02, but landing in `signaling`, a namespace `admission-guard` was never meant to govern.

**Think about this before you open the answer:**

Reading a webhook's scope and recognizing over-reach. Self-grading questions:

- Did you notice the denial landed in a namespace `admission-guard` **shouldn't govern**, rather than assuming a workload problem in `signaling`?
- Did you read the **`namespaceSelector`** and see `{}` matches every namespace — and that the mutating webhook was correctly scoped, which is why `signaling` got no `env`?
- Did you **narrow the scope** back to `admission-guard=enabled` (scoping, not weakening) — not add `env` to `sip-canary` or disable the webhook?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

the **validating** webhook's `namespaceSelector` was widened to `{}`, which matches *every* namespace<sup><a href="https://kubernetes.io/docs/reference/kubernetes-api/extend-resources/validating-webhook-configuration-v1/">[5]</a></sup>, so it now intercepts Pod creates cluster-wide. The **mutating** webhook is still correctly scoped to `admission-guard=enabled` (tenant-apps only), so it never injects `env` in `signaling` — and the over-broad validating webhook rejects the un-injected Pod. `tenant-web` in `tenant-apps` stays healthy because mutation still injects `env` there. The tell is not the message; it's the *namespace* it lands in.

**Diagnostic commands (run in this order):**

```bash
# 1. A denial in a namespace this webhook shouldn't touch
kubectl get deploy,rs,pods -n signaling -l app=sip-canary
kubectl describe rs -n signaling -l app=sip-canary | sed -n '/Events/,$p'
#    admission webhook "validate.admission-guard..." denied the request: ... missing required label 'env'

# 2. Read the scope — the validating selector matches everything
kubectl get validatingwebhookconfiguration admission-guard -o jsonpath='{.webhooks[0].namespaceSelector}{"\n"}'  # {}
kubectl get mutatingwebhookconfiguration  admission-guard -o jsonpath='{.webhooks[0].namespaceSelector}{"\n"}'  # admission-guard=enabled
```

**Exact fix:**

Narrow the validating webhook's `namespaceSelector` back to the label that means "governed":

```bash
kubectl patch validatingwebhookconfiguration admission-guard --type=json \
  -p '[{"op":"replace","path":"/webhooks/0/namespaceSelector","value":{"matchLabels":{"admission-guard":"enabled"}}}]'
kubectl rollout restart deployment/sip-canary -n signaling
```

**Verify:**

```bash
kubectl get validatingwebhookconfiguration admission-guard \
  -o jsonpath='{.webhooks[0].namespaceSelector}{"\n"}'                 # matchLabels admission-guard=enabled
kubectl rollout status deployment/sip-canary -n signaling --timeout=90s
kubectl get pods -n signaling -l app=sip-canary                       # 1/1 Running (no longer intercepted)
```

**Production thinking:**

A webhook intercepts exactly what its `rules` and selectors say; an empty `namespaceSelector: {}` reaches `kube-system` too. Prefer a *positive* selector (govern namespaces that carry a label) so a mistake shrinks the blast radius instead of growing it, and always exclude the control-plane namespaces. When two denials read alike, the namespace they land in — governed vs collateral — and the configuration at fault are what separate a scope bug from a logic bug. This is the failure mode that, combined with `failurePolicy: Fail`, is the canonical "a webhook took down the cluster" incident.

</details>

---

# `m22-host-networking/` — M22 — Host Networking & Multi-NIC

**Category:** Host networking / multi-NIC

Concept reading: `m22-host-networking/LESSON.md`

## Break/fix 01 — hostNetwork Pod lost cluster DNS

**Symptom — what you'd actually see:**

`rtp-relay` in `media` (a hostNetwork Pod) can't resolve in-cluster Service names — calls to `session-broker.media` and friends fail. The Pod is `Running`; nothing crashed. Every other Pod on the cluster resolves those names fine.

**Think about this before you open the answer:**

Knowing that `hostNetwork` changes a Pod's DNS, and reading the resolver instead of blaming CoreDNS. Self-grading questions:

- Did you `cat /etc/resolv.conf` *inside the Pod* and notice it was the node's resolver, rather than assuming CoreDNS was down?
- Did you connect the failure to the `hostNetwork` + `dnsPolicy` pair on the spec?
- Did you fix it with `ClusterFirstWithHostNet` — keeping the Pod on the host network — rather than removing `hostNetwork` (which would defeat the point of the relay)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The relay's `dnsPolicy` is `ClusterFirst` (the default). `ClusterFirst` is **silently ignored** on a `hostNetwork` Pod: the kubelet hands it the node's `/etc/resolv.conf`, which has no `svc.cluster.local` search domains and points at the node's upstream resolver, not CoreDNS<sup><a href="https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pod-s-dns-policy">[1]</a></sup>. So the Pod is on the host network *and* using the host's DNS. The fix is to keep it on the host network but ask for cluster DNS explicitly: `dnsPolicy: ClusterFirstWithHostNet`.

**Diagnostic commands (run in this order):**

```bash
# 1. The Pod is Running — not a crash
kubectl get pod -n media -l app=rtp-relay -o wide

# 2. Read the resolver it actually got — the node's, not the cluster's
kubectl exec deploy/rtp-relay -n media -- cat /etc/resolv.conf
#    nameserver <node upstream>   (no search ...svc.cluster.local)

# 3. Prove it can't resolve a cluster name
kubectl exec deploy/rtp-relay -n media -- getent hosts session-broker.media.svc.cluster.local; echo "exit=$?"
#    (no output) exit=2

# 4. Compare with a normal Pod — this one uses cluster DNS
kubectl exec deploy/session-broker -n media -- cat /etc/resolv.conf
#    nameserver <kube-dns ClusterIP> + search media.svc.cluster.local ...

# 5. The field that caused it
kubectl get pod -n media -l app=rtp-relay \
  -o jsonpath='{range .items[*]}hostNetwork={.spec.hostNetwork}  dnsPolicy={.spec.dnsPolicy}{"\n"}{end}'
#    hostNetwork=true  dnsPolicy=ClusterFirst
```

**Exact fix:**

Set the DNS policy that keeps cluster DNS on the host network:

```bash
kubectl patch deployment rtp-relay -n media --type=merge \
  -p '{"spec":{"template":{"spec":{"dnsPolicy":"ClusterFirstWithHostNet"}}}}'
# or: kubectl edit deployment rtp-relay -n media  → dnsPolicy: ClusterFirstWithHostNet
```

**Verify:**

```bash
kubectl get deploy rtp-relay -n media -o jsonpath='dnsPolicy={.spec.template.spec.dnsPolicy}{"\n"}'
kubectl exec deploy/rtp-relay -n media -- getent hosts session-broker.media.svc.cluster.local; echo "exit=$?"
#    resolves, exit=0 — and the Pod is still on hostNetwork
```

**Production thinking:**

Make `dnsPolicy: ClusterFirstWithHostNet` a standing rule for every `hostNetwork` workload that talks to cluster Services — bake it into the template so it can't be forgotten. The bug is invisible until the Pod resolves an in-cluster name, so it ships clean and pages later. If DNS is failing for *all* Pods, not just the hostNetwork ones, that's a different incident: check CoreDNS in `kube-system` and the `kube-dns` endpoints before touching a workload.

</details>

---

## Break/fix 02 — multi-NIC Pod stuck ContainerCreating

**Symptom — what you'd actually see:**

`media-probe` in `edge` never starts — it's stuck in `ContainerCreating` and never goes `Ready`. The container image and resources are fine; the Pod's sandbox can't be built.

**Think about this before you open the answer:**

Reading a `ContainerCreating` hang as a network-attachment problem, and knowing NADs are namespaced. Self-grading questions:

- Did you go to `describe pod` events (not logs — the container never ran) and read the `FailedCreatePodSandBox` line?
- Did you check `get network-attachment-definitions -A` and notice the NAD was in a different namespace, rather than assuming it was missing entirely?
- Did you fix it with a `<namespace>/<name>` reference (or a local NAD copy), not by editing the image or resources?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`media-probe` requests the extra network by **bare** name (`k8s.v1.cni.cncf.io/networks: rtp-macvlan`), but the `rtp-macvlan` NetworkAttachmentDefinition exists only in `media`, not in `edge`. NADs are namespaced, and a bare network name is resolved against the **Pod's own** namespace (the same namespace-scoping rule as M04's cross-namespace DNS). Multus looks for `rtp-macvlan` in `edge`, can't find it, and sandbox setup fails — so the Pod hangs at `ContainerCreating` (it can't reach `Running` with an incomplete network namespace). The fix is the cross-namespace reference `media/rtp-macvlan` (or a copy of the NAD in `edge`).

**Diagnostic commands (run in this order):**

```bash
# 1. The signature: ContainerCreating, not a runtime error
kubectl get pods -n edge -l app=media-probe -o wide     # STATUS ContainerCreating

# 2. The event names what Multus couldn't find
kubectl describe pod -n edge -l app=media-probe | tail -20
#    FailedCreatePodSandBox ... NetworkAttachmentDefinition ... 'rtp-macvlan' not found (namespace edge)

# 3. What the Pod asked for — a bare name
kubectl get pod -n edge -l app=media-probe \
  -o jsonpath='{.items[0].metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks}{"\n"}'
#    rtp-macvlan

# 4. Where the NAD actually lives
kubectl get network-attachment-definitions -A
#    NAMESPACE media  NAME rtp-macvlan   (not in edge)
```

The mismatch — the Pod is in `edge`, the NAD is in `media`, the reference is bare — is the whole bug.

**Exact fix:**

Qualify the network reference with the NAD's namespace:

```bash
kubectl patch deployment media-probe -n edge --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"media/rtp-macvlan"}}}}}'
# or: give edge its own copy of the NAD:
#   kubectl get nad rtp-macvlan -n media -o yaml | sed 's/namespace: media/namespace: edge/' | kubectl apply -f -
```

**Verify:**

```bash
kubectl get pods -n edge -l app=media-probe -o wide            # now Running
kubectl exec deploy/media-probe -n edge -- ls /sys/class/net   # eth0 lo net1
```

**Production thinking:**

This is M04's cross-namespace DNS trap one layer down: a bare name is namespace-scoped, whether it's a Service or a NAD. Standardize on either shared NADs referenced as `<namespace>/<name>`, or a NAD per namespace that needs the network — and keep them templated (Kustomize/Helm, M16–M17) so a Pod and its NAD can't drift into different namespaces. File the signature away: a `ContainerCreating` Pod with a `FailedCreatePodSandBox` event is almost always CNI/attachment, not the image.

</details>

---

## Break/fix 03 — NodePort blackholes on one node

**Symptom — what you'd actually see:**

External health checks against `rtp-ingress` (NodePort `30080`) flap — some succeed, some time out, with no pattern in the app. The Pod is `Running` and `Ready`, `get svc` is normal, `get endpoints` is populated. Reachability depends on which node's IP the client hits.

**Think about this before you open the answer:**

Telling a NodePort-policy failure from a workload failure, and the `Local` vs `Cluster` trade. Self-grading questions:

- Did the populated EndpointSlice + healthy Pod steer you away from the M04 selector/endpoint reflexes and toward the NodePort layer?
- Did you reproduce the failure *per node IP*, not just once, to see the split?
- Did you read `connection timed out` (dropped) as different from `refused`, and connect it to `externalTrafficPolicy: Local` with no local endpoint?
- Did you weigh keeping `Local` (source IP) with per-node endpoints, rather than reflexively switching to `Cluster`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The Service is `externalTrafficPolicy: Local`, and its single backing Pod runs on one node. Under `Local`, kube-proxy programs each node to serve the NodePort **only if that node has a local endpoint**, and to silently **drop** the traffic otherwise — it never forwards across nodes, which is how it preserves the client's source IP<sup><a href="https://kubernetes.io/docs/tutorials/services/source-ip/">[2]</a></sup>. So the node running the Pod answers and every other node is a blackhole. The Service and EndpointSlice look healthy throughout. The fix is `externalTrafficPolicy: Cluster` (accept the SNAT), or keep `Local` and put an endpoint on every node.

**Diagnostic commands (run in this order):**

```bash
# 1. The Service and endpoints look fine — NOT the empty-EndpointSlice case (M04)
kubectl get svc rtp-ingress -n media                    # 80:30080/TCP
kubectl get endpoints rtp-ingress -n media              # populated
kubectl get pod -n media -l app=rtp-ingress -o wide     # Running, Ready, on ONE node

# 2. Reproduce the split — hit each node's IP
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  echo -n "$ip:30080 -> "; curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://$ip:30080 || echo TIMEOUT
done
#    one node -> 200, the other -> TIMEOUT (dropped, not refused)

# 3. Read the policy
kubectl get svc rtp-ingress -n media \
  -o jsonpath='type={.spec.type}  externalTrafficPolicy={.spec.externalTrafficPolicy}{"\n"}'
#    type=NodePort  externalTrafficPolicy=Local
```

The discriminator vs M04's black hole: there the EndpointSlice was empty; here it's populated and the Pod is healthy — the drop is at the NodePort policy, per node.

**Exact fix:**

Restore reachability by load-balancing cluster-wide:

```bash
kubectl patch svc rtp-ingress -n media --type=merge \
  -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
# or keep Local and guarantee a local endpoint on every node:
#   run the front-end as a DaemonSet, or topology-spread enough replicas
```

**Verify:**

```bash
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  echo -n "$ip:30080 -> "; curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://$ip:30080 || echo TIMEOUT
done
#    every node -> 200
```

**Production thinking:**

`Local` is the right choice when you need the real client IP (source routing, per-tenant rate-limiting, media keyed off the caller). Its requirement is an endpoint on every node that receives external traffic — so pair it with a DaemonSet or topology spread, and point the external LB's health check at the Service's `healthCheckNodePort` (which `Local` publishes precisely so an LB stops sending traffic to nodes with no local endpoint). Reach for `Cluster` when even load-balancing outweighs the source IP. What never works is `Local` plus a single-node backend and an expectation that every node answers — most visible during a rollout that briefly drains the one serving node.

</details>

---

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
