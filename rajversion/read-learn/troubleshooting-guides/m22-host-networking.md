# `m22-host-networking/` — M22 — Host Networking & Multi-NIC

**Category:** Host networking / multi-NIC

Concept reading: `m22-host-networking/LESSON.md`

## Break/fix 01 — hostNetwork Pod lost cluster DNS

**Symptom — what you'd actually see:**

`rtp-relay` in `media` (a hostNetwork Pod) can't resolve in-cluster Service names — calls to `session-broker.media` and friends fail. The Pod is `Running`; nothing crashed. Every other Pod on the cluster resolves those names fine.

**Think about this before you open the answer:**

Knowing that `hostNetwork` changes a Pod's DNS, and reading the resolver instead of blaming CoreDNS. Self-grading questions:

- Did you `cat /etc/resolv.conf` *inside the Pod* and notice it was the node's resolver, rather than assuming CoreDNS was down?
- Did you connect the failure to the `hostNetwork` + `dnsPolicy` pair on the spec?
- Did you fix it with `ClusterFirstWithHostNet` — keeping the Pod on the host network — rather than removing `hostNetwork` (which would defeat the point of the relay)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The relay's `dnsPolicy` is `ClusterFirst` (the default). `ClusterFirst` is **silently ignored** on a `hostNetwork` Pod: the kubelet hands it the node's `/etc/resolv.conf`, which has no `svc.cluster.local` search domains and points at the node's upstream resolver, not CoreDNS<sup><a href="https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pod-s-dns-policy">[1]</a></sup>. So the Pod is on the host network *and* using the host's DNS. The fix is to keep it on the host network but ask for cluster DNS explicitly: `dnsPolicy: ClusterFirstWithHostNet`.

**Diagnostic commands (run in this order):**

```bash
# 1. The Pod is Running — not a crash
kubectl get pod -n media -l app=rtp-relay -o wide

# 2. Read the resolver it actually got — the node's, not the cluster's
kubectl exec deploy/rtp-relay -n media -- cat /etc/resolv.conf
#    nameserver <node upstream>   (no search ...svc.cluster.local)

# 3. Prove it can't resolve a cluster name
kubectl exec deploy/rtp-relay -n media -- getent hosts session-broker.media.svc.cluster.local; echo "exit=$?"
#    (no output) exit=2

# 4. Compare with a normal Pod — this one uses cluster DNS
kubectl exec deploy/session-broker -n media -- cat /etc/resolv.conf
#    nameserver <kube-dns ClusterIP> + search media.svc.cluster.local ...

# 5. The field that caused it
kubectl get pod -n media -l app=rtp-relay \
  -o jsonpath='{range .items[*]}hostNetwork={.spec.hostNetwork}  dnsPolicy={.spec.dnsPolicy}{"\n"}{end}'
#    hostNetwork=true  dnsPolicy=ClusterFirst
```

**Exact fix:**

Set the DNS policy that keeps cluster DNS on the host network:

```bash
kubectl patch deployment rtp-relay -n media --type=merge \
  -p '{"spec":{"template":{"spec":{"dnsPolicy":"ClusterFirstWithHostNet"}}}}'
# or: kubectl edit deployment rtp-relay -n media  → dnsPolicy: ClusterFirstWithHostNet
```

**Verify:**

```bash
kubectl get deploy rtp-relay -n media -o jsonpath='dnsPolicy={.spec.template.spec.dnsPolicy}{"\n"}'
kubectl exec deploy/rtp-relay -n media -- getent hosts session-broker.media.svc.cluster.local; echo "exit=$?"
#    resolves, exit=0 — and the Pod is still on hostNetwork
```

**Production thinking:**

Make `dnsPolicy: ClusterFirstWithHostNet` a standing rule for every `hostNetwork` workload that talks to cluster Services — bake it into the template so it can't be forgotten. The bug is invisible until the Pod resolves an in-cluster name, so it ships clean and pages later. If DNS is failing for *all* Pods, not just the hostNetwork ones, that's a different incident: check CoreDNS in `kube-system` and the `kube-dns` endpoints before touching a workload.

</details>

---

## Break/fix 02 — multi-NIC Pod stuck ContainerCreating

**Symptom — what you'd actually see:**

`media-probe` in `edge` never starts — it's stuck in `ContainerCreating` and never goes `Ready`. The container image and resources are fine; the Pod's sandbox can't be built.

**Think about this before you open the answer:**

Reading a `ContainerCreating` hang as a network-attachment problem, and knowing NADs are namespaced. Self-grading questions:

- Did you go to `describe pod` events (not logs — the container never ran) and read the `FailedCreatePodSandBox` line?
- Did you check `get network-attachment-definitions -A` and notice the NAD was in a different namespace, rather than assuming it was missing entirely?
- Did you fix it with a `<namespace>/<name>` reference (or a local NAD copy), not by editing the image or resources?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`media-probe` requests the extra network by **bare** name (`k8s.v1.cni.cncf.io/networks: rtp-macvlan`), but the `rtp-macvlan` NetworkAttachmentDefinition exists only in `media`, not in `edge`. NADs are namespaced, and a bare network name is resolved against the **Pod's own** namespace (the same namespace-scoping rule as M04's cross-namespace DNS). Multus looks for `rtp-macvlan` in `edge`, can't find it, and sandbox setup fails — so the Pod hangs at `ContainerCreating` (it can't reach `Running` with an incomplete network namespace). The fix is the cross-namespace reference `media/rtp-macvlan` (or a copy of the NAD in `edge`).

**Diagnostic commands (run in this order):**

```bash
# 1. The signature: ContainerCreating, not a runtime error
kubectl get pods -n edge -l app=media-probe -o wide     # STATUS ContainerCreating

# 2. The event names what Multus couldn't find
kubectl describe pod -n edge -l app=media-probe | tail -20
#    FailedCreatePodSandBox ... NetworkAttachmentDefinition ... 'rtp-macvlan' not found (namespace edge)

# 3. What the Pod asked for — a bare name
kubectl get pod -n edge -l app=media-probe \
  -o jsonpath='{.items[0].metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks}{"\n"}'
#    rtp-macvlan

# 4. Where the NAD actually lives
kubectl get network-attachment-definitions -A
#    NAMESPACE media  NAME rtp-macvlan   (not in edge)
```

The mismatch — the Pod is in `edge`, the NAD is in `media`, the reference is bare — is the whole bug.

**Exact fix:**

Qualify the network reference with the NAD's namespace:

```bash
kubectl patch deployment media-probe -n edge --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"media/rtp-macvlan"}}}}}'
# or: give edge its own copy of the NAD:
#   kubectl get nad rtp-macvlan -n media -o yaml | sed 's/namespace: media/namespace: edge/' | kubectl apply -f -
```

**Verify:**

```bash
kubectl get pods -n edge -l app=media-probe -o wide            # now Running
kubectl exec deploy/media-probe -n edge -- ls /sys/class/net   # eth0 lo net1
```

**Production thinking:**

This is M04's cross-namespace DNS trap one layer down: a bare name is namespace-scoped, whether it's a Service or a NAD. Standardize on either shared NADs referenced as `<namespace>/<name>`, or a NAD per namespace that needs the network — and keep them templated (Kustomize/Helm, M16–M17) so a Pod and its NAD can't drift into different namespaces. File the signature away: a `ContainerCreating` Pod with a `FailedCreatePodSandBox` event is almost always CNI/attachment, not the image.

</details>

---

## Break/fix 03 — NodePort blackholes on one node

**Symptom — what you'd actually see:**

External health checks against `rtp-ingress` (NodePort `30080`) flap — some succeed, some time out, with no pattern in the app. The Pod is `Running` and `Ready`, `get svc` is normal, `get endpoints` is populated. Reachability depends on which node's IP the client hits.

**Think about this before you open the answer:**

Telling a NodePort-policy failure from a workload failure, and the `Local` vs `Cluster` trade. Self-grading questions:

- Did the populated EndpointSlice + healthy Pod steer you away from the M04 selector/endpoint reflexes and toward the NodePort layer?
- Did you reproduce the failure *per node IP*, not just once, to see the split?
- Did you read `connection timed out` (dropped) as different from `refused`, and connect it to `externalTrafficPolicy: Local` with no local endpoint?
- Did you weigh keeping `Local` (source IP) with per-node endpoints, rather than reflexively switching to `Cluster`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The Service is `externalTrafficPolicy: Local`, and its single backing Pod runs on one node. Under `Local`, kube-proxy programs each node to serve the NodePort **only if that node has a local endpoint**, and to silently **drop** the traffic otherwise — it never forwards across nodes, which is how it preserves the client's source IP<sup><a href="https://kubernetes.io/docs/tutorials/services/source-ip/">[2]</a></sup>. So the node running the Pod answers and every other node is a blackhole. The Service and EndpointSlice look healthy throughout. The fix is `externalTrafficPolicy: Cluster` (accept the SNAT), or keep `Local` and put an endpoint on every node.

**Diagnostic commands (run in this order):**

```bash
# 1. The Service and endpoints look fine — NOT the empty-EndpointSlice case (M04)
kubectl get svc rtp-ingress -n media                    # 80:30080/TCP
kubectl get endpoints rtp-ingress -n media              # populated
kubectl get pod -n media -l app=rtp-ingress -o wide     # Running, Ready, on ONE node

# 2. Reproduce the split — hit each node's IP
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  echo -n "$ip:30080 -> "; curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://$ip:30080 || echo TIMEOUT
done
#    one node -> 200, the other -> TIMEOUT (dropped, not refused)

# 3. Read the policy
kubectl get svc rtp-ingress -n media \
  -o jsonpath='type={.spec.type}  externalTrafficPolicy={.spec.externalTrafficPolicy}{"\n"}'
#    type=NodePort  externalTrafficPolicy=Local
```

The discriminator vs M04's black hole: there the EndpointSlice was empty; here it's populated and the Pod is healthy — the drop is at the NodePort policy, per node.

**Exact fix:**

Restore reachability by load-balancing cluster-wide:

```bash
kubectl patch svc rtp-ingress -n media --type=merge \
  -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
# or keep Local and guarantee a local endpoint on every node:
#   run the front-end as a DaemonSet, or topology-spread enough replicas
```

**Verify:**

```bash
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  echo -n "$ip:30080 -> "; curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://$ip:30080 || echo TIMEOUT
done
#    every node -> 200
```

**Production thinking:**

`Local` is the right choice when you need the real client IP (source routing, per-tenant rate-limiting, media keyed off the caller). Its requirement is an endpoint on every node that receives external traffic — so pair it with a DaemonSet or topology spread, and point the external LB's health check at the Service's `healthCheckNodePort` (which `Local` publishes precisely so an LB stops sending traffic to nodes with no local endpoint). Reach for `Cluster` when even load-balancing outweighs the source IP. What never works is `Local` plus a single-node backend and an expectation that every node answers — most visible during a rollout that briefly drains the one serving node.

</details>

---
