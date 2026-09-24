#!/bin/bash
# Logs worker replicas and queue state every INTERVAL seconds as CSV.
# Usage: scripts/watch-replicas.sh [OUTFILE] [INTERVAL]   (Ctrl-C to stop)
out=${1:-/dev/stdout}; interval=${2:-5}
r="$(dirname "$0")/redis.sh"
start=$(date +%s)
echo "t_sec,desired,ready,jobs,processing,done" > "$out"
while true; do
  read -r desired ready < <(kubectl -n ingest get deploy worker \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas}')
  { read -r jobs; read -r processing; read -r done_; } < <(printf 'LLEN jobs\nLLEN processing\nGET done\n' | $r)
  echo "$(( $(date +%s) - start )),${desired:-0},${ready:-0},$jobs,$processing,${done_:-0}" >> "$out"
  sleep "$interval"
done
