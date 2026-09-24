# Polyphone / Killercoda Kubernetes Break/Fix Lab — Master Index

This repo is a set of **Killercoda scenarios** built around one running cluster (the "Polyphone" fleet). Each module (`mXX-...`) teaches one area of Kubernetes, then breaks it in 3–4 specific ways (`breakfix-NN-...`) so you can practice the real diagnostic loop: **`get` → `describe` → `events` → `logs`**, form a hypothesis, fix it, verify it.

This README is a **map of every scenario** in the repo: what topic it's under, what actually breaks, what category of problem it is (Pod / Config / Network / RBAC / etc.), and what question you should be asking yourself while you diagnose it. Each module folder already contains two files with the *full* answer — this index tells you which one to open and when:

- **`mXX-*/LESSON.md`** — the concept explainer for that module (mental model, vocabulary, a diagram of how the pieces fit, a failure-mode table).
- **`mXX-*/ANSWER-KEY.md`** — the self-grading answer key: for every break/fix, the exact symptom, root cause, the diagnostic commands in order, the fix commands, a verify step, self-grading questions, and a "production thinking" note on how you'd prevent/detect it for real.

**How to use this:** pick a module below, read the one-line issue for each of its scenarios without looking at the answer key, run the scenario in Killercoda, diagnose it yourself using the "what to think about" column, *then* open `ANSWER-KEY.md` to check your path.

---

## All modules at a glance

| # | Module | Category | Scenarios |
|---|--------|----------|-----------|
| m00-foundations | Mental Model & kubectl Fluency | Diagnostic fundamentals (kubectl / cluster awareness) | 3 |
| m01-workloads-i | Workloads I: Pods, Deployments, ReplicaSets | Pod lifecycle & probes | 3 |
| m01b-workloads-batch | Workloads: Jobs & CronJobs | Jobs & CronJobs | 3 |
| m02-images-registries | Container Images & Registries | Container images & registries | 4 |
| m03-configuration | Configuration | ConfigMaps & Secrets (config wiring) | 4 |
| m04-networking-services-dns | Networking I: Services & DNS | Services & DNS (networking) | 3 |
| m05-storage | Storage: Volumes, PersistentVolumes, Claims & StorageClasses | PersistentVolumes / Claims (storage) | 4 |
| m06-scheduling | Scheduling | Scheduler (Pending pods, taints, resources) | 4 |
| m07-workloads-ii | Workloads II: StatefulSets & DaemonSets | StatefulSets & DaemonSets | 3 |
| m08-crds-operators | CRDs & Operators | CRDs & Operators | 3 |
| m09-resilience-autoscaling | Resilience & Autoscaling | Resilience & autoscaling (PDB, HPA, rollouts) | 3 |
| m10-security-rbac | Security I: RBAC & Pod Security | RBAC & Pod Security (403 Forbidden) | 4 |
| m11-secrets-at-scale | Security II: Secrets at Scale | External secrets pipelines | 3 |
| m12-pki-tls | PKI & TLS | PKI / TLS / cert-manager | 3 |
| m13-observability | Observability | Logs, events, metrics | 3 |
| m14-networking-policy-ingress | Networking II: Policy & Ingress | NetworkPolicy & Ingress | 3 |
| m15-service-mesh | Service Mesh | Service mesh (Istio-style) | 3 |
| m16-kustomize | Kustomize Bases & Overlays | Kustomize bases/overlays | 3 |
| m17-helm | Helm Fundamentals | Helm charts & releases | 3 |
| m18-flux | Flux (GitOps Delivery) | Flux GitOps | 3 |
| m19-multi-cluster | Multi-cluster Fleet | Multi-cluster fleet config | 3 |
| m20-kyverno-opa | Policy as Code: Kyverno & OPA Gatekeeper | Policy-as-code (Kyverno/OPA) | 3 |
| m21-admission-control | Admission Control: Validating & Mutating Webhooks | Admission webhooks | 3 |
| m22-host-networking | Host Networking & Multi-NIC | Host networking / multi-NIC | 3 |
| m24-stateful-coordination | Stateful Coordination: Identity, Discovery & Leadership | Stateful coordination (identity/leader election) | 3 |
| m26-operate-platform | Operating the Platform: Where You Go From Here | Capstone module — no break/fix scenarios (wrap-up/reflection) | 0 |

---

## `m00-foundations/` — M00 — Mental Model & kubectl Fluency

**Category:** Diagnostic fundamentals (kubectl / cluster awareness)

**What the module covers:** The foundation. How a Kubernetes cluster is organized, how `kubectl` actually works, and the four-command diagnostic loop every later module assumes.

**Full concept writeup:** `m00-foundations/LESSON.md`  ·  **Full answers:** `m00-foundations/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Context Blindness**<br/>`breakfix-01-context-blindness` | Alert says Polyphone workloads are degraded. You run kubectl get pods and see nothing. | Is the cluster broken, or is your view broken? |
| **Namespace Blindness**<br/>`breakfix-02-namespace-blindness` | Something on the Polyphone cluster is broken. You don't know where. | Use cluster-wide situational awareness to find and fix it. |
| **Event-Only Failure**<br/>`breakfix-03-event-only-failure` | A Deployment in the Polyphone fleet is short a replica. The pods that exist are fine. | The answer isn't on any Pod — practice climbing the owner chain. |

## `m01-workloads-i/` — M01 — Workloads I: Pods, Deployments, ReplicaSets

**Category:** Pod lifecycle & probes

**What the module covers:** What a Pod actually is, how its lifecycle works, how the three probes decide "alive" and "ready," and why graceful shutdown is the difference between a clean rollout and dropped calls.

**Full concept writeup:** `m01-workloads-i/LESSON.md`  ·  **Full answers:** `m01-workloads-i/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Liveness Restart Loop**<br/>`breakfix-01-liveness-restart-loop` | A workload is stuck in CrashLoopBackOff — but the app is healthy. | Tell a real crash from a liveness probe killing a good container, and fix it. |
| **Readiness Traffic Blackhole**<br/>`breakfix-02-readiness-traffic-blackhole` | A Service has no endpoints and callers get nothing — but every Pod is Running and not restarting. | Find why readiness is pulling them from rotation, and fix it. |
| **preStop Truncation**<br/>`breakfix-03-prestop-truncation` | The workload is healthy and serving — until it shuts down. Every rollout drops in-flight sessions. | Find why the drain is being cut short, and fix it. |

## `m01b-workloads-batch/` — M01b — Workloads: Jobs & CronJobs

**Category:** Jobs & CronJobs

**What the module covers:** The other half of the workload family: controllers whose goal is *finishing*, not *staying up*. How a Job drives Pods to successful completion, how `backoffLimit` and `restartPolicy` decide what a failure costs, how `completions`/`parallelism` shard the work, and how a CronJob turns a Job into a clock-driven task.

**Full concept writeup:** `m01b-workloads-batch/LESSON.md`  ·  **Full answers:** `m01b-workloads-batch/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **CronJob Never Fires**<br/>`breakfix-01-cronjob-never-fires` | The nightly cdr-rollup hasn't run — no pods, no errors, nothing in the logs. | Work the CronJob differential and get it firing again. |
| **Job Stuck Retrying**<br/>`breakfix-02-job-backofflimit` | A schema-migrate Job won't complete — its pods keep failing. | Read backoffLimit and restartPolicy, find why every attempt fails, and recreate the Job to fix it. |
| **Completions Shortfall**<br/>`breakfix-03-completions-shortfall` | usage-export reports Complete, but downstream sees only a fraction of the data. | A green Job that's still wrong — read completions against the real work size, and recreate. |

## `m02-images-registries/` — M02 — Container Images & Registries

**Category:** Container images & registries

**What the module covers:** What a container image actually is, how a Pod *names* one, and every way the name can fail to become a running container. The pull-failure differential: read the kubelet's status and you know which link in registry → reference → policy → auth broke.

**Full concept writeup:** `m02-images-registries/LESSON.md`  ·  **Full answers:** `m02-images-registries/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **ErrImageNeverPull**<br/>`breakfix-01-never-pull` | A workload won't start and there are no logs. The status isn't ImagePullBackOff — it's ErrImageNeverPull. | Tell 'wouldn't pull' from 'couldn't pull', and fix it. |
| **Registry Unreachable**<br/>`breakfix-02-registry-unreachable` | A pod is in ImagePullBackOff. Is it auth, a bad tag, or something else? Read the event message: this one says 'no such host'. | Fix the unreachable registry. |
| **401 Unauthorized**<br/>`breakfix-03-imagepull-auth` | media-recorder is in ImagePullBackOff against the private registry. The event says 401 Unauthorized. | Wire an imagePullSecret and recover the pull. |
| **Digest Mismatch**<br/>`breakfix-04-digest-mismatch` | A digest-pinned workload fails with 'manifest unknown'. The registry is reachable and authenticated — the reference resolves to nothing. | Re-pin it correctly. |

## `m03-configuration/` — M03 — Configuration

**Category:** ConfigMaps & Secrets (config wiring)

**What the module covers:** How a Pod gets its configuration — ConfigMaps and Secrets, injected as environment variables or mounted as files — and the four ways that wiring breaks: the Pod won't start, won't update, or runs but reads the wrong value.

**Full concept writeup:** `m03-configuration/LESSON.md`  ·  **Full answers:** `m03-configuration/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **CreateContainerConfigError**<br/>`breakfix-01-configmap-key-missing` | A workload won't start and the status is CreateContainerConfigError, not a crash or a pull error. | Trace it to a config key the ConfigMap doesn't have, and fix it. |
| **stuck ContainerCreating**<br/>`breakfix-02-secret-volume-missing` | A workload is stuck in ContainerCreating with no logs and no config error. | Trace the FailedMount event to a Secret that was never created, and fix it. |
| **config edited, nothing changed**<br/>`breakfix-03-stale-env-config` | A ConfigMap was updated, but the workload still serves the old value. | Diagnose the propagation gap — env is frozen at container start — and make the change take. |
| **Running, but the credential is wrong**<br/>`breakfix-04-secret-double-base64` | A workload is Running and Ready, but authenticating with a garbled password. | Find the green-but-wrong config by reading the injected value, and trace it to a double-base64'd Secret. |

## `m04-networking-services-dns/` — M04 — Networking I: Services & DNS

**Category:** Services & DNS (networking)

**What the module covers:** How a stable name reaches a moving set of Pods — Services, selectors, EndpointSlices, kube-proxy, and cluster DNS — and the three places on that path where traffic silently stops flowing.

**Full concept writeup:** `m04-networking-services-dns/LESSON.md`  ·  **Full answers:** `m04-networking-services-dns/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **DNS — Cross-Namespace Name**<br/>`breakfix-01-dns-cross-namespace` | account-provisioner can't reach the session broker. The configured name won't resolve. Read the DNS answer: a bare Service name used across namespaces returns NXDOMAIN. | Qualify it. |
| **Selector Mismatch**<br/>`breakfix-02-selector-mismatch` | route-engine is unreachable but its Pods are healthy and its Service looks normal. Check the EndpointSlice: it's empty. | Find the selector that matches no Pod and fix it. |
| **Port Mismatch**<br/>`breakfix-03-port-mismatch` | portal-ui refuses connections, but this time the EndpointSlice is populated. The traffic reaches a Pod and gets rejected. | Find the targetPort that points at no listener. |

## `m05-storage/` — M05 — Storage: Volumes, PersistentVolumes, Claims & StorageClasses

**Category:** PersistentVolumes / Claims (storage)

**What the module covers:** A Pod's own filesystem dies with the Pod. This module covers the objects that give a Pod durable storage, and the three places on that path where a Pod stops before it runs.

**Full concept writeup:** `m05-storage/LESSON.md`  ·  **Full answers:** `m05-storage/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **A Claim That Never Binds**<br/>`breakfix-01-pvc-storageclass-missing` | cdr-writer is stuck Pending and never starts. Its claim is Pending too, because it names a StorageClass that does not exist, so no volume is ever provisioned. | Find it with get pvc and describe pvc, then repair the class. |
| **A Pod Names a Claim That Is Not There**<br/>`breakfix-02-pvc-claim-missing` | directory is stuck Pending because it names a claim that does not exist. | Read describe pod and get pvc to see the Pod pointing at a claimName that was never created, then repoint it at the claim that is there. |
| **An RWO Volume Cannot Serve Two Nodes**<br/>`breakfix-03-rwo-multi-attach` | directory was scaled to 2 replicas sharing one ReadWriteOnce claim. The claim is Bound, and one replica is stuck, because an RWO volume cannot be attached on a second node. | Read the Bound-but-stuck signature and match the access mode to the workload. |
| **RWOP Refuses a Second Pod**<br/>`breakfix-04-rwop-single-pod` | cdr-writer runs 2 replicas on one node, and its claim is ReadWriteOncePod. The claim is Bound, one replica runs, and the scheduler refuses the other. | Read the access mode, then restore an access mode the workload can actually use. |

## `m06-scheduling/` — M06 — Scheduling

**Category:** Scheduler (Pending pods, taints, resources)

**What the module covers:** How the scheduler decides which node runs each Pod — requests, limits, QoS, taints, and affinity — and the handful of ways a Pod ends up `Pending` forever or gets killed the moment it starts.

**Full concept writeup:** `m06-scheduling/LESSON.md`  ·  **Full answers:** `m06-scheduling/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Insufficient Resources**<br/>`breakfix-01-insufficient-resources` | stream-analyzer never starts — its Pod is stuck Pending. | Read the FailedScheduling event, find the oversized memory request, and right-size it so it fits a node. |
| **Untolerated Taint**<br/>`breakfix-02-untolerated-taint` | pstn-probe is Pending, but nothing is short on resources. A node was tainted for a dedicated pool and the Pod lacks the matching toleration. | Read the node's taint and add it. |
| **Anti-affinity Unschedulable**<br/>`breakfix-03-antiaffinity-unschedulable` | sip-director wants 3 replicas but only one is Running; two are Pending. A required one-per-node anti-affinity has nowhere to spread on this cluster. | Soften it or add nodes. |
| **OOMKilled**<br/>`breakfix-04-oom-killed` | media-buffer schedules fine, then CrashLoopBackOff. Its Last State is OOMKilled, exit 137 — a memory limit set below the container's working set. | Raise the limit. |

## `m07-workloads-ii/` — M07 — Workloads II: StatefulSets & DaemonSets

**Category:** StatefulSets & DaemonSets

**What the module covers:** The two workload controllers a Deployment can't replace: one gives each Pod a durable name, its own disk, and a strict startup order; the other pins one Pod to every node. Both trade the Deployment's interchangeable-replica model for something more specific — and both fail in ways a Deployment never does.

**Full concept writeup:** `m07-workloads-ii/LESSON.md`  ·  **Full answers:** `m07-workloads-ii/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Headless Service Missing**<br/>`breakfix-01-headless-service-missing` | session-store's Pods are all Running, but its members can't find each other — session-store-0.session-store... returns NXDOMAIN. The StatefulSet's governing headless Service was never created. | Find it missing and create it. |
| **Ordered Rollout Stall**<br/>`breakfix-02-ordered-rollout-stall` | session-store is stuck at READY 0/3 with only Pod-0 present, Running but never Ready. Under OrderedReady, an un-ready Pod-0 blocks every ordinal behind it. | Find why Pod-0 won't go Ready and unblock the set. |
| **DaemonSet Node Coverage**<br/>`breakfix-03-daemonset-node-coverage` | rtp-probe is meant to run on every node, but on this 2-node cluster it reports DESIRED 1 — the control-plane node has no Pod, no error, no Pending. A missing toleration made that node ineligible. | Read the coverage gap and close it. |

## `m08-crds-operators/` — M08 — CRDs & Operators

**Category:** CRDs & Operators

**What the module covers:** The API server ships with a fixed vocabulary — Pods, Deployments, Services. A CustomResourceDefinition adds your own words to it; an operator is the program that makes those words mean something. Together they're how every capability above the built-ins — databases, certificates, mesh config — gets delivered, and how it quietly fails.

**Full concept writeup:** `m08-crds-operators/LESSON.md`  ·  **Full answers:** `m08-crds-operators/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Custom Resource Rejected by Schema**<br/>`breakfix-01-cr-schema-rejected` | A product team's new MediaTenant, vega, never appeared — kubectl get shows only orion and lyra, and no vega-media Deployment exists. The manifest is at /root/vega-tenant.yaml. | Find why the API server refused it and get vega provisioned. |
| **Reconciliation Stuck (Operator RBAC)**<br/>`breakfix-02-reconcile-stuck-rbac` | The tenant-operator Pod is Running, but no MediaTenant ever reaches Ready and no child Deployments exist — every tenant sits at phase=Provisioning. Nothing crashed. | Read status, then the operator's logs, to find why reconciliation makes no progress, and unblock it. |
| **Orphaned Child (Missing Owner Reference)**<br/>`breakfix-03-orphaned-owner-reference` | Tenant vega was offboarded weeks ago — its MediaTenant is gone — but vega-media is still Running and holding capacity. Cascading deletion should have removed it. | Find why it was orphaned instead of collected, and reclaim the capacity. |

## `m09-resilience-autoscaling/` — M09 — Resilience & Autoscaling

**Category:** Resilience & autoscaling (PDB, HPA, rollouts)

**What the module covers:** How Kubernetes keeps a service available while the world changes underneath it — demand rising and falling, versions shipping, nodes draining — and the handful of ways each of those controls quietly stops protecting you.

**Full concept writeup:** `m09-resilience-autoscaling/LESSON.md`  ·  **Full answers:** `m09-resilience-autoscaling/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **PDB Blocks Drain**<br/>`breakfix-01-pdb-blocks-drain` | You need to drain the worker for a kernel patch, but the drain hangs — an eviction is refused. sip-registrar's PodDisruptionBudget allows zero disruptions. | Find out why and give the budget headroom. |
| **HPA Can't Read Its Metric**<br/>`breakfix-02-hpa-no-requests` | transcode-scaler's HorizontalPodAutoscaler is stuck at <unknown>/50% and never scales. The target has no CPU request, so there's no denominator for a utilization percentage. | Add the request. |
| **Stuck Rollout**<br/>`breakfix-03-rollout-stuck` | A portal-web release has been rolling out for minutes and never finishes. The new ReplicaSet's Pods can't pull their image; the old version is still serving. | Diagnose the stuck rollout and roll it back. |

## `m10-security-rbac/` — M10 — Security I: RBAC & Pod Security

**Category:** RBAC & Pod Security (403 Forbidden)

**What the module covers:** The two questions every request to the API server must pass — *who are you* and *what may you do* — plus the admission gate that decides whether a Pod's security posture is allowed at all, and the handful of ways each one returns `Forbidden`.

**Full concept writeup:** `m10-security-rbac/LESSON.md`  ·  **Full answers:** `m10-security-rbac/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **RBAC — a missing verb**<br/>`breakfix-01-rbac-missing-verb` | endpoint-watcher CrashLoopBackOffs with a 403 Forbidden. Its Role grants get/watch on endpoints but not list. | Read the Forbidden, find the too-narrow Role, add the missing verb. |
| **ServiceAccount — running as default**<br/>`breakfix-02-serviceaccount-default` | route-watcher CrashLoopBackOffs with a 403 Forbidden — but the message names ...:default, not the SA someone bound. The Pod omits serviceAccountName. | Set it and the correct identity is used. |
| **RBAC — wrong scope**<br/>`breakfix-03-rbac-cluster-scope` | node-inspector CrashLoopBackOffs with a 403 that ends 'at the cluster scope'. A namespaced Role/RoleBinding can't grant the cluster-scoped nodes resource. | Re-grant with a ClusterRole + ClusterRoleBinding. |
| **PodSecurity — a rejected Pod**<br/>`breakfix-04-podsecurity-restricted` | payments-api sits 0/1 with no Pods at all — not even Pending. The namespace enforces the restricted Pod Security Standard and the Pod sets no securityContext, so admission rejects it. | Read the ReplicaSet event and add a compliant securityContext. |

## `m11-secrets-at-scale/` — M11 — Security II: Secrets at Scale

**Category:** External secrets pipelines

**What the module covers:** Why a plaintext Secret can't live in Git, and the two patterns that fix it — sync a secret in from an external store, or commit it encrypted and decrypt it in-cluster. Both turn a Secret into something a controller *materializes*, which moves the failure surface out of the Pod and into the pipeline that feeds it.

**Full concept writeup:** `m11-secrets-at-scale/LESSON.md`  ·  **Full answers:** `m11-secrets-at-scale/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **SecretSync SyncError (Missing Source Key)**<br/>`breakfix-01-source-key-missing` | The partner-connector Pod (media) is stuck in CreateContainerConfigError and its partner-api Secret doesn't exist — while the billing side is perfectly healthy. Nothing crashed. | Read the SecretSync's status, not the Pod's logs, to find why the Secret was never materialized, and fix it. |
| **Store Access Denied (SecretStore Not Ready)**<br/>`breakfix-02-store-access-denied` | Both consumers — billing-processor and partner-connector — are down at once, and every SecretSync reads StoreNotReady. The operator Pod is Running. One shared dependency is broken: the operator lost read access to the backing store. | Diagnose store-first, using auth can-i --as the operator, and restore access. |
| **Rotation Not Propagated (Stale Consumer)**<br/>`breakfix-03-rotation-not-propagated` | The database password was rotated in the store and the pipeline synced it — every SecretSync is Synced, the db-credentials Secret holds the new value, nothing is red. Yet billing-processor is still presenting the OLD password. | Find the failure the status doesn't show, and make the rotation actually reach the consumer. |

## `m12-pki-tls/` — M12 — PKI & TLS

**Category:** PKI / TLS / cert-manager

**What the module covers:** How workloads get a cryptographic identity and use it to talk securely. cert-manager turns a declarative `Certificate` into a signed key pair; an internal CA signs the fleet's certs; mutual TLS proves *both* ends. Every TLS failure is one of three questions — was the cert **issued**, does its **identity** match, is it **trusted** — and this module teaches you to tell them apart at a glance.

**Full concept writeup:** `m12-pki-tls/LESSON.md`  ·  **Full answers:** `m12-pki-tls/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **a Certificate that won't issue**<br/>`breakfix-01-certificate-not-ready` | config-api is stuck ContainerCreating and its Certificate reads Ready: False. The issuerRef names an issuer that doesn't exist, so cert-manager never signs it, the kubernetes.io/tls Secret is never written, and the Pod that mounts it can't start. | Climb the issuance ladder — Certificate then CertificateRequest — and repoint issuerRef at the real internal-CA issuer. |
| **a cert valid for the wrong name**<br/>`breakfix-02-san-mismatch` | config-api is Running, its Certificate is Ready, and the TLS Secret exists — but the mTLS call fails with 'no alternative certificate subject name matches target host name'. The server cert's SANs omit config-api.media.svc.cluster.local, the name the client dials. | Read the cert's SANs, put the real dnsNames back, and reload nginx. |
| **the client trusts the wrong CA**<br/>`breakfix-03-trust-mismatch` | config-api's cert is issued, Ready, and correctly named — but config-client's mTLS call fails with 'unable to get local issuer certificate'. The client mounts the wrong trust bundle (legacy-ca-bundle, an unrelated CA), so it can't verify the server's cert, which is signed by the internal CA. | Point the client's trust volume back at internal-ca-bundle. |

## `m13-observability/` — M13 — Observability

**Category:** Logs, events, metrics

**What the module covers:** The three signals a running cluster already gives you — **events**, **logs**, **metrics** — plus the fourth you add yourself, **traces**; which question each answers, why every one of them is ephemeral, and how to read the right signal instead of guessing.

**Full concept writeup:** `m13-observability/LESSON.md`  ·  **Full answers:** `m13-observability/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Logs — an app that writes to a file**<br/>`breakfix-01-logs-to-stdout` | session-logger is Running 1/1 but kubectl logs shows only a startup banner. It writes its real logs to a file inside the container, and the kubelet captures only stdout/stderr. | Restore visibility — log to stdout, or add a streaming sidecar. |
| **Logs & Events — a crashlooping sidecar**<br/>`breakfix-02-sidecar-crashloop` | sip-monitor is stuck at 1/2. The nginx app container is healthy; its metrics-agent telemetry sidecar crashloops. | Read which container the events name, then logs -c metrics-agent --previous to see why the dead instance exited, and fix the sidecar's command. |
| **Metrics — a scrape target that's DOWN**<br/>`breakfix-03-metrics-scrape-port` | call-metrics is Running 1/1, kubectl top works, and its /metrics endpoint serves fine on port 80 — but its dashboards are flat. The prometheus.io/port annotation points at 9090, where nothing listens, so the scrape is refused and the target is DOWN. | Point the scrape port at the port /metrics is actually served on. |

## `m14-networking-policy-ingress/` — M14 — Networking II: Policy & Ingress

**Category:** NetworkPolicy & Ingress

**What the module covers:** Two controls that shape traffic the Service layer leaves wide open: NetworkPolicy, which turns a flat, default-open pod network into segmented east-west lanes, and Ingress, the L7 front door for north-south HTTP — plus the failure signatures each one adds.

**Full concept writeup:** `m14-networking-policy-ingress/LESSON.md`  ·  **Full answers:** `m14-networking-policy-ingress/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **NetworkPolicy Default-Deny**<br/>`breakfix-01-networkpolicy-default-deny` | session-broker in media went dark — callers time out — but its Pods are healthy, its Service has endpoints, and DNS resolves. A default-deny locked the namespace and no allow was ever added. | Add the allow without removing the deny. |
| **NetworkPolicy Cross-Namespace**<br/>`breakfix-02-networkpolicy-cross-namespace` | An allow policy exists and names sip-app, but the cross-namespace caller is still denied. The `from` peer is a bare podSelector — namespace-local — so it matches nothing. | Add the namespaceSelector. |
| **Ingress Misrouting**<br/>`breakfix-03-ingress-misrouting` | The portal Ingress returns 503, but portal-ui's Pods, Service, and endpoints are all healthy. The rule forwards to a port the Service doesn't expose. | Read describe ingress against the Service and fix the port. |

## `m15-service-mesh/` — M15 — Service Mesh

**Category:** Service mesh (Istio-style)

**What the module covers:** A second dataplane, layered inside the pod network: a proxy beside every workload that carries its traffic, so routing, retries, timeouts, circuit breaking, and mutual TLS become platform config instead of application code — plus the new failure signatures that dataplane introduces, and the tool that reads them.

**Full concept writeup:** `m15-service-mesh/LESSON.md`  ·  **Full answers:** `m15-service-mesh/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Sidecar Not Injected**<br/>`breakfix-01-sidecar-not-injected` | Calls to session-broker fail with 503, but its Pods are Running/Ready and its Service has endpoints. The workload was opted out of sidecar injection, so it isn't in the mesh — and with mTLS required upstream, callers can't reach it. | Re-enroll it in the mesh. |
| **VirtualService Subset**<br/>`breakfix-02-virtualservice-subset` | session-broker returns 503 through the mesh, but its Pods are 2/2, in the mesh, with endpoints and working mTLS. The VirtualService routes to a subset that has no pods, so Envoy has an empty cluster and no healthy upstream. | Route it back to a subset that exists. |
| **mTLS Mode Mismatch**<br/>`breakfix-03-mtls-mode-mismatch` | session-broker 503s even though its Pods are 2/2, the route targets a subset with endpoints, and mTLS is 'on'. The DestinationRule tells callers to send plaintext while the PeerAuthentication requires mTLS — the two halves disagree. | Align them. |

## `m16-kustomize/` — M16 — Kustomize Bases & Overlays

**Category:** Kustomize bases/overlays

**What the module covers:** One base, many environments, no templating language. How Kustomize composes and transforms plain YAML — and the three distinct layers where it fails.

**Full concept writeup:** `m16-kustomize/LESSON.md`  ·  **Full answers:** `m16-kustomize/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Patch Target Mismatch**<br/>`breakfix-01-patch-target-mismatch` | The prod promotion of edge-relay isn't landing and the workload is missing from the cluster. The apply never got past `kustomize build`. | Read the build error, find the patch that targets a resource that doesn't exist, and fix it. |
| **Generator Name Mismatch**<br/>`breakfix-02-generator-name-mismatch` | edge-relay rendered and applied fine, but its Pod is stuck in CreateContainerConfigError. The generated ConfigMap exists under a hashed name; the Deployment asks for a name that doesn't. | Find why Kustomize didn't rewrite the reference. |
| **commonLabels vs the Immutable Selector**<br/>`breakfix-03-commonlabels-immutable-selector` | edge-relay runs on the lab spec; promoting the prod overlay is rejected with 'field is immutable'. A label transformer is writing into the Deployment's selector. | Move it off the selector and let the promotion land. |

## `m17-helm/` — M17 — Helm Fundamentals

**Category:** Helm charts & releases

**What the module covers:** The Kubernetes package manager. How a chart plus values renders into manifests, what a release actually is, and how to debug the three ways Helm bites you: a value that doesn't take, an upgrade that "succeeds" but breaks, and a render that fails before anything deploys.

**Full concept writeup:** `m17-helm/LESSON.md`  ·  **Full answers:** `m17-helm/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Values Key Ignored**<br/>`breakfix-01-values-key-ignored` | A values file sets replicas: 3, but the voicemail release runs one pod. The value is present in the release, yet the workload never changed. | Find out why Helm ignored it. |
| **Bad Upgrade, Rollback**<br/>`breakfix-02-bad-upgrade-rollback` | A voicemail upgrade reported success, but the rolled pods are stuck. helm status says deployed. | The revision history holds the fix. |
| **Render Required Value**<br/>`breakfix-03-render-required-value` | The voicemail install failed and nothing deployed. No release, no pods. | Read the render error, reproduce it offline with helm template, and supply the missing value. |

## `m18-flux/` — M18 — Flux (GitOps Delivery)

**Category:** Flux GitOps

**What the module covers:** Git is the desired state; a controller in the cluster makes it true and keeps it true. How Flux fetches a source, reconciles it, corrects drift, and orders dependent releases — and the three places the pipeline stalls without touching your workload.

**Full concept writeup:** `m18-flux/LESSON.md`  ·  **Full answers:** `m18-flux/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Source Ref Not Found**<br/>`breakfix-01-source-ref-not-found` | A GitRepository points at a branch that doesn't exist. Flux applies nothing new, nothing crashes, and the cluster quietly runs no GitOps workloads. | Read the source's Ready condition first. |
| **Kustomization Suspended**<br/>`breakfix-02-kustomization-suspended` | A hand-scaled Deployment won't revert to its git-declared count, and get output looks healthy. | Find the suspended consumer and resume it. |
| **HelmRelease Dependency**<br/>`breakfix-03-helmrelease-dependency` | A HelmRelease is stuck not-ready and never installs, though the source, the apps Kustomization, and its message-store dependency are all healthy. | Read the dependsOn message and correct the reference. |

## `m19-multi-cluster/` — M19 — Multi-cluster Fleet

**Category:** Multi-cluster fleet config

**What the module covers:** One repo, many clusters. How a fleet's desired state is composed per-cluster from shared layers — and the three ways a value ends up wrong for one cluster while every other cluster is fine.

**Full concept writeup:** `m19-multi-cluster/LESSON.md`  ·  **Full answers:** `m19-multi-cluster/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Stale Cluster Variable**<br/>`breakfix-01-stale-cluster-var` | prod-eu-central-1 is healthy and running, but it reports the wrong region. A region overlay was cloned from its sibling and its REGION variable never updated. | Trace the value to its owning layer and fix the stale cluster variable. |
| **Shadowed Override**<br/>`breakfix-02-shadowed-override` | The us-east-1 region raised its session-capacity standard to 8000, but prod-us-east-1 still renders 5000. The region overlay is correct — a leftover per-cluster override sits later in the composition stack and wins. | Trace the winning layer and remove the shadow. |
| **Promotion in the Wrong Overlay**<br/>`breakfix-03-promotion-wrong-overlay` | A promotion of nginx:1.27 to stage didn't take — stage still runs 1.25 — while prod unexpectedly renders 1.27. The image pin landed in the wrong tier's overlay. | Diagnose the two-sided symptom and move the pin to the layer that owns that promotion step. |

## `m20-kyverno-opa/` — M20 — Policy as Code: Kyverno & OPA Gatekeeper

**Category:** Policy-as-code (Kyverno/OPA)

**What the module covers:** One more gate on every write to the API server — a policy engine that runs your organization's rules as admission webhooks: rejecting non-compliant objects, silently rewriting them to a safe default, and refusing images you didn't sanction — plus the handful of ways each of those goes wrong.

**Full concept writeup:** `m20-kyverno-opa/LESSON.md`  ·  **Full answers:** `m20-kyverno-opa/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Validation Rejects a Rollout**<br/>`breakfix-01-require-limits-rejected` | billing-api sits at 0/1 with no Pods. A Kyverno validate policy (Enforce) rejects its Pods at the ReplicaSet because it declares no resource limits. | Read the denial, find the rule, and fix the workload to comply. |
| **A Mutation That Never Fired**<br/>`breakfix-02-mutation-not-applied` | tenant-portal runs fine but is missing the owner label the platform injects on every tenant Pod. The mutate policy's match names the wrong namespace, so it never selected the Pods. | Fix the policy, then re-admit. |
| **Image Admission Rejects the Tag**<br/>`breakfix-03-image-tag-rejected` | call-recorder sits at 0/1 with no Pods. The image-admission policy (Enforce) rejects its Pods because the image is pinned to :latest. | Read the denial and pin the tag — the supply-chain gate. |

## `m21-admission-control/` — M21 — Admission Control: Validating & Mutating Webhooks

**Category:** Admission webhooks

**What the module covers:** The mechanism beneath every policy engine: two configuration objects that splice your own HTTPS callbacks into the API server's write path — one that rewrites objects, one that accepts or rejects them — plus the handful of ways a webhook wedges deploys, silently stops enforcing, or reaches into a namespace it was never meant to touch.

**Full concept writeup:** `m21-admission-control/LESSON.md`  ·  **Full answers:** `m21-admission-control/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **A Fail-Closed Webhook Wedges Deploys**<br/>`breakfix-01-webhook-fail-closed` | billing-api sits at 0/1 with no Pods. The admission-guard webhook backend is down, and with failurePolicy: Fail the API server rejects every Pod create in tenant-apps — a failed call, not a policy denial. | Read the FailedCreate event, distinguish 'failed calling webhook' from 'denied the request', and restore the backend. |
| **A Mutating Webhook That Never Fires**<br/>`breakfix-02-mutation-not-firing` | orders-api sits at 0/1 with no Pods, rejected by the validating webhook for a missing env label. But the author never sets env — the mutating webhook is supposed to. Its rules match UPDATE instead of CREATE, so it never fires on new Pods. The denial is at validation; the fault is upstream in mutation. | Fix the mutating config's operations. |
| **A Webhook Whose Scope Is Too Broad**<br/>`breakfix-03-webhook-scope-too-broad` | sip-canary in the signaling namespace sits at 0/1, rejected by the admission-guard validating webhook — a webhook that only governs tenant-apps. Its namespaceSelector was widened to {}, so it now intercepts every namespace. | Read the webhook's scope, see it reaching where it shouldn't, and narrow it back. |

## `m22-host-networking/` — M22 — Host Networking & Multi-NIC

**Category:** Host networking / multi-NIC

**What the module covers:** When a Pod steps off the default pod network to reach the node's own NIC and ports — hostNetwork, hostPort, a second interface via Multus, and the NodePort policy that decides which nodes actually serve traffic — and the four places each trade bites.

**Full concept writeup:** `m22-host-networking/LESSON.md`  ·  **Full answers:** `m22-host-networking/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **hostNetwork Pod Lost Cluster DNS**<br/>`breakfix-01-hostnetwork-dns` | rtp-relay is Running but can't resolve in-cluster Service names. A hostNetwork Pod left at the default dnsPolicy uses the node's resolver, not CoreDNS. | Give it ClusterFirstWithHostNet. |
| **Multi-NIC Pod Stuck ContainerCreating**<br/>`breakfix-02-multus-missing-nad` | media-probe in edge is stuck ContainerCreating. It asks Multus for a network by bare name, but the NetworkAttachmentDefinition lives in another namespace. | Reference it cross-namespace. |
| **NodePort Blackholes on One Node**<br/>`breakfix-03-etp-local-blackhole` | rtp-ingress answers on one node's IP and hangs on the other. externalTrafficPolicy Local drops traffic on nodes with no local endpoint. | Switch to Cluster, or put an endpoint on every node. |

## `m24-stateful-coordination/` — M24 — Stateful Coordination: Identity, Discovery & Leadership

**Category:** Stateful coordination (identity/leader election)

**What the module covers:** How a set of Pods stops being interchangeable and becomes a coordinated cluster — stable identity, per-Pod DNS for discovery, an ordered lifecycle, and a Lease-based leader — and the three links on that path that break while every Pod still looks healthy.

**Full concept writeup:** `m24-stateful-coordination/LESSON.md`  ·  **Full answers:** `m24-stateful-coordination/ANSWER-KEY.md`

| Scenario | Issue (symptom) | What to think about |
|---|---|---|
| **Per-Pod DNS Gone (Headless Service Lost clusterIP: None)**<br/>`breakfix-01-headless-service-clusterip` | Peers can't resolve session-cache-0.session-cache.media.svc anymore. The governing Service was created as a normal ClusterIP Service instead of headless, so per-Pod DNS records are no longer published. | Find it and recreate the Service headless. |
| **StatefulSet Wedged Behind Ordinal 0**<br/>`breakfix-02-statefulset-ordered-wedge` | session-cache should have 3 replicas but only session-cache-0 exists, stuck 0/1 Running. Its readiness probe never passes, and OrderedReady won't create the next ordinal until this one is Ready — so the whole set is halted. | Fix the probe and watch the ordered cascade. |
| **No Leader Ever Elected (Leader-Election RBAC)**<br/>`breakfix-03-leader-election-rbac` | call-coordinator's Pods are Running, but no leader is ever elected and no Lease is held. The ServiceAccount's leader-election Role is missing the verbs needed to acquire and renew the Lease lock. | Prove it with auth can-i and restore the Role. |
