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
