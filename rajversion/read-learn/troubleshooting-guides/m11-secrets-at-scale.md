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
