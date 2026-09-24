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
