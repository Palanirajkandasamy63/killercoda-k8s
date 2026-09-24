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
