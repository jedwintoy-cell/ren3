#!/bin/bash
# Logs worker replicas and queue state every INTERVAL seconds as CSV.
# Usage: scripts/watch-replicas.sh [OUTFILE] [INTERVAL]   (Ctrl-C to stop)

# Output file (default: the screen) and interval in seconds (default 5).
out=${1:-/dev/stdout}; interval=${2:-5}

# Helper that runs redis-cli inside the Redis pod.
r="$(dirname "$0")/redis.sh"

# Remember the start time, to print elapsed seconds.
start=$(date +%s)

# Write the CSV header line (">" = create/overwrite the file).
echo "t_sec,desired,ready,jobs,processing,done" > "$out"

# Forever (until Ctrl-C or kill):
while true; do
  # Ask Kubernetes for the worker Deployment's desired and ready replica counts
  # and read the two values into the variables "desired" and "ready".
  read -r desired ready < <(kubectl -n ingest get deploy worker \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas}')
  # Send 3 commands to Redis in one call and read the 3 reply lines into 3 variables.
  { read -r jobs; read -r processing; read -r done_; } < <(printf 'LLEN jobs\nLLEN processing\nGET done\n' | $r)
  # Append (">>") one CSV row; ${x:-0} prints 0 when a value is empty.
  echo "$(( $(date +%s) - start )),${desired:-0},${ready:-0},$jobs,$processing,${done_:-0}" >> "$out"
  # Wait before the next sample.
  sleep "$interval"
done
