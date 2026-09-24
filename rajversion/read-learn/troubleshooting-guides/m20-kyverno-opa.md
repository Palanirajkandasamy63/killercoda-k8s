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
