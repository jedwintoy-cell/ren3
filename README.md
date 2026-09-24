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

## Running it

```bash
./cluster/create-cluster.sh   # build node image, create kind cluster, wait for nodes
./scripts/deploy.sh           # Redis + worker in namespace ingest
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
