# `m04-networking-services-dns/` — M04 — Networking I: Services & DNS

**Category:** Services & DNS (networking)

Concept reading: `m04-networking-services-dns/LESSON.md`

## Break/fix 01 — DNS: cross-namespace short name

**Symptom — what you'd actually see:**

`account-provisioner` in `provisioning` is configured to call the session broker at `http://session-broker/`, and reports it can't reach the upstream. The Pod itself is `Running` — this is a name-resolution failure, not a crash.

**Think about this before you open the answer:**

Understanding the Service DNS scheme and that short names are namespace-scoped. Self-grading questions:

- Did you reproduce the failure from the *caller's* namespace, not a random one? (A `busybox` in `media` would have resolved the short name and hidden the bug.)
- Did you reach for `nslookup` / the name, rather than assuming the Service was down or the pull was broken?
- Did you qualify the name (`<svc>.<ns>` or FQDN) instead of moving the workload or duplicating the Service into `provisioning`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The endpoint uses the **bare** Service name `session-broker`, but the target Service lives in the `media` namespace while the caller is in `provisioning`. A short name resolves only within the caller's own namespace, because the Pod's DNS search domains are built from *its* namespace (`provisioning.svc.cluster.local`, …). So the lookup becomes `session-broker.provisioning.svc.cluster.local` → NXDOMAIN. The Service is fine; the name is unqualified<sup><a href="https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/">[4]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. The configured endpoint — the bare name is the clue
kubectl describe deploy account-provisioner -n provisioning
#    Environment: BROKER_ENDPOINT: http://session-broker/

# 2. Reproduce resolution from the CALLER's namespace — NXDOMAIN
kubectl run dns-test --rm -i --restart=Never --image=busybox:1.36 -n provisioning -- \
  nslookup session-broker
#    ** server can't find session-broker...: NXDOMAIN

# 3. Prove the Service exists — just in another namespace
kubectl get svc session-broker -n media          # it's there, with a ClusterIP

# 4. Resolve it qualified — works
kubectl run dns-test --rm -i --restart=Never --image=busybox:1.36 -n provisioning -- \
  nslookup session-broker.media.svc.cluster.local
#    → the session-broker ClusterIP
```

**busybox caveat, worth knowing:** `session-broker.media` is the form application config normally carries, and a glibc-based image resolves it — `ndots:5` means a 1-dot name gets the search domains appended first, which completes it to `session-broker.media.svc.cluster.local`. busybox does not do that: it queries any name containing a dot literally, so `nslookup session-broker.media` returns NXDOMAIN from a busybox probe even though the Service is reachable. Use the FQDN in throwaway busybox clients, or you'll misdiagnose a healthy name as broken.

**Exact fix:**

Qualify the name with the target namespace (or the full FQDN):

```bash
kubectl set env deployment/account-provisioner -n provisioning \
  BROKER_ENDPOINT=http://session-broker.media.svc.cluster.local/
# (session-broker.media also works for a glibc-based app image — the search list completes it)
```

**Verify:**

```bash
kubectl describe deploy account-provisioner -n provisioning     # Environment: the qualified name
kubectl run dns-test --rm -i --restart=Never --image=busybox:1.36 -n provisioning -- \
  wget -qO- -T3 http://session-broker.media.svc.cluster.local/ | head -4   # nginx HTML
```

**Production thinking:**

Cross-namespace calls should use `<svc>.<ns>` (or the FQDN) as a convention, set in config, so a namespace split never silently breaks resolution. The bare-name habit works right up until a caller and callee stop sharing a namespace — then it fails for a subset of traffic in a way that looks like an outage of the callee. If real DNS resolution is failing *everywhere* (not just cross-namespace), that's a different incident: check CoreDNS in `kube-system` and the `kube-dns` Service's endpoints before touching app config.

</details>

---

## Break/fix 02 — Selector mismatch: the empty EndpointSlice

**Symptom — what you'd actually see:**

Calls to `route-engine` in `call-routing` fail — the connection hangs or is refused. `route-engine`'s Pods are all `Running` and `Ready`, and `kubectl get svc route-engine` shows a normal ClusterIP. Nothing looks wrong at the top line.

**Think about this before you open the answer:**

The single most important Service-debugging reflex — checking `get endpointslice` before anything else. Self-grading questions:

- Was `kubectl get endpointslice`  one of your first three commands?
- Did you compare the Service's `selector` to the Pods' actual labels, rather than restarting or scaling the Pods (which were never unhealthy)?
- Did you recognize that `get svc` looking normal proves nothing about reachability?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `route-engine` Service's selector was changed to `app: route-enginev2`, but the Pods are labeled `app: route-engine`. The selector matches nothing, so the endpoints controller writes an **empty** EndpointSlice<sup><a href="https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/">[2]</a></sup>, and kube-proxy has no backend to send the ClusterIP's traffic to — it rejects the connection<sup><a href="https://kubernetes.io/docs/reference/networking/virtual-ips/">[3]</a></sup>. The Service exists and looks healthy; it just routes to nothing.

**Diagnostic commands (run in this order):**

```bash
# 1. The Service exists and looks fine
kubectl get svc route-engine -n call-routing            # ClusterIP, 80/TCP — normal

# 2. The diagnosis: NO endpoints behind it
kubectl get endpointslice -n call-routing \
  -l kubernetes.io/service-name=route-engine   # no endpoint addresses

# 3. Why empty? Compare the selector to the Pods' labels
kubectl describe svc route-engine -n call-routing
#    Selector:   app=route-enginev2
#    Endpoints:  <none>          ← the query and its answer, one screen
kubectl get pods -n call-routing --show-labels
#    app=route-engine   (and the Pods are Running + Ready)
```

The mismatch — selector `route-enginev2` vs label `route-engine` — is the whole bug. Endpoints are empty for one of two reasons; this is the selector one. (The other is "Pods matched but none are `Ready`" — there `get pods` would show them not-Ready.)

**Exact fix:**

Make the selector match the Pods (or, equivalently, fix whichever side drifted):

```bash
kubectl patch svc route-engine -n call-routing \
  -p '{"spec":{"selector":{"app":"route-engine"}}}'
# or: kubectl edit svc route-engine -n call-routing   → set selector.app: route-engine
```

**Verify:**

```bash
kubectl get endpointslice -n call-routing \
  -l kubernetes.io/service-name=route-engine   # now lists Pod addresses on :80
kubectl run net-test --rm -i --restart=Never --image=busybox:1.36 -n call-routing -- \
  wget -qO- --timeout=3 http://route-engine/             # nginx HTML
```

**Production thinking:**

This is the failure a label rename ships silently: someone updates the `app` label on a Deployment's Pod template and the Service's selector drifts out of sync, or vice-versa. No Pod is unhealthy, nothing logs an error, and the Service empties. Detect it by alerting on a Service with zero `Ready` endpoints (the `kube_endpoint_address_available`-style metric), not on Pod health — Pod health is green throughout. The durable fix is to keep selector and Pod labels in one templated source (Kustomize/Helm, M16–M17) so they can't drift independently.

</details>

---

## Break/fix 03 — Port mismatch: refused, with endpoints

**Symptom — what you'd actually see:**

Calls to `portal-ui` in `admin-portal` come back `connection refused` immediately. Unlike breakfix-02, the EndpointSlice for `portal-ui` is **populated** — the Pods are there, Ready, and in the EndpointSlice. The connection is reaching a Pod and getting rejected.

**Think about this before you open the answer:**

Telling a port failure from an endpoint failure, and the `port`/`targetPort`/`containerPort` distinction. Self-grading questions:

- Did the **populated** EndpointSlice stop you from chasing the selector (the breakfix-02 reflex), and point you at the port instead?
- Did you compare `targetPort` to what the process actually binds — not to `containerPort`, which is just documentation?
- Did you read `connection refused` (reached a Pod, rejected) as different from the black hole's hang/reject-with-no-endpoints?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `portal-ui` Service forwards `port: 80` to `targetPort: 8080`, but the container (nginx) listens on **80**, not 8080. Nothing is bound to 8080, so the Pod's kernel answers the forwarded connection with a RST → `connection refused`. The selector and endpoints are correct; the *port* the traffic is delivered to is wrong. `containerPort` declaring 8080 changes nothing — it never opened a listener<sup><a href="https://kubernetes.io/docs/concepts/services-networking/service/#defining-a-service">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Endpoints ARE present — this is NOT the black-hole case
kubectl get endpointslice -n admin-portal \
  -l kubernetes.io/service-name=portal-ui   # lists Pod addresses on :8080

# 2. The connection is refused, not hung — something is rejecting it
kubectl run net-test --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -qO- --timeout=3 http://portal-ui/
#    wget: can't connect ... Connection refused

# 3. Read the Service's targetPort and compare to the real listener
kubectl describe svc portal-ui -n admin-portal
#    Port: 80/TCP   TargetPort: 8080/TCP   Endpoints: <PodIP>:8080
# nginx serves on 80 — prove it directly against the Pod:
kubectl run net-test --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  sh -c 'wget -qO- --timeout=3 http://<a-portal-ui-pod-ip>:80 && echo OK-on-80'
```

The endpoints listing showing `:8080` while nginx serves `:80` is the discriminator: a populated EndpointSlice plus a refused connection equals a `targetPort` problem, never a selector one.

**Exact fix:**

Point `targetPort` at the port the process actually listens on:

```bash
kubectl patch svc portal-ui -n admin-portal \
  -p '{"spec":{"ports":[{"port":80,"targetPort":80}]}}'
# or: kubectl edit svc portal-ui -n admin-portal   → targetPort: 80
```

**Verify:**

```bash
kubectl get endpointslice -n admin-portal \
  -l kubernetes.io/service-name=portal-ui   # now shows the address on :80
kubectl run net-test --rm -i --restart=Never --image=busybox:1.36 -n admin-portal -- \
  wget -qO- --timeout=3 http://portal-ui/                # nginx HTML
```

**Production thinking:**

Port mismatches usually ship from a Service and a container image that were edited by different people or at different times — the app moved its listener, or a copy-pasted Service kept a `targetPort` from another workload. Named ports (`targetPort: http`, with the container declaring a `ports: [{name: http, containerPort: 80}]`) make this class of bug far rarer, because the Service references the port *by name* and the number lives in one place. Readiness probes help too: a probe against the real port fails the Pod out of the EndpointSlice, converting a silent refused-with-endpoints into a visible not-Ready Pod.

</details>

---
