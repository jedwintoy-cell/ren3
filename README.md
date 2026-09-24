# redis-worker-scaling

A Redis-backed job queue on Kubernetes. Workers pop job IDs from a Redis list, and
KEDA scales them from 0 to N based on queue depth (Part 2). They also must not
lose jobs when scaled down (Part 3).

```
produce.sh ──RPUSH──▶ Redis list "jobs" ──BLMOVE──▶ "processing" ──LREM + INCR done──▶ finished
                         (ns: ingest)                 worker pods (bash + redis-cli)
```

## Layout

| Path | Purpose |
|---|---|
| `kind-config.yaml` | 1 control-plane + 2 workers |
| `cluster/Containerfile`, `cluster/create-cluster.sh` | Patched kind node image + cluster creation (see "Cluster note") |
| `k8s/00-namespace.yaml` | Namespace `ingest` |
| `k8s/redis.yaml` | Redis 7 Deployment (password, readiness probe, limits) + Service |
| `k8s/worker.yaml` | Worker ConfigMap (`REDIS_HOST`), script ConfigMap, Deployment |
| `scripts/deploy.sh` | Creates the password Secret (random, not in git) and applies manifests |
| `scripts/produce.sh N` | Resets counters and pushes N unique job IDs onto `jobs` |
| `scripts/check.sh N` | Passes when `done == N` and `jobs` / `processing` are empty |
| `scripts/redis.sh CMD…` | Runs `redis-cli` inside the Redis pod |
| `k8s/keda.yaml` | KEDA TriggerAuthentication + ScaledObject |
| `scripts/install-keda.sh` | Installs KEDA 2.21.0 via Helm |
| `scripts/watch-replicas.sh [FILE]` | Logs replicas and queue state every 5 s as CSV |
| `results/` | Recorded run data |

## Running it

```bash
./cluster/create-cluster.sh   # build node image, create kind cluster, wait for nodes
./scripts/install-keda.sh     # KEDA from its Helm chart
./scripts/deploy.sh           # Redis, worker, KEDA ScaledObject in namespace ingest
./scripts/produce.sh 20       # push 20 jobs
./scripts/check.sh 20         # once idle: PASS
```

## Part 1: Deploy

- **Redis** runs `redis:7` with `--requirepass $(REDIS_PASSWORD)`. Kubernetes expands the
  password from the `redis-auth` Secret. A `Service` named `redis` gives it a stable DNS name.
  Persistence is off (`--save ""`, no AOF), so if the Redis pod restarts, the queue is lost.
  That's a deliberate simplification for this demo.
- **Readiness probe** on Redis runs an authenticated `redis-cli ping`. This checks that Redis
  is actually serving and that authentication works, not just that the port is open.
- **Worker** is the bash stub from the case, mounted from a ConfigMap into the stock `redis:7`
  image, which already has bash and `redis-cli`, so no image build is needed. `REDIS_HOST` comes from
  the `worker-config` ConfigMap and `REDIS_PASSWORD` from the Secret.
- **Resources:** every container has requests and limits. They're kept small (worker 10m/16Mi
  request) so 10 workers fit on a laptop-sized kind cluster.

**Result:** 20 jobs with 1 worker drained in about 65 s (average 3.5 s per job, as expected), and `check.sh 20` → `PASS`.

## Part 2: Autoscale with KEDA

KEDA 2.21.0 is installed from the official chart (`scripts/install-keda.sh`). `k8s/keda.yaml` contains:

- **TriggerAuthentication `redis-auth`** reads the password from the same `redis-auth` Secret
  the worker uses, so the ScaledObject never contains the password.
- **ScaledObject `worker`**: 0 to 10 replicas, `pollingInterval: 5`, `cooldownPeriod: 30`, HPA
  scale-down stabilization reduced from 300 s to 30 s so scale-down is visible in the demo. Two
  `redis` list triggers (the HPA uses the **max** of the two):
  - `jobs`, `listLength: 5`: the backlog, one worker per 5 queued jobs.
  - `processing`, `listLength: 1`: in-flight work. It keeps at least one replica per job being
    worked on, so KEDA doesn't scale to 0 while a worker is mid-job.

The worker Deployment has **no `replicas` field**, because KEDA owns the replica count.
Re-applying the manifest won't reset it.

### 200 jobs: replicas over time (`results/part2-200-jobs.csv`)

| t (s) | replicas | jobs | processing | done |
|---:|---:|---:|---:|---:|
| 5 | 0 | 0 | 0 | 0 |
| 11 | **1** | 199 | 1 | 0 |
| 16 | **5** | 194 | 5 | 1 |
| 31 | **10** | 168 | 10 | 22 |
| 57 | 10 | 91 | 10 | 99 |
| 87 | 10 | 3 | 10 | 187 |
| 97 | 10 | 0 | 0 | 200 |
| 123 | **0** | 0 | 0 | 200 |

The 200 jobs finished in about 90 s, versus about 700 s for 1 worker. `check.sh 200` → `PASS`.

### How the worker gets from 0 → 1 and from 1 → N

- **0 → 1: the KEDA operator.** A standard HPA can't scale from 0, because with no pods there's
  nothing to measure and its minimum is 1. So the KEDA operator polls Redis itself every
  `pollingInterval` (5 s). When a trigger becomes *active* (`LLEN jobs` > `activationListLength`,
  default 0), the operator sets the Deployment's replicas to 1. Operator log:
  `Successfully updated ScaleTarget … Original Replicas Count: 0, New Replicas Count: 1`.
- **1 → N: the HPA that KEDA creates** (`keda-hpa-worker`, minimum 1, maximum 10). KEDA's metrics
  API server exposes each list length as an *external metric* (`s0-redis-jobs`,
  `s1-redis-processing`). The HPA computes `desired = ceil(metric / listLength)` for each trigger
  and takes the maximum. For 200 jobs that's 40, capped at 10. The HPA's default scale-up policy
  (at most +4 pods or +100% per 15 s, whichever is larger) explains the steps
  **1 → 5 → 10** (HPA events: `New size: 5`, then `New size: 10`).
- **N → 0: KEDA again.** Once both triggers have been inactive (both lists empty) for
  `cooldownPeriod` (30 s), the operator sets replicas to 0. With the `processing` trigger, this
  happened only after the last job finished (processing = 0 at t=97, scaled to 0 at t=123).

## Cluster note (cgroup v1 host)

This host is RHEL 8 with **cgroup v1** and rootful podman. In a stock multi-node kind cluster,
the worker kubelets crash-loop:
`cgroup ["kubelet" "kubepods"] has some missing paths`.

**Cause:** systemd inside each kind node boots in *hybrid* mode and mounts a cgroup2 tree at
`/sys/fs/cgroup/unified`. On a v1 host, every node container sits at the same spot in that
tree (`0::/init.scope`), so all nodes **share** it. Each node's systemd creates and deletes
`/kubelet.slice/...` there and removes the others' cgroups. The control-plane happens to win.

**Fix:** `cluster/Containerfile` wraps `kindest/node:v1.31.12` and passes
`systemd.legacy_systemd_cgroup_controller=1` to `/sbin/init`. That forces pure cgroup v1 mode,
where each node's hierarchies are properly isolated. The alternative, switching the host to
cgroup v2, needs a kernel parameter change and a reboot.
