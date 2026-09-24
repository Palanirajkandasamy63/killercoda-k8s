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
