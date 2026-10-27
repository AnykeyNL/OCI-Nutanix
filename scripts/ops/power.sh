#!/bin/bash
# =============================================================================
# ops/power.sh — clean reboot, power-off and power-on of the Nutanix node
# =============================================================================
# usage: scripts/ops/power.sh status|reboot|shutdown|start|reset|hardstop [--stop-cluster] [--force]
#
#   status      OCI instance state, host/CVM reachability, cluster summary
#   reboot      clean reboot: cvm_shutdown -P now on the CVM, wait until it is
#               off, reboot the AHV host, wait until host, CVM and cluster are
#               back (about 15 min). The cluster restarts by itself.
#   shutdown    clean power-off: as reboot, but "shutdown -h now"; waits until
#               OCI reports STOPPED. Use this BEFORE stopping the instance.
#   start       OCI START, wait for AHV, the CVM and the cluster (about 20 min)
#   reset       OCI hard RESET (immediate, like a reset button). Needs --force.
#   hardstop    OCI hard STOP (immediate power-off). Needs --force.
#
#   --stop-cluster  (reboot/shutdown) run "cluster stop" first (interactive:
#                   type "I agree") and "cluster start" when the node is back.
#                   Not needed on a single-node cluster; see docs/OPERATIONS.md.
#
# Never use the OCI console "Stop"/"Reboot" without Force on this node: AHV
# ignores the ACPI power button by design, OCI waits about 15 minutes and then
# cuts the power with the CVM still running (docs/OPERATIONS.md, S5/S6).
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_config
need_cmd oci sshpass ssh ping
load_node
ACTION=${1:-}; shift || true
STOP_CLUSTER=no; FORCE=no
for a in "$@"; do case $a in --stop-cluster) STOP_CLUSTER=yes ;; --force) FORCE=yes ;; *) die "unknown option $a" ;; esac; done
STOPPED_MARK=$STATE_DIR/$NODE_NAME.cluster-stopped

cvm_name()  { ssh_host "virsh list --all --name | grep -- '-CVM\$'" 2>/dev/null; }
cvm_off()   { ssh_host "virsh domstate $(cvm_name)" 2>/dev/null | grep -q 'shut off'; }
host_down() { ! ping -c1 -W2 "$HOST_IP" >/dev/null 2>&1; }
host_up()   { ssh_ok "root@$HOST_IP"; }
cvm_up()    { ssh_cvm 'genesis status' 2>/dev/null | grep -q 'genesis:'; }
oci_state_is() { [ "$(oci_instance_state "$INSTANCE_ID")" = "$1" ]; }

status() {
  say "Status of $NODE_NAME"
  info "OCI instance: $(oci_instance_state "$INSTANCE_ID")"
  if ping -c1 -W2 "$HOST_IP" >/dev/null 2>&1; then
    info "AHV host $HOST_IP: up"
    C=$(cvm_name); [ -n "$C" ] && info "CVM $C: $(ssh_host "virsh domstate $C" 2>/dev/null)"
  else
    info "AHV host $HOST_IP: not reachable"
  fi
  if ping -c1 -W2 "$CVM_IP" >/dev/null 2>&1; then
    OUT=$(ssh_cvm 'cluster status' 2>/dev/null) || true
    info "CVM $CVM_IP: up; $(echo "$OUT" | grep -m1 -E 'The state of the cluster|Cluster is currently' | sed 's/^\s*//'); services UP: $(echo "$OUT" | grep -c ' UP')  DOWN: $(echo "$OUT" | grep -c ' DOWN')"
  else
    info "CVM $CVM_IP: not reachable"
  fi
  [ -f "$STOPPED_MARK" ] && warn "cluster was stopped by power.sh --stop-cluster; run: scripts/ops/cluster.sh start"
}

shutdown_cvm() {
  if [ $STOP_CLUSTER = yes ]; then
    say "cluster stop (type 'I agree' when asked)"
    ssh_cvm_tty 'cluster stop' && touch "$STOPPED_MARK"
  fi
  say "Shutting down the CVM cleanly (cvm_shutdown -P now)"
  if cvm_off; then info "CVM already off"; return; fi
  ssh_cvm 'cvm_shutdown -P now' || warn "cvm_shutdown returned an error (the CVM may already be going down)"
  wait_for "CVM shut off" 600 10 cvm_off
}

come_back() {
  say "Waiting for the node to come back"
  wait_for "AHV host SSH" 2400 30 host_up
  wait_for "CVM genesis" 1800 30 cvm_up
  if [ -f "$STOPPED_MARK" ]; then
    say "cluster start"
    ssh_cvm 'cluster start' && rm -f "$STOPPED_MARK"
  fi
  info "the cluster needs 2-20 min for all services to be UP; check with scripts/ops/cluster.sh status"
  status
}

case $ACTION in
  status) status ;;
  reboot)
    shutdown_cvm
    say "Rebooting the AHV host"
    ssh_host reboot >/dev/null 2>&1 || true
    wait_for "host to go down" 600 10 host_down
    come_back ;;
  shutdown)
    shutdown_cvm
    say "Powering off the AHV host (shutdown -h now)"
    ssh_host 'shutdown -h now' >/dev/null 2>&1 || true
    wait_for "host to go down" 600 10 host_down
    wait_for "OCI state STOPPED" 1200 30 oci_state_is STOPPED
    info "instance is STOPPED. Power on with: scripts/ops/power.sh start" ;;
  start)
    say "OCI START"
    oci compute instance action --instance-id "$INSTANCE_ID" --action START --wait-for-state RUNNING >/dev/null
    info "instance RUNNING; bare-metal POST + AHV boot takes 5-8 min, the CVM 3-5 min more"
    come_back ;;
  reset|hardstop)
    [ $FORCE = yes ] || die "$ACTION cuts the power with the CVM running (like a crash). Only for a hung host; add --force"
    A=RESET; [ $ACTION = hardstop ] && A=STOP
    say "OCI $A (hard)"
    oci compute instance action --instance-id "$INSTANCE_ID" --action $A >/dev/null
    [ $A = RESET ] && come_back || info "instance stopping. Power on with: scripts/ops/power.sh start" ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
