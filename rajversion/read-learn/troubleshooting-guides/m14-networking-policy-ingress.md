# `m14-networking-policy-ingress/` — M14 — Networking II: Policy & Ingress

**Category:** NetworkPolicy & Ingress

Concept reading: `m14-networking-policy-ingress/LESSON.md`

## Break/fix 01 — NetworkPolicy default-deny

**Symptom — what you'd actually see:**

`session-broker` in `media` is unreachable — callers hang and time out. Its Pods are `Running` and `Ready`, `kubectl get endpoints session-broker -n media` lists the Pod IPs, and DNS for `session-broker.media` resolves. Nothing is refused, nothing is `NXDOMAIN`, nothing logs an error.

**Think about this before you open the answer:**

Recognizing the silent-timeout signature and the default-deny model. Self-grading questions:

- Did you read the **hang** (vs `NXDOMAIN` / `connection refused`) as a policy drop, rather than restarting the healthy Pods?
- Did you rule out endpoints and DNS *before* concluding "policy," so it was a diagnosis and not a guess?
- Did you **add an allow** rather than delete the deny — keeping the namespace isolated?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

A `default-deny-ingress` policy (empty `podSelector`, `policyTypes: [Ingress]`, no rules) selects every pod in `media` and denies all ingress. It is the *only* policy present — the companion allow that the baseline had is missing. Selecting a pod flips it to default-deny, and with no allow, every caller (including ones in `media` itself) is dropped<sup><a href="https://kubernetes.io/docs/concepts/services-networking/network-policies/">[1]</a></sup>. Ingress-only policies don't touch egress, so DNS still works — which is why the path looks healthy right up to the silent drop.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — a hang, not a refusal or NXDOMAIN
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  wget -qO- --timeout=5 http://session-broker.media/     # times out

# 2. Rule out the M04 layers: endpoints present, DNS resolves
kubectl get endpoints session-broker -n media            # lists PodIPs:80
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  nslookup session-broker.media                          # resolves

# 3. A silent drop with a healthy path == NetworkPolicy
kubectl get networkpolicy -n media                       # only default-deny-ingress
kubectl describe networkpolicy default-deny-ingress -n media
#    PodSelector: <none>   policyTypes: Ingress   (no allow rules) → deny all ingress
```

**Exact fix:**

Add an allow that selects `session-broker` and permits its callers — do **not** delete the deny (the lockdown is intended):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-session-broker-internal, namespace: media }
spec:
  podSelector: { matchLabels: { app: session-broker } }
  policyTypes: [Ingress]
  ingress:
    - from: [ { podSelector: {} } ]          # any pod in this namespace
      ports: [ { protocol: TCP, port: 80 } ]
EOF
```

**Verify:**

```bash
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n media -- \
  wget -qO- --timeout=5 http://session-broker.media/     # nginx HTML
# and the isolation you kept is intact — a caller from outside still can't:
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n signaling -- \
  wget -qO- --timeout=5 http://session-broker.media/     # still times out
```

**Production thinking:**

This ships the moment someone applies a hardening `default-deny` and forgets the allows, or deletes an allow during a refactor. No Pod is unhealthy and nothing logs an error, so alert on it at the connectivity layer — synthetic probes between the pairs that are *supposed* to talk, not Pod health. And prefer ingress-only lockdowns first: an egress `default-deny` additionally breaks the namespace's DNS, turning one outage into two.

</details>

---

## Break/fix 02 — NetworkPolicy cross-namespace

**Symptom — what you'd actually see:**

`sip-app` in `app-services` can't reach `session-broker` in `media` — the call times out, the same hang as breakfix-01. But an allow policy *exists* (`allow-broker-from-app`) and it names `sip-app`. On paper the traffic is permitted.

**Think about this before you open the answer:**

Peer-selector semantics — `podSelector` vs `namespaceSelector`, and the AND-in-one-element rule. Self-grading questions:

- Did you reproduce from the **caller's** namespace and label, not a random client? (A test from the wrong place would mislead.)
- Did you spot that the `from` peer had no `namespaceSelector`, and know that makes it namespace-local?
- Did you put both selectors in **one** `from` element (AND), understanding that splitting them into two elements would be a looser OR?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The allow's `from` peer is a bare `podSelector: { app: sip-app }` with **no `namespaceSelector`**. A `podSelector` on its own is evaluated in the policy's *own* namespace — here `media` — so it means "pods labeled `app=sip-app` in `media`," of which there are none. The allow matches an empty set; the `default-deny-ingress` denies everything else; the cross-namespace caller is dropped<sup><a href="https://kubernetes.io/docs/concepts/services-networking/network-policies/">[1]</a></sup>. The policy looks correct and allows nothing.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce AS the caller — sip-app's namespace and label
kubectl run sip-app --rm -i --restart=Never --labels app=sip-app \
  --image=busybox:1.36 -n app-services -- \
  wget -qO- --timeout=5 http://session-broker.media/     # times out

# 2. An allow exists — read its peer
kubectl get networkpolicy allow-broker-from-app -n media -o yaml | grep -A8 ingress:
#    from:
#      - podSelector: { matchLabels: { app: sip-app } }   # no namespaceSelector!

# 3. Prove the peer matches nothing: no sip-app pod in the policy's namespace
kubectl get pods -n media -l app=sip-app                 # none
kubectl get pods -n app-services -l app=sip-app          # the real one is here
```

**Exact fix:**

Add a `namespaceSelector` so the peer reaches into `app-services`. Combine it with the `podSelector` in **one** `from` element (an AND — "`sip-app` pods in `app-services`"):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-broker-from-app, namespace: media }
spec:
  podSelector: { matchLabels: { app: session-broker } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: app-services } }
          podSelector:       { matchLabels: { app: sip-app } }
      ports: [ { protocol: TCP, port: 80 } ]
EOF
```

**Verify:**

```bash
kubectl run sip-app --rm -i --restart=Never --labels app=sip-app \
  --image=busybox:1.36 -n app-services -- \
  wget -qO- --timeout=5 http://session-broker.media/     # nginx HTML
# precision check — an app-services client WITHOUT the label is still denied:
kubectl run other --rm -i --restart=Never --image=busybox:1.36 -n app-services -- \
  wget -qO- --timeout=5 http://session-broker.media/     # still times out
```

**Production thinking:**

This is the most common NetworkPolicy authoring bug, and it fails *open-looking but closed* — the policy is present, so a reviewer skims past it. Two guards: templatize cross-namespace allows (Kustomize/Helm, M16–M17) so the `namespaceSelector` can't be dropped by hand, and test policies with a real cross-namespace probe in CI, since the object applying cleanly proves nothing about whether it allows the intended traffic. Mind the AND/OR shape too — one misplaced list dash turns a scoped allow into a namespace-wide one, which is a silent widening of a security boundary.

</details>

---

## Break/fix 03 — Ingress misrouting

**Symptom — what you'd actually see:**

`portal.polyphone.example` returns `503 Service Temporarily Unavailable` from outside. But `portal-ui` in `admin-portal` is healthy: Pods `Running`/`Ready`, a ClusterIP, and `kubectl get endpoints portal-ui` lists the Pod IPs on `:80`. Reached directly by its Service, `portal-ui` answers fine.

**Think about this before you open the answer:**

Telling an Ingress backend failure (`503`) from a routing miss (`404`), and reading the rule's `backend.service.port` against the Service. Self-grading questions:

- Did the **`503`** (vs `404`) tell you the rule matched and the *backend* was the problem, so you inspected the Service/port rather than the host/path?
- Did you prove `portal-ui` was healthy directly before touching the Ingress, so you knew the break was in the rule?
- Did you compare `backend.service.port` to the Service's actual `ports`, rather than assuming the Service or its endpoints were down?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `portal` Ingress rule forwards to `portal-ui` on port **8080**, but the Service exposes only **80**. The controller claims the Ingress (class `nginx`)<sup><a href="https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/">[3]</a></sup> and matches the host — so routing works — but it resolves the backend `portal-ui:8080` to *zero* endpoints and has nothing to forward to, returning `503`<sup><a href="https://kubernetes.io/docs/concepts/services-networking/ingress/">[2]</a></sup>. The Service, Pods, and endpoints are all healthy on 80; only the port the rule names is wrong. (A `404` would be the other failure — no rule matched the host/path at all.)

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce through the controller — a 503 (rule matched, backend didn't resolve)
CIP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.clusterIP}')
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -O- --timeout=5 --header "Host: portal.polyphone.example" "http://$CIP/"
#    wget: server returned error: HTTP/1.1 503 Service Temporarily Unavailable

# 2. Prove the backend is healthy — this is NOT a Service/endpoints outage
kubectl get endpoints portal-ui -n admin-portal          # PodIPs:80
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -qO- --timeout=5 http://portal-ui.admin-portal/   # nginx HTML

# 3. Read the rule against the Service — the port doesn't line up
kubectl describe ingress portal -n admin-portal          # backend portal-ui:8080
kubectl get svc portal-ui -n admin-portal                # PORT(S): 80/TCP only
```

**Exact fix:**

Point the backend port at 80 (what the Service exposes):

```bash
kubectl patch ingress portal -n admin-portal --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":80}]'
# or: kubectl edit ingress portal -n admin-portal   → backend.service.port.number: 80
```

**Verify:**

```bash
CIP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.clusterIP}')
kubectl run client --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -qO- --timeout=5 --header "Host: portal.polyphone.example" "http://$CIP/"   # nginx HTML
```

**Production thinking:**

Port mismatches ship when an Ingress and a Service are edited by different people or at different times — the app moved its listener, or a copied Ingress kept another workload's port. Named ports remove the class of bug: have the Service declare `ports: [{ name: http, port: 80 }]` and the Ingress reference `port: { name: http }`, so the number lives in one place. And distinguish a **steady** `503` (config: wrong port/service) from a **transient** `503` right after a deploy (the backend's endpoints briefly empty during a rollout) — the second self-heals via readiness (M04, M09) and is not an Ingress bug.

</details>

---
