# `m07-workloads-ii/` — M07 — Workloads II: StatefulSets & DaemonSets

**Category:** StatefulSets & DaemonSets

Concept reading: `m07-workloads-ii/LESSON.md`

## Break/fix 01 — Headless Service Missing

**Symptom — what you'd actually see:**

`session-store` (a 3-replica StatefulSet in `app-services`) has all three Pods `Running`, `READY 3/3`, correctly named — but its members can't reach each other, and `nslookup session-store-0.session-store.app-services.svc.cluster.local` returns NXDOMAIN.

**Think about this before you open the answer:**

Knowing that a StatefulSet's network identity is a Service you own, and that "Pods Running" ≠ "identity working." Self-grading:

- Did you check the *name resolution*, not just `get pods` (which looked healthy)?
- Did you find the missing Service via `serviceName` + `get svc`, rather than assuming the Pods or DNS were broken?
- Did you create it **headless** (`clusterIP: None`) — knowing a normal ClusterIP Service wouldn't publish the per-Pod records?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The StatefulSet's governing Service — named in `spec.serviceName: session-store` — was never created. A StatefulSet does **not** create its governing Service; you must, and it must be **headless** (`clusterIP: None`)<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/">[1]</a></sup>. Without a headless Service selecting the Pods, cluster DNS has no basis to publish the per-Pod A records `<pod>.<serviceName>.<ns>.svc.cluster.local`<sup><a href="https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/">[2]</a></sup>. Ordinal identity and storage are intact — only the network identity is missing — so the Pods look perfectly healthy.

**Diagnostic commands (run in this order):**

```bash
# 1. Pods are up and correctly named — this is NOT a crash or scheduling problem
kubectl get statefulset session-store -n app-services       # READY 3/3
kubectl get pods -n app-services -l app=session-store       # -0, -1, -2 all Running

# 2. The per-Pod name doesn't resolve
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n app-services -- \
  nslookup session-store-0.session-store.app-services.svc.cluster.local   # NXDOMAIN

# 3. The governing Service the StatefulSet expects — and its absence
kubectl get statefulset session-store -n app-services -o jsonpath='{.spec.serviceName}'; echo  # session-store
kubectl get svc -n app-services                              # no session-store Service
```

**Exact fix:**

Create the headless governing Service the StatefulSet points at:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: session-store
  namespace: app-services
  labels: { app: session-store, plane: app, tier: lab }
spec:
  clusterIP: None
  selector: { app: session-store }
  ports: [{ port: 80, name: http }]
EOF
```

**Verify:**

```bash
kubectl get svc session-store -n app-services               # CLUSTER-IP None
kubectl run dns --rm -i --restart=Never --image=busybox:1.36 -n app-services -- \
  nslookup session-store-0.session-store.app-services.svc.cluster.local   # resolves to Pod-0 IP
```

**Production thinking:**

This is the single most common StatefulSet mistake — the manifest ships the StatefulSet and forgets (or misnames, or gives a ClusterIP to) the governing Service. It passes every "are the Pods up?" check and fails only when peers try to find each other, which may be minutes into a cluster bootstrap. Guard it by templating the StatefulSet and its headless Service together (one Helm chart / Kustomize base — M16–M17) so they can't drift apart, and by adding a readiness or startup check in the app that actually resolves a peer name, turning a silent DNS gap into a failing probe.

</details>

---

## Break/fix 02 — Ordered Rollout Stall

**Symptom — what you'd actually see:**

`session-store` (declared `replicas: 3`, headless Service present this time) is stuck at `READY 0/3`, and only `session-store-0` exists — `Running` but `0/1` ready. `session-store-1` and `-2` were never created.

**Think about this before you open the answer:**

Reading the ordered lifecycle — recognizing that missing higher ordinals are a *symptom* of an un-ready lower one, not a separate failure. Self-grading:

- Did you notice only Pod-0 existed and read that as "the gate never opened," rather than looking for three failed Pods?
- Did you diagnose Pod-0's readiness (probe port vs. container port), not restart the whole set blindly?
- Do you understand *why* a Deployment wouldn't fail this way (parallel creation, no ordering gate)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`session-store-0`'s **readiness probe** targets port `8080`, but the container serves on port `80`; the probe is refused every time, so the kubelet never marks Pod-0 Ready. Under the default `podManagementPolicy: OrderedReady`, the controller creates ordinals one at a time and will not create Pod `N+1` until Pod `N` is Running **and** Ready<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/">[1]</a></sup>. Pod-0 never goes Ready, so ordinals 1 and 2 are never created. A Deployment would have created all three replicas at once and left the two healthy ones serving — the ordered lifecycle is what makes one un-ready Pod a whole-set stall.

**Diagnostic commands (run in this order):**

```bash
# 1. Only Pod-0 exists, and the set is 0/3 — a StatefulSet-shaped stall
kubectl get statefulset session-store -n app-services       # READY 0/3
kubectl get pods -n app-services -l app=session-store       # only session-store-0, 0/1 Running

# 2. Pod-0 is Running but not Ready — the probe is failing
kubectl describe pod session-store-0 -n app-services | grep -A8 Conditions   # Ready: False
kubectl describe pod session-store-0 -n app-services | grep -A6 Events        # Readiness probe failed: connection refused

# 3. The probe's port vs. the container's port
kubectl get statefulset session-store -n app-services \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet}'; echo   # port 8080
kubectl get statefulset session-store -n app-services \
  -o jsonpath='{.spec.template.spec.containers[0].ports}'; echo                    # containerPort 80
```

**Exact fix:**

Point the readiness probe at the port the container serves (80):

```bash
kubectl patch statefulset session-store -n app-services --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'
# The RollingUpdate recreates Pod-0 with the corrected probe. If it doesn't re-roll promptly:
kubectl delete pod session-store-0 -n app-services   # comes back with the same name + PVC
```

**Verify:**

```bash
kubectl rollout status statefulset/session-store -n app-services --timeout=120s
kubectl get statefulset session-store -n app-services       # READY 3/3
kubectl get pods -n app-services -l app=session-store       # -0, -1, -2 all 1/1 Running
```

**Production thinking:**

`OrderedReady` is a feature for apps that must bootstrap a seed member before peers join — and a foot-gun when a health check is wrong, because it converts one Pod's misconfiguration into a total rollout stall. Know the escape hatches: `podManagementPolicy: Parallel` drops the ordering gate (keeping stable names and storage) for apps that don't need sequential startup; and for updates, `partition` lets you canary a new revision to the top ordinals only, so a bad rollout is contained to a few Pods instead of stopping at ordinal 0. Either way, get the readiness probe right — in a StatefulSet it gates far more than one Pod.

</details>

---

## Break/fix 03 — DaemonSet Node Coverage

**Symptom — what you'd actually see:**

`rtp-probe`, a DaemonSet in `edge` meant to run on every node, reports `DESIRED 1` on a 2-node cluster. Its one Pod runs on the worker; the control-plane node has no `rtp-probe` Pod. Nothing is `Pending`, no event or error appears.

**Think about this before you open the answer:**

Reading `desiredNumberScheduled` as a coverage check, and knowing DaemonSet eligibility includes taint tolerations. Self-grading:

- Did you notice `DESIRED` was below the node count and treat *that* as the bug, rather than looking for a crashed or `Pending` Pod (there isn't one)?
- Did you find the uncovered node's taint and compare tolerations between the two DaemonSets?
- Did you match the toleration to the taint (key/effect), rather than guess at resources or affinity?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`rtp-probe`'s Pod template is missing a toleration for the control-plane taint `node-role.kubernetes.io/control-plane:NoSchedule`. A DaemonSet counts a node in `desiredNumberScheduled` only if the Pod matches the node's selectors/affinity **and** tolerates its taints<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/">[4]</a></sup><sup><a href="https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/">[3]</a></sup>. The control-plane node is tainted, `rtp-probe` doesn't tolerate it, so that node is ineligible — not counted, never scheduled, and silent (there's no rejected Pod to leave a `Pending` trail). The fleet's `sbc-edge` DaemonSet reaches both nodes precisely because it *does* carry that toleration.

**Diagnostic commands (run in this order):**

```bash
# 1. DESIRED is the coverage number, and it's short of the node count
kubectl get daemonset -n edge                # sbc-edge DESIRED 2; rtp-probe DESIRED 1
kubectl get nodes                            # 2 nodes
kubectl get pods -n edge -o wide             # rtp-probe only on the worker; control-plane uncovered

# 2. The uncovered node is tainted
kubectl describe node -l node-role.kubernetes.io/control-plane | grep -A2 Taints
#    node-role.kubernetes.io/control-plane:NoSchedule

# 3. sbc-edge tolerates it; rtp-probe tolerates nothing
kubectl get ds sbc-edge  -n edge -o jsonpath='{.spec.template.spec.tolerations}'; echo   # control-plane toleration
kubectl get ds rtp-probe -n edge -o jsonpath='{.spec.template.spec.tolerations}'; echo   # empty
```

**Exact fix:**

Add the control-plane toleration (the same form `sbc-edge` uses):

```bash
kubectl patch daemonset rtp-probe -n edge --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]'
# or: kubectl edit daemonset rtp-probe -n edge  → add the tolerations block
```

**Verify:**

```bash
kubectl get daemonset rtp-probe -n edge      # DESIRED 2 CURRENT 2 READY 2
kubectl get pods -n edge -o wide -l app=rtp-probe   # a Pod now on the control-plane node too
```

**Production thinking:**

This is how node-local agents (log shippers, security agents, CNI/CSI plugins, node exporters) silently miss nodes — a taint added to a node pool after the DaemonSet shipped, or a DaemonSet that never tolerated the control-plane/dedicated taints in the first place. Because it's silent, add a check that compares each critical DaemonSet's `desiredNumberScheduled` (or `numberReady`) against the node count and alerts on a gap — the control-plane and any tainted pools are where coverage quietly disappears. When you *do* want an agent everywhere including tainted nodes, the blunt instrument is `tolerations: [{ operator: Exists }]` (tolerate everything); prefer specific tolerations so you don't accidentally schedule onto nodes cordoned or under-pressure for a reason.

</details>

---
