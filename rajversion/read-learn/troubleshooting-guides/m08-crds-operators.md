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
