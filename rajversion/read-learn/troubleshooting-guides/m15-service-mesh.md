# `m15-service-mesh/` — M15 — Service Mesh

**Category:** Service mesh (Istio-style)

Concept reading: `m15-service-mesh/LESSON.md`

## Break/fix 01 — Sidecar not injected

**Symptom — what you'd actually see:**

Callers of `session-broker` in `media` get `HTTP 503`. Its Pod is `Running`/`Ready`, `kubectl get endpoints session-broker -n media` lists the Pod IP on `:80`, and DNS resolves. Nothing logs an error; the app container is serving.

**Think about this before you open the answer:**

Reading `2/2` vs `1/1` as a mesh-membership check, and knowing a sidecar-less pod is entirely outside the mesh. Self-grading questions:

- Did you check the container count and `proxy-status` before assuming the app or the Service was broken?
- Did you connect "no sidecar" to "no mTLS terminator" as the reason for the `503`, rather than blaming the DestinationRule?
- Did you fix by **re-enrolling** the workload, leaving `STRICT` mTLS intact — not by weakening the server to accept plaintext?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `session-broker` Deployment's pod template carries `sidecar.istio.io/inject: "false"`, which overrides the namespace's `istio-injection=enabled` and admits the pod **without a sidecar** — it comes up `1/1` and is not in the mesh<sup><a href="https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/">[1]</a></sup>. Every caller's sidecar is told by the `session-broker` DestinationRule to originate `ISTIO_MUTUAL` mTLS. With no sidecar on `session-broker` to terminate that mTLS, the caller's Envoy can't complete the connection and returns `503`. The workload is healthy; only its mesh membership is missing.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce from the in-mesh client — a 503
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 503

# 2. Rule out the Service layer — endpoints present, DNS resolves
kubectl get endpoints session-broker -n media                     # PodIP:80
kubectl exec -n media deploy/mesh-client -c curl -- nslookup session-broker.media

# 3. Count containers — the tell
kubectl get pods -n media                                         # session-broker is 1/1, siblings 2/2
istioctl proxy-status | grep session-broker                       # absent — no sidecar registered with istiod
kubectl get pod -n media -l app=session-broker -o yaml | grep -A2 'annotations:'
#    sidecar.istio.io/inject: "false"
```

**Exact fix:**

Re-enroll the workload — set injection back on and let the Deployment roll a new, injected pod. Do **not** touch mTLS:

```bash
kubectl patch deployment session-broker -n media \
  -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}}}'
kubectl rollout status deployment session-broker -n media
# or: kubectl edit deployment session-broker -n media  → delete the inject: "false" annotation
```

**Verify:**

```bash
kubectl get pods -n media -l app=session-broker                   # now 2/2
istioctl proxy-status | grep session-broker                       # now listed, SYNCED
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 200
kubectl get peerauthentication default -n media -o jsonpath='{.spec.mtls.mode}{"\n"}'        # still STRICT
```

**Production thinking:**

This ships whenever a workload is templated with injection disabled, or deployed into a namespace before it was labeled. The loud `503` here is a lucky consequence of the explicit `ISTIO_MUTUAL` DestinationRule; under *automatic* mTLS the same missing sidecar would silently downgrade the hop to plaintext — an unencrypted security hole with no error. Alert on it structurally: a check that every pod in a meshed namespace is `2/2`, and mesh telemetry showing the workload is absent, catch it before a caller does.

</details>

---

## Break/fix 02 — VirtualService subset

**Symptom — what you'd actually see:**

`session-broker` returns `HTTP 503`, but every `media` pod is `2/2` and in the mesh (`istioctl proxy-status` lists `session-broker` as `SYNCED`), the Service has endpoints, and mTLS is healthy. The workload is fine.

**Think about this before you open the answer:**

Debugging a mesh `503` in the compiled Envoy config rather than in `kubectl get pods`, and knowing a subset can be valid but empty. Self-grading questions:

- Did the `2/2` pods steer you away from "the workload is down" and toward the route?
- Did you use `istioctl proxy-config routes` then `endpoints` to see the route landing on an empty cluster, instead of guessing?
- Did you connect the empty cluster to the VirtualService `subset` and the absence of `version: canary` pods?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `session-broker` VirtualService routes to `subset: canary`. The DestinationRule defines `canary` as `labels: { version: canary }` — a version nobody deployed — so istiod compiles it into an Envoy cluster (`outbound|80|canary|session-broker.media.svc.cluster.local`) with **zero endpoints**. The route matches, Envoy selects the canary cluster, finds no healthy upstream, and returns `503`<sup><a href="https://istio.io/latest/docs/concepts/traffic-management/">[2]</a></sup>. The `stable` subset has the running pods; the route just aims at the empty one.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — 503
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 503

# 2. Rule out the workload — all 2/2, endpoints present (NOT breakfix-01)
kubectl get pods -n media
kubectl get endpoints session-broker -n media                     # PodIP:80

# 3. Follow the route in Envoy — the caller's sidecar routes it
POD=$(kubectl get pod -n media -l app=mesh-client -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config routes "$POD" -n media --name 80 -o json | grep -i '"cluster"'
#    ...|canary|session-broker...   ← route targets the canary subset
istioctl proxy-config endpoints "$POD" -n media | grep session-broker
#    |stable| cluster has PodIPs:80 ; |canary| cluster is EMPTY

# 4. Confirm the source
kubectl get virtualservice session-broker -n media -o yaml | grep -A3 route:   # subset: canary
kubectl get pods -n media -l version=canary                       # none
```

**Exact fix:**

Point the route at a subset that has pods (`stable`); the canary build doesn't exist to deploy:

```bash
kubectl patch virtualservice session-broker -n media --type=json \
  -p '[{"op":"replace","path":"/spec/http/0/route/0/destination/subset","value":"stable"}]'
# or: kubectl edit virtualservice session-broker -n media  → subset: canary → stable
```

**Verify:**

```bash
POD=$(kubectl get pod -n media -l app=mesh-client -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config routes "$POD" -n media --name 80 -o json | grep -i '"cluster"'   # ...|stable|...
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 200
```

**Production thinking:**

This is the classic canary footgun: shift traffic to `version: canary` *before* the canary pods are `Ready`, and every routed request falls into an empty cluster. A VirtualService applying cleanly proves nothing about whether its subset has backends. Guard it by ordering the rollout (pods `Ready` before the traffic shift) and by testing routing with a real request in CI — and remember that a *partial* traffic split turns this into a *fractional* `503` that's easy to misread as flakiness.

</details>

---

## Break/fix 03 — mTLS mode mismatch

**Symptom — what you'd actually see:**

`session-broker` returns `HTTP 503`. Every pod is `2/2`, the VirtualService routes to `stable`, `istioctl proxy-config endpoints` shows that cluster with healthy endpoints — and it still fails. Neither of the previous two causes applies.

**Think about this before you open the answer:**

Recognizing mTLS as a two-sided contract and reading the server policy against the client policy. Self-grading questions:

- Did you rule out breakfix-01 (`2/2`) and breakfix-02 (endpoints present) before concluding "mTLS"?
- Did you read **both** the PeerAuthentication and the DestinationRule, rather than trusting either in isolation?
- Did you fix by raising the **client** to mTLS, keeping `STRICT`, instead of dropping the server to `PERMISSIVE` (which would silently make the hop plaintext)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

mTLS is configured on both sides and they **disagree**. The namespace `PeerAuthentication default` is `mtls.mode: STRICT` — `session-broker`'s sidecar accepts only mTLS. The `session-broker` DestinationRule sets `trafficPolicy.tls.mode: DISABLE` — callers' sidecars send **plaintext**. The caller sends plaintext into a server that rejects everything but mTLS; the server's sidecar resets the connection and the caller's Envoy returns `503`<sup><a href="https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/">[3]</a></sup>. Both ends are healthy and in the mesh; only the transport policies conflict.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — 503
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 503

# 2. Rule out 01 and 02 — sidecar present, route lands on endpoints
kubectl get pods -n media                                         # all 2/2 (not breakfix-01)
POD=$(kubectl get pod -n media -l app=mesh-client -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config endpoints "$POD" -n media | grep 'session-broker' | grep ':80'   # stable has endpoints (not breakfix-02)

# 3. Read both halves of mTLS
kubectl get peerauthentication default -n media -o yaml | grep -A2 mtls:            # mode: STRICT   (server)
kubectl get destinationrule session-broker -n media -o yaml | grep -A2 'tls:'       # mode: DISABLE  (client)
#    server requires mTLS, client sends plaintext → mismatch
```

**Exact fix:**

Align the client to the server. Raise the DestinationRule to `ISTIO_MUTUAL`; keep the server `STRICT`:

```bash
kubectl patch destinationrule session-broker -n media --type=json \
  -p '[{"op":"replace","path":"/spec/trafficPolicy/tls/mode","value":"ISTIO_MUTUAL"}]'
# or: kubectl edit destinationrule session-broker -n media  → mode: DISABLE → ISTIO_MUTUAL
# (removing the tls block entirely also works — automatic mTLS then negotiates it)
```

**Verify:**

```bash
kubectl exec -n media deploy/mesh-client -c curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 http://session-broker.media/   # 200
kubectl get peerauthentication default -n media -o jsonpath='{.spec.mtls.mode}{"\n"}'        # still STRICT
```

**Production thinking:**

With no DestinationRule `tls` block, automatic mTLS would have negotiated this correctly — so an explicit `DISABLE` against a `STRICT` server is a self-inflicted mismatch, usually a copy-pasted rule or a leftover from a plaintext migration. Roll `STRICT` out the safe way: set `PERMISSIVE` first, let workloads gain sidecars and traffic become mTLS, confirm with telemetry, then flip to `STRICT`. And treat "fix by dropping to `PERMISSIVE`" as a regression, not a fix — it re-opens the plaintext path the mesh existed to close.

</details>

---
