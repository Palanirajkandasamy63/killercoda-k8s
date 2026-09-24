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
