#!/bin/bash
# =============================================================================
# ops/cluster.sh — cluster status / start / stop from the admin host
# =============================================================================
# usage: scripts/ops/cluster.sh status|start|stop|hosts
#   status  cluster status (summary: state and services UP/DOWN)
#   start   cluster start (needed after a planned reboot/power-off done with
#           power.sh --stop-cluster)
#   stop    cluster stop (interactive: type "I agree" when asked)
#   hosts   acli host.list
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_config
need_cmd sshpass ssh
load_node
case ${1:-} in
  status)
    OUT=$(ssh_cvm 'cluster status' 2>&1) || true
    echo "$OUT" | grep -E 'The state of the cluster|Cluster is currently' | sed 's/^\s*//'
    echo "services UP: $(echo "$OUT" | grep -c ' UP')   DOWN: $(echo "$OUT" | grep -c ' DOWN')"
    echo "$OUT" | grep ' DOWN' | sed 's/^/    /' || true
    ;;
  start) ssh_cvm 'cluster start' ;;
  stop)  ssh_cvm_tty 'cluster stop' ;;
  hosts) ssh_cvm 'acli host.list' ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
