# redis-worker-scaling

A Redis-backed job queue on Kubernetes. Workers pop job IDs from a Redis list, and **KEDA**
scales them from 0 to N based on queue depth. Jobs are **not lost** when KEDA scales workers
down. A reaper CronJob recovers jobs from workers that crashed.

```
produce.sh ─RPUSH─▶ "jobs" ─BLMOVE (atomic)─▶ "processing" ─MULTI{LREM, INCR done}─▶ done counter
                      ▲                          │   ▲
                      │ polls LLEN jobs          │   └── worker pods (bash + redis-cli), 0..10
                KEDA ─┘ 0→1 itself, 1→N via HPA  │        SIGTERM → finish current job → exit
                      ▲                          │
                      └──── LPUSH ◀── reaper CronJob (every minute): re-queues jobs stuck > 1 min
```

Everything runs in namespace `ingest` on a kind cluster (1 control-plane + 2 workers).

## Layout

| Path | Purpose |
|---|---|
| `kind-config.yaml` | 1 control-plane + 2 workers |
| `cluster/Containerfile`, `cluster/create-cluster.sh` | Patched kind node image + cluster creation (see "Cluster note") |
| `k8s/00-namespace.yaml` | Namespace `ingest` |
| `k8s/redis.yaml` | Redis 7 Deployment (password, readiness probe, limits) + Service |
| `k8s/worker.yaml` | `worker-config` ConfigMap (`REDIS_HOST`), worker script ConfigMap, Deployment |
| `k8s/keda.yaml` | KEDA TriggerAuthentication + ScaledObject |
| `k8s/reaper.yaml` | Bonus: reaper script ConfigMap + CronJob |
| `scripts/install-keda.sh` | Installs KEDA 2.21.0 via its official Helm chart |
| `scripts/deploy.sh` | Creates the password Secret (random, not in git), applies `k8s/`, restarts workers |
| `scripts/produce.sh N` | The producer: resets counters, pushes N unique job IDs onto `jobs` |
| `scripts/check.sh N` | The case's check: PASS when `done == N` and `jobs` / `processing` are empty |
| `scripts/redis.sh CMD…` | Runs `redis-cli` inside the Redis pod |
| `scripts/watch-replicas.sh [FILE]` | Logs replicas and queue state every 5 s as CSV |
| `scripts/scaledown-test.sh [N] [SCALE_AT]` | Part 3: forces a mid-run scale-down, then checks |
| `scripts/crash-test.sh [N]` | Bonus: SIGKILLs a busy worker, waits for the reaper, then checks |
| `results/` | Recorded evidence from the runs below |

## Setup, run, teardown

Prerequisites: podman (or docker), kind, kubectl, helm.

```bash
./cluster/create-cluster.sh           # build node image, create kind cluster, wait for nodes
./scripts/install-keda.sh             # KEDA from its Helm chart
./scripts/deploy.sh                   # Redis, worker, ScaledObject, reaper in namespace ingest

./scripts/produce.sh 20               # Part 1: push 20 jobs...
./scripts/check.sh 20                 # ...once idle: PASS

./scripts/watch-replicas.sh &         # Part 2: record replicas while 200 jobs run
./scripts/produce.sh 200              #   (kill %1 when done)

./scripts/scaledown-test.sh 100 5     # Part 3: scale down mid-run, then check
./scripts/crash-test.sh 20            # Bonus: hard-kill a worker, reaper recovers the job
```

Teardown:

```bash
kind delete cluster --name ren3                      # removes everything above
podman rmi localhost/kind-node-cgv1:v1.31.12         # optional: the patched node image
```

## Part 1: Deploy

- **Redis** runs `redis:7` with `--requirepass $(REDIS_PASSWORD)`. Kubernetes expands the
  password from the `redis-auth` Secret. A `Service` named `redis` gives it a stable DNS name.
  Persistence is off (`--save ""`, no AOF), so a Redis restart loses the queue. That's a
  deliberate simplification for this demo.
- **Readiness probe** on Redis runs an authenticated `redis-cli ping`. This checks that Redis is
  actually serving and that authentication works, not just that the port is open.
- **Worker** runs in the stock `redis:7` image, which already has bash and `redis-cli`, so no
  image build is needed. Its script is mounted from a ConfigMap. `REDIS_HOST` comes from the
  `worker-config` ConfigMap and `REDIS_PASSWORD` from the Secret.
- **Resources:** every container has requests and limits. They're kept small (worker 10m/16Mi
  request) so 10 workers fit on this 4-CPU / 3.6 GB host.

**Result:** 20 jobs with 1 worker drained in about 65 s (average 3.5 s per job, as expected), and `check.sh 20` → `PASS`.

## Part 2: Autoscale with KEDA

`k8s/keda.yaml`:

- **TriggerAuthentication `redis-auth`** reads the password from the same Secret the worker
  uses, so the ScaledObject never contains the password.
- **ScaledObject `worker`**: `redis` list trigger on `jobs` with `listLength: 5` (one worker per 5
  queued jobs), 0 to 10 replicas, `pollingInterval: 5`, `cooldownPeriod: 30`. HPA scale-down
  stabilization is reduced from 300 s to 30 s so scale-down is visible in the demo.
- The worker Deployment has **no `replicas` field**, because KEDA owns the replica count.
  Re-applying the manifest won't reset it.

### 200 jobs: replicas over time (`results/part2-200-jobs.csv`)

| t (s) | replicas | jobs | processing | done |
|---:|---:|---:|---:|---:|
| 5 | 0 | 0 | 0 | 0 |
| 10 | **1 → 5** | 199 | 1 | 0 |
| 26 | **10** | 169 | 10 | 21 |
| 56 | 10 | 85 | 10 | 105 |
| 82 | 10 | 8 | 10 | 182 |
| 87 | **9** | 0 | 4 | 196 |
| 92 | 9 | 0 | 0 | 200 |
| 102 | **1** | 0 | 0 | 200 |
| 112 | **0** | 0 | 0 | 200 |

The 200 jobs finished in about 90 s, versus about 700 s with 1 worker. `check.sh 200` → `PASS`. The
10 → 9 step is a scale-down mid-run while 4 jobs were in flight, and with the Part 3 fix nothing
was lost.

### How does the worker get from 0 → 1 and from 1 → N?

- **0 → 1: the KEDA operator.** A standard HPA can't scale from 0: with no pods there's nothing to
  measure, and its minimum is 1. So the KEDA operator polls Redis itself every `pollingInterval`
  (5 s). When the trigger becomes *active* (`LLEN jobs` > `activationListLength`, default 0), the
  operator sets the Deployment's replicas to 1 directly. Operator log:
  `Successfully updated ScaleTarget … Original Replicas Count: 0, New Replicas Count: 1`.
- **1 → N: the HPA that KEDA creates** (`keda-hpa-worker`, minimum 1, maximum 10). KEDA's metrics
  API server exposes `LLEN jobs` as an *external metric* (`s0-redis-jobs`). The HPA computes
  `desired = ceil(LLEN jobs / 5)`. For 200 jobs that's 40, capped at 10. Its default scale-up
  policy (at most +4 pods or +100% per 15 s, whichever is larger) produces the steps
  **1 → 5 → 10** (HPA events `New size: 5`, `New size: 10`).
- **Back down:** as the queue empties, the HPA lowers `desired` after its 30 s stabilization
  window. Once `jobs` has been empty for `cooldownPeriod` (30 s), KEDA sets 1 → 0.

## Part 3: Don't lose jobs

### The stub as given loses jobs

`scripts/scaledown-test.sh 100 5` pushes 100 jobs, waits until 5 replicas are ready, then forces
a KEDA scale-down mid-run by lowering `maxReplicaCount` to 2. The HPA removes 3 busy pods.

With the stub (`results/part3-before-stub.{csv,txt}`):

```
removed pods took 44s to terminate
stuck in processing: job-…-65 job-…-66 job-…-67
jobs=0 processing=3 done=97 (expected 100)
FAIL
```

**Why:** on scale-down, Kubernetes sends **SIGTERM** to the container's PID 1, waits
`terminationGracePeriodSeconds` (30 s), then sends **SIGKILL**. The stub is a bash script
running *as PID 1* with no handler. The kernel doesn't apply default signal actions to PID 1
of a PID namespace, so SIGTERM is **ignored**. The removed pods kept pulling new jobs for the
full 30 s, visible in the CSV as `ready=2` while `processing=5`. Then SIGKILL hit each one
mid-job: **3 pods removed → 3 jobs stranded in `processing` forever**.

The loss depends on timing. When I triggered the scale-down late in a run, the queue emptied
within the 30 s grace period and nothing was lost. A second path: pods still terminating from a
*previous* scale-to-0 took jobs from a new batch and were then killed.

### The fix (`k8s/worker.yaml`)

```bash
stop=0
trap 'stop=1; echo "SIGTERM: finishing current job, then exiting"' TERM
while [ "$stop" = 0 ]; do
  job=$(rcli BLMOVE jobs processing LEFT RIGHT 5)
  [ -n "$job" ] || continue
  sleep $((RANDOM % 4 + 2))
  printf 'MULTI\nLREM processing 1 %s\nINCR done\nEXEC\n' "$job" | rcli >/dev/null
done
```

- The **trap** handles SIGTERM, so it's no longer ignored. It only sets a flag. Bash runs the
  trap after the current foreground command (`redis-cli` or `sleep`) finishes, so the job in hand
  is always completed. The loop then exits instead of taking a new job.
- Worst case to exit: a 5 s `BLMOVE` wait (which may still return a job) plus a 5 s job, about
  10 s. `terminationGracePeriodSeconds: 30` is set explicitly to leave headroom.
- `LREM` + `INCR` now run in one **MULTI/EXEC** transaction, so a job can't be removed from
  `processing` without being counted.
- `deploy.sh` runs `rollout restart` because pods only read the ConfigMap script at start.

Same test after the fix (`results/part3-after-fix.{csv,txt}`):

```
removed pods took 16s to terminate
stuck in processing:
jobs=0 processing=0 done=100 (expected 100)
PASS
```

`processing` dropped 5 → 3 → 2 within about 10 s of the scale-down: the removed pods finished
their jobs and stopped. The worker's own log during a pod delete
(`results/part3-sigterm-log.txt`): `SIGTERM: finishing current job, then exiting` →
`worker exited cleanly`.

**Design note:** I first added a second KEDA trigger on `processing`, so KEDA wouldn't scale to 0
while a job was in flight. I removed it. SIGTERM handling already protects in-flight jobs, and
the trigger had a real downside: a job stuck in `processing` kept idle workers running
indefinitely (observed: 2 idle pods for 14+ minutes).

### What failure cases does the fix not cover?

The fix relies on the worker being **asked** to stop. It doesn't help when:

1. **The worker is killed without SIGTERM**: OOMKill (SIGKILL), `kill -9`, a container runtime
   crash, or a node crash or power loss. The job stays in `processing`. *The reaper below
   covers this.*
2. **The job takes longer than the grace period.** A job over about 20 s would be SIGKILLed
   mid-job. Real workloads need `terminationGracePeriodSeconds` sized to the longest job.
3. **Redis itself fails.** There's no persistence and no replica, so a Redis pod restart
   loses `jobs`, `processing` and `done` entirely.
4. **Network or Redis errors mid-job.** If the `MULTI/EXEC` fails (Redis unreachable), the
   worker moves on and the job stays in `processing`. The reaper re-queues it, and the job then
   runs **twice**.
5. **A poison job** that crashes the worker every time is re-queued forever by the reaper.
   There's no retry limit or dead-letter list.
6. **At-least-once, not exactly-once.** Any re-queue, whether from the reaper or an ambiguous
   failure, can process a job twice. Real job handlers must be idempotent.
7. **A worker that hangs** (alive but stuck) never gets SIGTERM from KEDA. Only the reaper helps.

## Bonus: reaper CronJob (`k8s/reaper.yaml`)

Runs every minute (`concurrencyPolicy: Forbid`), same image, ConfigMap and Secret as the worker.

- **Rule:** a job is stuck if it was in `processing` at the **previous** run as well, i.e. for at
  least 1 minute. Jobs take at most 5 s, so a healthy worker never holds one that long. The
  snapshot lives in the Redis set `reaper:seen`, so the worker didn't need per-job timestamps.
- **Re-queue is atomic** (Lua `EVAL`): it only `LPUSH`es back onto `jobs` if `LREM` actually
  removed the job from `processing`. If a worker finished it in the meantime, nothing happens.
  `LPUSH` puts recovered jobs at the head, so they run next.
- Recovery latency is 1–2 minutes (two cron runs).

**Test:** `scripts/crash-test.sh 20` (`results/reaper-crash.txt`). It SIGKILLs a busy worker's
process from its kind node, simulating an OOM or crash. The job `job-…-1` is stranded in
`processing` until the reaper re-queues it about 110 s later. A worker processes it and
`check.sh 20` → `PASS`. Reaper log: `re-queued stuck job job-…-1`.

## What I'd do with more time

- **Redis durability:** AOF persistence on a PVC, or Redis Sentinel or a managed Redis. Today a
  Redis restart loses everything.
- **A real worker** (Python/Go) with per-job start timestamps, a retry count, and a dead-letter list
  for poison jobs. Idempotent processing keyed by job ID.
- **Per-worker processing lists** (`processing:<pod>`) instead of one shared list. `LREM` on a
  shared list scans it (O(n)), and a reaper could then tell exactly whose jobs are orphaned.
- **Observability:** export `jobs`/`processing` length, oldest in-flight age, and `requeued` to
  Prometheus. Alert on stuck jobs.
- **Compare with a KEDA `ScaledJob`** (one Kubernetes Job per batch of messages). No scale-down
  problem at all, at the cost of pod start-up per job.
- **Tune scaling for production:** longer `cooldownPeriod` and stabilization windows to avoid
  flapping, and a `listLength` based on measured throughput.
- **CI:** a job that creates the kind cluster and runs `scaledown-test.sh` and `crash-test.sh` on
  every change.

## Cluster note (cgroup v1 host)

This host is RHEL 8 with **cgroup v1** and rootful podman. In a stock multi-node kind cluster,
the worker kubelets crash-loop with
`cgroup ["kubelet" "kubepods"] has some missing paths`.

**Cause:** systemd inside each kind node boots in *hybrid* mode and mounts a cgroup2 tree at
`/sys/fs/cgroup/unified`. The host doesn't use cgroup2, so every node container sits at its root
(`0::/init.scope` for all three nodes), and the nodes **share** that tree. Each node's systemd
creates and removes `/kubelet.slice/...` in the same directories, so the kubelets' cgroups
disappear. The control-plane survived, most likely because its static pods populated its cgroups
immediately.

**Fix:** `cluster/Containerfile` wraps `kindest/node:v1.31.12` and passes
`systemd.legacy_systemd_cgroup_controller=1` to `/sbin/init`. That forces pure cgroup v1 mode,
where each node's hierarchies are isolated. The alternative, switching the host to cgroup v2,
needs a kernel parameter change and a reboot.

## DNS note (offline / air-gapped hosts)

When this host lost its outside network, every `redis-cli` call from a pod took about **12–14 s**:
jobs crawled, the reaper hit its 50 s deadline, and graceful shutdown took 46 s again.

**Cause:** Kubernetes gives pods `options ndots:5`, so a name with fewer than 5 dots, like
`redis.ingest.svc.cluster.local`, is first tried with every *search suffix*. The search list
includes suffixes inherited from the host (`dns.podman`, `mshome.net`, `local`). CoreDNS forwards
those to the host's upstream DNS, which is unreachable, so each attempt waits for a timeout.
Measured in a worker pod: lookup without a trailing dot **14 018 ms**, with a trailing dot **1 ms**.

**Fix:** `REDIS_HOST: redis.ingest.svc.cluster.local.` (in `k8s/worker.yaml`). The trailing dot
makes it an absolute name, so the search list is skipped. KEDA's Go resolver showed no timeouts,
so its `address` is unchanged. Alternatives: `dnsConfig: {options: [{name: ndots, value: "2"}]}`
on the pods, or fixing CoreDNS's upstream. After the fix, `scaledown-test.sh 100 5` and
`crash-test.sh 20` both pass again.
