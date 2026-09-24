# Running the Polyphone Break/Fix Labs on Local kind

Good news: `background.sh` in every `baseline/` and `breakfix-*/` folder is
**plain `kubectl apply` / `helm install` / `curl` shell** — nothing Killercoda-specific.
Each breakfix folder's `background.sh` is the *entire* cluster bring-up script with
one mutation baked in (not a patch applied after the fact), so running it against
a fresh local cluster reproduces the scenario exactly.

## 1. Prerequisites (one-time)

Install on your machine:

```bash
# Docker (kind runs nodes as containers)
# https://docs.docker.com/get-docker/

# kind
brew install kind            # macOS
# or: go install sigs.k8s.io/kind@latest
# or: see https://kind.sigs.k8s.io/docs/user/quick-start/#installation

# kubectl
brew install kubectl         # macOS
```

Several modules install their own extra CLIs/controllers *inside* `background.sh`
via `curl .../linux-amd64...` (helm, istioctl, flux, k9s) — that only works if
you're running the script from a **Linux x86_64 shell**. If you're on macOS
(especially Apple Silicon) or Windows, pre-install these yourself instead and
the scripts will detect the binary is already on `PATH` and skip the download
for the ones that check first — but a few don't check, so it's safer to just
have them installed up front for these modules:

| Module | Extra tool needed | Install |
|---|---|---|
| `m17-helm` | `helm` | `brew install helm` |
| `m18-flux` | `flux` CLI | `brew install fluxcd/tap/flux` |
| `m15-service-mesh` | `istioctl` | `brew install istioctl` |
| `m16-kustomize` | none (`kubectl kustomize` built in) | — |
| `m20-kyverno-opa` | none (installs via manifest URL) | — |
| `m12-pki-tls` | none (installs cert-manager via manifest URL) | — |

Everything else (m00–m11, m13–m14, m19, m21–m22, m24) needs nothing beyond
`kubectl` — they only touch built-in Kubernetes objects.

## 2. Create the lab cluster

The scripts assume a **2-node cluster** (they label "the worker" `disktype=ssd`
and deliberately skip the control-plane node), so use the provided config:

```bash
kind create cluster --name polyphone-lab --config kind-cluster.yaml
kubectl config use-context kind-polyphone-lab
kubectl get nodes   # should show 2 nodes, both Ready within ~30-60s
```

## 3. Run a scenario

Every scenario folder (`baseline/`, `breakfix-01-.../`, etc.) has its own
self-contained `background.sh`. Pick one and run it:

```bash
# Healthy baseline for a module (read this first, to see "good" state)
./run-scenario.sh killercoda-k8s-main/m03-configuration/baseline

# A broken scenario
./run-scenario.sh killercoda-k8s-main/m03-configuration/breakfix-01-configmap-key-missing
```

`run-scenario.sh` just runs `bash background.sh` after checking your
`kubectl` context is actually the kind cluster (so you can't accidentally
nuke a real cluster), then prints that scenario's `intro.md` so you get the
same framing text Killercoda would show you.

It takes 20–90 seconds depending on the module (longer for ones that pull
cert-manager/Istio/Kyverno images). Then start diagnosing for real:

```bash
kubectl get pods -A
kubectl get pods -n media          # whatever namespace intro.md pointed at
kubectl describe pod ...
```

Use the `TROUBLESHOOTING-WORKBOOK.md` (or the per-module file in
`troubleshooting-guides/`) from earlier — read the Symptom + "think about
this" section, diagnose for real against this live cluster, then expand the
answer to check yourself. `step1/text.md` and `step2/text.md` inside each
scenario folder are the original Killercoda step hints if you want an
even softer nudge before the full answer key.

## 4. Reset before the next scenario

Because scenario `background.sh` files `kubectl apply` full manifests (not
diffs), you generally **cannot** just run a different scenario's
`background.sh` on top of a previous one and expect a clean break — leftover
objects from the last scenario (or a previous scenario's mutation) can linger
and confuse the picture. Two options:

**Full reset (reliable, ~30–60s) — recommended, especially across modules:**

```bash
./reset-lab.sh
# then run-scenario.sh again for the next one
```

**Fast reset (same module only, if you're iterating within one module):**

```bash
kubectl delete namespace media signaling app-services edge provisioning \
  admin-portal call-routing cdr-storage analytics number-porting \
  --ignore-not-found
# re-run that module's background.sh
```

The fast path won't undo cluster-scoped installs (cert-manager, Istio,
Kyverno, Flux controllers, CRDs) from a *different* module — if you're
switching from, say, `m12-pki-tls` to `m03-configuration`, do the full reset.

## 5. Tear down when you're done

```bash
kind delete cluster --name polyphone-lab
```

## Notes / gotchas

- **Images**: everything uses `nginx:1.25` as a stand-in app image (this is a
  concept lab, not a real SIP/media stack) — you don't need any private
  registry access.
- **Storage**: `background.sh` installs Rancher's `local-path-provisioner`
  and uses `storageClassName: local-path`. kind also ships its own default
  `standard` StorageClass — both can coexist; the scripts explicitly request
  `local-path`, so this doesn't matter.
- **k9s**: `baseline/background.sh` also curls down the `k9s` TUI binary as a
  convenience — safe to ignore if the curl fails locally (it's not required
  for any scenario, just a nicer `kubectl get`/`describe` browser).
- **Killercoda-only steps**: ignore anything in `step*/verify.sh` that
  references Killercoda's own grading endpoints, if present — `verify.sh`
  files here are plain `kubectl` assertions, so they should just work, but
  treat them as a sanity check, not gospel.
- **One breakfix scenario = one cluster state.** `foreground.sh` just prints
  a progress spinner and a hint once `/tmp/.setup-complete` exists — that
  file convention doesn't matter for local runs (`run-scenario.sh` runs
  `background.sh` synchronously and returns when it's done).
