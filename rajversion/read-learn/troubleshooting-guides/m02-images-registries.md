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
