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
