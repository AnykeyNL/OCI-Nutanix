#!/bin/bash
# =============================================================================
# ops/ssh.sh — open a shell on the installer, the AHV host or the CVM
# =============================================================================
# usage: scripts/ops/ssh.sh installer|host|cvm [command]
#   installer  root@IBFT_IP  (only while the CE installer is running)
#   host       root@HOST_IP  (AHV)
#   cvm        nutanix@CVM_IP (login shell, so cluster/ncli/acli work)
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_config
need_cmd sshpass ssh
load_node
T=${1:-}; shift || true
case $T in
  installer) exec sshpass -p "$CE_PASSWORD" ssh -t $SSHO "root@$IBFT_IP" "$@" ;;
  host)      exec sshpass -p "$CE_PASSWORD" ssh -t $SSHO "root@$HOST_IP" "$@" ;;
  cvm)       if [ $# -gt 0 ]; then exec ssh_cvm_tty "$@"; else exec sshpass -p "$CE_PASSWORD" ssh -t $SSHO "nutanix@$CVM_IP"; fi ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
