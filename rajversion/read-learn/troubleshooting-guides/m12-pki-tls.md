# `m12-pki-tls/` — M12 — PKI & TLS

**Category:** PKI / TLS / cert-manager

Concept reading: `m12-pki-tls/LESSON.md`

## Break/fix 01 — Issuance: a Certificate that won't issue

**Symptom — what you'd actually see:**

`config-api` in `media` is stuck `ContainerCreating`, `0/1`, and never serves HTTPS. The rest of the fleet is healthy.

**Think about this before you open the answer:**

Climbing the issuance ladder instead of debugging the Pod. Self-grading questions:

- Did the `FailedMount` send you to the *Secret*, and the missing Secret to the *Certificate*, rather than to the Pod's image or command?
- Did you read the `CertificateRequest` (not just the `Certificate`) to get the actual reason issuance failed<sup><a href="https://cert-manager.io/docs/troubleshooting/">[2]</a></sup>?
- Did you recognize that a `Ready: False` cert writes no Secret, so the Pod *couldn't* start — the two symptoms have one cause?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The `config-api-tls` `Certificate`'s `issuerRef` names `polyphone-ca-typo`, an issuer that doesn't exist. cert-manager has nothing to sign with, so the `Certificate` sits `Ready: False`, the `kubernetes.io/tls` Secret<sup><a href="https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets">[4]</a></sup> `config-api-tls` is **never written**, and the Pod that mounts that Secret can't start — a `FailedMount` for a Secret that isn't there<sup><a href="https://cert-manager.io/docs/concepts/">[1]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Stuck, not crashing — it can't even start
kubectl get pods -n media -l app=config-api               # ContainerCreating, 0/1

# 2. What is it waiting on? A Secret that doesn't exist
kubectl describe pod -n media -l app=config-api | sed -n '/Events:/,$p'
#    Warning FailedMount ... secret "config-api-tls" not found

# 3. That Secret is written by a Certificate — is it Ready?
kubectl get certificate config-api-tls -n media           # READY False

# 4. WHY isn't it? The reason is on the child CertificateRequest
kubectl describe certificaterequest -n media -l cert-manager.io/certificate-name=config-api-tls | sed -n '/Status:/,$p'
#    Referenced "ClusterIssuer" not found: ... "polyphone-ca-typo" not found

kubectl get clusterissuers                                # the real one is polyphone-ca
```

**Exact fix:**

Repoint the `Certificate` at the real internal-CA issuer.

```bash
kubectl patch certificate config-api-tls -n media --type=merge \
  -p '{"spec":{"issuerRef":{"name":"polyphone-ca"}}}'
```

**Verify:**

```bash
kubectl wait --for=condition=Ready certificate/config-api-tls -n media --timeout=90s   # True
kubectl get secret config-api-tls -n media                                             # now exists
kubectl rollout restart deployment/config-api -n media                                 # nudge the stuck Pod
kubectl rollout status  deployment/config-api -n media --timeout=90s
```

**Production thinking:**

A single wrong `issuerRef` in a manifest takes a service fully offline, and the failure surfaces as a stuck Pod that looks nothing like a cert problem. Two guards: an admission check (or CI lint) that every `issuerRef` resolves to an existing issuer before merge; and an alert on `Certificate` objects that are `Ready: False` for more than a few minutes, which catches issuance failures — bad issuer, RBAC on the issuer, an unreachable CA — before a rollout mounts the missing Secret.

</details>

---

## Break/fix 02 — Identity: a cert valid for the wrong name

**Symptom — what you'd actually see:**

`config-api` is `Running 1/1`, its `Certificate` is `Ready`, the Secret exists — but `config-client`'s mTLS call fails: `curl: (60) SSL: no alternative certificate subject name matches target host name 'config-api.media.svc.cluster.local'`.

**Think about this before you open the answer:**

Splitting a handshake failure into identity vs trust from the error text, and reading a cert's SANs. Self-grading questions:

- Did the error's wording (`subject name matches`, not `local issuer certificate`) tell you this was identity, not trust?
- Did you decode the served cert and compare its SANs to the exact name the client dialed, rather than assuming the `Ready` cert was correct?
- Did you fix `dnsNames` **and** roll the server (cert-manager reissues, but nginx won't reload a mounted cert on its own)?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The server cert's Subject Alternative Names list only `config-api-legacy.media.svc.cluster.local`, but clients reach the Service at `config-api.media.svc.cluster.local`. Modern TLS verifies the connection's target host against the cert's **SANs** (the Common Name doesn't count), so a valid, trusted cert is rejected because its identity doesn't cover the name dialed<sup><a href="https://cert-manager.io/docs/usage/certificate/">[3]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — read WHICH check failed
kubectl exec -n app-services deploy/config-client -- \
  curl -sS --cert /etc/tls/id/tls.crt --key /etc/tls/id/tls.key \
       --cacert /etc/tls/trust/ca.crt https://config-api.media.svc.cluster.local/
#    (60) ... no alternative certificate subject name matches target host name  → identity, not trust

# 2. The app is fine; a green Certificate says "issued", not "correct"
kubectl get pods -n media -l app=config-api               # Running 1/1
kubectl get certificate config-api-tls -n media           # READY True

# 3. Read the served cert's SANs, and the dnsNames driving them
kubectl get secret config-api-tls -n media -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -ext subjectAltName                # DNS:config-api-legacy.media.svc.cluster.local
kubectl get certificate config-api-tls -n media -o jsonpath='{.spec.dnsNames}{"\n"}'
```

**Exact fix:**

Put every name clients use back into `dnsNames`, let cert-manager reissue, and roll nginx so it loads the new cert.

```bash
kubectl patch certificate config-api-tls -n media --type=merge -p \
  '{"spec":{"dnsNames":["config-api.media.svc.cluster.local","config-api.media.svc","config-api"]}}'
kubectl wait --for=condition=Ready certificate/config-api-tls -n media --timeout=90s
kubectl rollout restart deployment/config-api -n media       # nginx loaded the OLD cert at startup
```

**Verify:**

```bash
kubectl get secret config-api-tls -n media -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -ext subjectAltName                  # now includes config-api.media.svc.cluster.local
kubectl exec -n app-services deploy/config-client -- \
  curl -sS --cert /etc/tls/id/tls.crt --key /etc/tls/id/tls.key \
       --cacert /etc/tls/trust/ca.crt https://config-api.media.svc.cluster.local/   # config-api: mTLS OK
```

**Production thinking:**

A missing SAN is a deterministic bug that *looks* intermittent — same-namespace callers using the short name may pass while cross-namespace callers using the FQDN fail, or vice-versa, depending on which names made it into the cert. Generate `dnsNames` from the Service's real names (or let a mesh/ingress integration derive them) so the cert and the Service can't drift, and remember `CN` is legacy: put every name in the SANs.

</details>

---

## Break/fix 03 — Trust: the client trusts the wrong CA

**Symptom — what you'd actually see:**

`config-api`'s cert is issued, `Ready`, and correctly named — but `config-client`'s mTLS call fails: `curl: (60) SSL certificate problem: unable to get local issuer certificate`.

**Think about this before you open the answer:**

Recognizing a trust failure and fixing it by distributing the right CA — not by disabling verification. Self-grading questions:

- Did `unable to get local issuer certificate` read as *trust* (the client's CA), sending you to compare the server's *issuer* against the CA the client holds?
- Did you find the mismatch by reading both certs (`-issuer` on the server cert, `-subject` on the client's mounted CA), not by guessing?
- Did you fix it by mounting the correct CA bundle, and explicitly **not** by adding `--insecure` / `insecureSkipVerify`?

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`config-client` mounts the wrong trust bundle. Its `/etc/tls/trust` volume points at `legacy-ca-bundle` — an unrelated CA (`polyphone-legacy-ca`) — while the server's cert is signed by `polyphone-internal-ca`. The client can't chain the server's cert up to any CA it holds, so it rejects a perfectly valid certificate. This is a *trust* failure, not a bad cert<sup><a href="https://cert-manager.io/docs/configuration/ca/">[5]</a></sup>.

**Diagnostic commands (run in this order):**

```bash
# 1. Reproduce — the error is trust, not identity
kubectl exec -n app-services deploy/config-client -- \
  curl -sS --cert /etc/tls/id/tls.crt --key /etc/tls/id/tls.key \
       --cacert /etc/tls/trust/ca.crt https://config-api.media.svc.cluster.local/
#    (60) ... unable to get local issuer certificate   → the client doesn't trust the signer

# 2. Who signed the server's cert?
kubectl get secret config-api-tls -n media -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -issuer                         # issuer=CN=polyphone-internal-ca

# 3. Which CA is the client actually trusting?
kubectl exec -n app-services deploy/config-client -- \
  openssl x509 -in /etc/tls/trust/ca.crt -noout -subject # subject=CN=polyphone-legacy-ca  ← mismatch

# 4. Where does the wrong bundle come from?
kubectl get deploy config-client -n app-services \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="trust")].secret.secretName}{"\n"}'   # legacy-ca-bundle
```

**Exact fix:**

Mount the correct trust bundle (the internal CA's public cert). A strategic-merge patch updates the `trust` volume by name and leaves the identity volume alone.

```bash
kubectl patch deployment config-client -n app-services -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"trust","secret":{"secretName":"internal-ca-bundle"}}]}}}}'
kubectl rollout status deployment/config-client -n app-services --timeout=90s
```

**Verify:**

```bash
kubectl exec -n app-services deploy/config-client -- \
  openssl x509 -in /etc/tls/trust/ca.crt -noout -subject   # subject=CN=polyphone-internal-ca
kubectl exec -n app-services deploy/config-client -- \
  curl -sS --cert /etc/tls/id/tls.crt --key /etc/tls/id/tls.key \
       --cacert /etc/tls/trust/ca.crt https://config-api.media.svc.cluster.local/   # config-api: mTLS OK
```

**Production thinking:**

`curl --insecure` makes this error vanish by making verification meaningless — the client will now accept *any* cert, including an attacker's, so a trust bug becomes a silent MITM hole. The real fix is trust *distribution*: get the correct `ca.crt` (public, safe to spread) to every client. Copy-per-namespace doesn't scale; **trust-manager** syncs a CA bundle into every namespace and lets you hold two CAs during a root rotation so the swap doesn't cause a fleet-wide outage. Ban `insecureSkipVerify` in review — a passing test with verification off is worse than a failing one.

</details>

---
