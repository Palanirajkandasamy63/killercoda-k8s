# `m01b-workloads-batch/` — M01b — Workloads: Jobs & CronJobs

**Category:** Jobs & CronJobs

Concept reading: `m01b-workloads-batch/LESSON.md`

## Break/fix 01 — CronJob Never Fires

**Symptom — what you'd actually see:**

Report: the `cdr-rollup` CronJob in `cdr-storage` hasn't produced output. No recent Jobs, no Pods, no error logs, no events. Billing reconciliation drifting on stale CDRs.

**Think about this before you open the answer:**

Not flipping a boolean — that's trivial. The skill is the **differential for a CronJob that creates nothing**, so you don't go spelunking through logs that don't exist. Self-grading questions:

- Did you recognize there were no logs/events *because* a suspended CronJob does nothing — rather than concluding the cluster was broken?
- Did you read `SUSPEND`/`LAST SCHEDULE`/`ACTIVE`/`schedule` as a checklist, instead of guessing one cause?
- Did you backfill the missed run with `kubectl create job --from=cronjob/...` rather than just waiting?

<details>
<summary>📖 Going deeper: the other ways a CronJob silently fires nothing<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/">[2]</a></sup></summary>

`suspend: true` is the most common, but the differential has more entries, and they all present identically (no Jobs, no obvious error):

- **A valid schedule that never matches.** `0 0 31 2 *` is legal cron — the 31st of February — and fires never. So is `0 0 30 2 *`. Always read the schedule semantically, not just for syntax errors (the API rejects *malformed* cron, but not *impossible* dates).
- **Missed runs past `startingDeadlineSeconds`.** If the controller was down or the cluster was too busy and a scheduled time slipped by more than `startingDeadlineSeconds`, that run is dropped. Set it very low and transient delays silently eat runs; `describe cronjob` shows "missed schedule" / "too many missed start times" events.
- **A previous run stuck `Active` with `concurrencyPolicy: Forbid`.** `Forbid` skips a new run while the old one is still going — so one hung Job blocks *all* successors. `kubectl get jobs` reveals the stuck `Active` Job; killing or fixing it unblocks the schedule.
- **Timezone confusion.** By default schedules are interpreted in the kube-controller-manager's timezone (UTC on most clusters). A `spec.timeZone` field exists; a mismatch between the expected and actual zone makes a CronJob fire "at the wrong time," which reads as "didn't fire" to whoever's watching the wrong clock.

The reflex: a silent CronJob is almost never a broken controller. It's a spec field — read them in order.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The CronJob has `spec.suspend: true`. A suspended CronJob is valid and otherwise healthy — the scheduler simply skips it, so it creates no Jobs<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/">[2]</a></sup>. That's why there's nothing to find in logs or events: it isn't failing, it's switched off. The most common real-world cause is someone suspending it for a maintenance window and never re-enabling it.

**Diagnostic commands (run in this order):**

```bash
# 1. Confirm it's creating nothing — LAST SCHEDULE <none>, no Jobs
kubectl get cronjob cdr-rollup -n cdr-storage
kubectl get jobs -n cdr-storage -l app=cdr-rollup
```

```bash
# 2. Work the differential — the default columns ARE the differential
kubectl get cronjob cdr-rollup -n cdr-storage
# SCHEDULE / SUSPEND / ACTIVE / LAST SCHEDULE → SUSPEND=True, that's it
```

```bash
# 3. Confirm it on the resource itself — describe spells out the flag and shows events
kubectl describe cronjob cdr-rollup -n cdr-storage
# Suspend:  True
```

**Exact fix:**

```bash
# A CronJob is patchable — suspend is a mutable, run-governing field.
kubectl patch cronjob cdr-rollup -n cdr-storage -p '{"spec":{"suspend":false}}'
# or kubectl edit, suspend: true → false (or delete the line)

# Backfill the missed run immediately rather than waiting for the schedule:
kubectl create job --from=cronjob/cdr-rollup cdr-rollup-recover -n cdr-storage
```

**Verify:**

```bash
kubectl get cronjob cdr-rollup -n cdr-storage      # SUSPEND False; LAST SCHEDULE updates within a minute
kubectl get jobs -n cdr-storage -l app=cdr-rollup  # recover Job + scheduled Job(s) reappearing
```

**Production thinking:**

The deeper issue is detection. A crash-looping Deployment pages you because traffic drops; a suspended CronJob pages *no one* — the only signal is stale data noticed downstream days later. The durable fix is twofold: correct `suspend` in `platform-gitops` so a Flux reconcile doesn't re-suspend it, and add a freshness/heartbeat alert (alert if `time() - kube_cronjob_status_last_schedule_time > 2 × period`, or if the rollup output table hasn't advanced). Make a missed scheduled run as loud as a down service.

</details>

---

## Break/fix 02 — Job Stuck Retrying

**Symptom — what you'd actually see:**

Release blocked: the pre-deploy `schema-migrate` Job in `provisioning` won't complete. `COMPLETIONS` stuck at `0/1`; one Pod with a climbing `RESTARTS` count.

**Think about this before you open the answer:**

Reading Job failure state correctly and knowing Jobs are immutable. Self-grading questions:

- Did you check `.status.conditions` to tell *retrying* from *given up*, rather than assuming "0/1" means "stuck"?
- Did you read `kubectl logs job/<name>` to find the *actual* failure (a typo → exit 127), not guess?
- Did you reach for delete-and-recreate after the patch was rejected — rather than fighting the immutability error?

<details>
<summary>📖 Going deeper: OnFailure vs Never, and why a Failed Job won't self-heal<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/job/">[1]</a></sup></summary>

**`OnFailure` vs `Never` change what you see.** `OnFailure` restarts the same container in place — one Pod, climbing `RESTARTS`, `CrashLoopBackOff` between tries (this scenario). `Never` leaves each failed Pod and creates a *new* one per attempt — a growing list of `Error` Pods, restart count stuck at 0. Same root-cause work; different surface. `Never` is useful when you want each attempt's Pod preserved for forensics; `OnFailure` is tidier when you don't.

**`backoffLimit` is the give-up count, and the give-up is sticky.** Once a Job is `Failed`, it does not retry on its own and — crucially — it does **not** self-heal the way a Deployment does. A Deployment with a fixed image rolls forward on the next reconcile; a `Failed` Job just sits there. So fixing the manifest in Git is necessary but not sufficient: something has to *re-run* the Job. In a GitOps world that usually means deleting the failed Job so Flux recreates it from the corrected manifest (or a pipeline step that re-applies it). Know that the corrected source won't execute itself.

**`activeDeadlineSeconds`** is the other bound: a wall-clock cap that overrides `backoffLimit` and fails a Job that runs too long — the right control for a migration that must not bleed into the maintenance window's end.

**`podFailurePolicy`** (stable since v1.31) is the modern complement to `backoffLimit`. This scenario's typo exits `127` every time — a guaranteed failure that `backoffLimit` still dutifully retries three times. A `podFailurePolicy` rule that does `FailJob` on that exit code would fail the Job on the *first* attempt, surfacing the bug in seconds. The mirror case: a rule that does `Ignore` on the `DisruptionTarget` condition so a node preemption or spot reclaim doesn't burn a retry. `podFailurePolicy` classifies *why* a Pod failed; `backoffLimit` caps how many countable failures you tolerate. See `LESSON.md` for the full breakdown.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

The Job's container command has a typo on its final step — `ecaho` instead of `echo` — so the shell exits `127` (command not found) every run<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/job/">[1]</a></sup>. With `restartPolicy: OnFailure` the kubelet retries the *same* Pod in place (climbing restarts, `CrashLoopBackOff` between attempts), and the Job counts failures toward `backoffLimit` (3); once exhausted, the Job goes to `Failed` and stops trying<sup><a href="https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#restart-policy">[3]</a></sup>. No number of retries fixes a typo.

**Diagnostic commands (run in this order):**

```bash
# 1. Read the bound + live status: retrying, or given up? (yaml carries both spec + status)
kubectl get job schema-migrate -n provisioning
kubectl get job schema-migrate -n provisioning -o yaml
# spec.backoffLimit: 3 , template restartPolicy: OnFailure
# status: no Failed condition = still retrying; conditions[].type=Failed = backoffLimit exhausted
```

```bash
# 2. OnFailure → one pod, climbing RESTARTS (not a pile of new pods)
kubectl get pods -n provisioning -l app=schema-migrate
```

```bash
# 3. Ask the pod WHY it dies — the log gets through early steps then errors
kubectl logs job/schema-migrate -n provisioning
# ...applying 001_init
# /bin/sh: ecaho: not found
```

```bash
# 4. Confirm a real non-zero exit (not a probe kill): in Containers:, the Last State: block
POD=$(kubectl get pod -n provisioning -l app=schema-migrate -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod $POD -n provisioning
#   Last State:  Terminated   Reason: Error   Exit Code: 127
```

**Exact fix:**

A Job's pod template is immutable — `kubectl patch` of the command returns `field is immutable`. Delete and recreate with the corrected command:

```bash
kubectl delete job schema-migrate -n provisioning
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: schema-migrate
  namespace: provisioning
  labels: { app: schema-migrate, plane: control, tier: lab }
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: schema-migrate, plane: control, tier: lab }
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: busybox:1.36
          command: ["/bin/sh","-c","echo '[schema-migrate] connecting'; echo '[schema-migrate] applying 001_init'; sleep 3; echo '[schema-migrate] done'"]
EOF
```

**Verify:**

```bash
kubectl wait --for=condition=complete job/schema-migrate -n provisioning --timeout=60s
kubectl get job schema-migrate -n provisioning    # COMPLETIONS 1/1
```

**Production thinking:**

The live recreate unblocks the release, but the typo is in the manifest in `platform-gitops`. Correct it there and let Flux apply — then confront the detection gap: a migration command that exits 127 every time should fail in CI or staging, not in the release pipeline. Why did a Job whose command had never run successfully get promoted? And because a `Failed` Job won't re-run itself on reconcile, decide who owns re-triggering it after the fix lands (Flux deletes-and-recreates, a pipeline re-applies, or an operator does it by hand).

</details>

---

## Break/fix 03 — Completions Shortfall

**Symptom — what you'd actually see:**

Finance ticket: the daily `usage-export` in `analytics` is missing data — only 1 of 4 shards reached downstream. But the Job reports `COMPLETIONS 1/1`, `Complete`, exit 0, no errors, no failed Pods.

**Think about this before you open the answer:**

Not trusting a green status, and understanding `completions`/`parallelism`. Self-grading questions:

- Did you question `Complete` and compare `completions` to the *real* work size, rather than closing the ticket on a green Job?
- Did you confirm no Pods actually failed — distinguishing "did too little" from "errored"?
- Did you recreate (immutability) and confirm `4/4`, not just bump a number you assumed was patchable?

<details>
<summary>📖 Going deeper: Indexed completion makes "which shard is missing?" answerable<sup><a href="https://kubernetes.io/docs/tasks/job/indexed-parallel-processing-static/">[6]</a></sup></summary>

Default `NonIndexed` mode treats completions as interchangeable — any 4 successes finish the Job, and there's no built-in notion of *which* shard each Pod did. That's fine when Pods pull from a shared queue, but for statically partitioned work (export day-partition 0, 1, 2, 3) it has two weaknesses: nothing assigns each Pod a partition, and when one fails you only know "3 of 4 succeeded," not *which* one is missing.

`completionMode: Indexed` fixes both. The Job hands each Pod a unique `JOB_COMPLETION_INDEX` (0…`completions`-1) via env var and annotation; the Pod reads it to pick its partition, and the Job is Complete only when every index has succeeded exactly once. The operational payoff is diagnosability: the succeeded set is `{0,1,3}` and you instantly know shard 2 failed. For Polyphone's `usage-export`, Indexed mode would both eliminate the coordination problem and turn "missing data somewhere" into "shard 2 didn't run." When you see sharded batch work, ask whether it should be Indexed.

Note this scenario's bug — wrong `completions` — would still be a bug under Indexed mode (you'd set the count wrong either way). Indexed doesn't prevent under-sizing; it makes a *partial failure* legible. The guard against under-sizing is reviewing `completions` against the known work size, ideally in CI.

</details>

<details>
<summary><b>Click to reveal: diagnostic commands, root cause, exact fix, verify</b></summary>

**Root cause:**

`spec.completions` is `1` when the work is 4 shards. A Job marks itself `Complete` the instant `succeeded` reaches `completions`<sup><a href="https://kubernetes.io/docs/concepts/workloads/controllers/job/#parallel-jobs">[1]</a></sup> — so with `completions: 1` it ran one Pod, succeeded once, and declared done while shards 2–4 were never processed. Nothing failed; the spec was simply sized wrong. This is the batch analog of M01's "`Running` ≠ `Ready`": **`Complete` ≠ correct.**

**Diagnostic commands (run in this order):**

```bash
# 1. The status that lies — Complete, but is the target right?
kubectl get job usage-export -n analytics
# COMPLETIONS 1/1  Complete
```

```bash
# 2. Compare the target against the real work (4 shards) — describe shows the sizing + result
kubectl describe job usage-export -n analytics
#   Completions: 1   ← should be 4
#   Pods Statuses: 0 Active / 1 Succeeded / 0 Failed
```

```bash
# 3. Confirm only one pod ran — no hidden failures, just under-sized work
kubectl get pods -n analytics -l app=usage-export   # one Completed pod, 0 restarts
kubectl logs job/usage-export -n analytics          # one shard processed
```

**Exact fix:**

`completions` is immutable. Delete and recreate sized to the real work:

```bash
kubectl delete job usage-export -n analytics
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: usage-export
  namespace: analytics
  labels: { app: usage-export, plane: control, tier: lab }
spec:
  completions: 4
  parallelism: 2
  backoffLimit: 4
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: usage-export, plane: control, tier: lab }
    spec:
      restartPolicy: OnFailure
      containers:
        - name: export
          image: busybox:1.36
          command: ["/bin/sh","-c","echo '[usage-export] processing a usage shard'; sleep 4; echo '[usage-export] shard complete'"]
EOF
```

**Verify:**

```bash
kubectl wait --for=condition=complete job/usage-export -n analytics --timeout=60s
kubectl get job usage-export -n analytics
# COMPLETIONS 4/4  Complete
```

**Production thinking:**

This is the most dangerous failure in the module because it's invisible to every health check — the Job is `Complete`, so liveness of the *pipeline* looks fine. Detection has to come from the *output*, not the Job: reconcile row counts (does the export have 4 partitions?), or assert the expected `completions` in a policy check before deploy. The durable fix corrects `completions` in `platform-gitops`; the real deliverable is a data-completeness check so "the job is green but the data is short" can't reach finance again. Consider Indexed mode so future partial failures name the missing shard.

</details>

---
