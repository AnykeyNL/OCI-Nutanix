#!/bin/bash
# =============================================================================
# 07-create-cluster.sh — wait for AHV and the CVM, create the single-node cluster
# =============================================================================
#   1. Waits for the AHV host on HOST_IP (first boot: 15-20 min after reboot).
#   2. Runs the 30-point health check (validate-ahv-bm.sh) on the host.
#   3. Waits for the CVM to answer and for genesis to be up.
#   4. cluster create (1 node, RF1), then OCI NTP and DNS (169.254.169.254).
#   5. Final health check and summary (Prism URL).
# Safe to re-run: an existing cluster is detected and left alone.
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
load_config
need_cmd sshpass ssh scp ping
load_node

say "1/5 Waiting for AHV on $HOST_IP"
# AHV also answers on the boot NIC (IBFT_IP, routing table 100). If only that
# path works, br0 (the host IP) is not up or does not carry the VNIC MAC yet:
# OCI drops frames from any other MAC. Use the boot NIC to look and to repair.
ssh_bootnic() { ssh_pw "root@$IBFT_IP" "$@"; }
host_or_bootnic_up() { ssh_ok "root@$HOST_IP" 2>/dev/null || ssh_ok "root@$IBFT_IP"; }
wait_for "AHV host SSH ($HOST_IP, or boot NIC $IBFT_IP)" 3600 30 host_or_bootnic_up
if ! ssh_ok "root@$HOST_IP" 2>/dev/null; then
  warn "AHV answers on the boot NIC ($IBFT_IP) but not on the host IP ($HOST_IP = br0 on NIC1)"
  # let the first boot finish first (it builds br0 and defines the CVM)
  first_boot_done() { ssh_bootnic "virsh list --all --name 2>/dev/null | grep -q -- '-CVM\$' || ip link show br0 >/dev/null 2>&1"; }
  ( wait_for "AHV first boot (br0 / CVM) via the boot NIC" 1500 30 first_boot_done ) || warn "first boot still not finished after 25 min - continuing with diagnostics"
  info "state of the host, seen through the boot NIC:"
  ssh_bootnic '
    echo "--- addresses";              ip -br addr show 2>/dev/null | grep -E "br0|eth0|ahv" | sed "s/^/    /"
    echo "--- MACs: br0=$(cat /sys/class/net/br0/address 2>/dev/null)  eth0=$(cat /sys/class/net/eth0/address 2>/dev/null)  boot-nic=$(cat /etc/oci-bm-boot-nic 2>/dev/null)"
    echo "--- OVS";                    ovs-vsctl show 2>&1 | grep -E "Bridge|Port|Interface|error" | sed "s/^/    /"
    echo "--- routes";                 ip route show default 2>/dev/null | sed "s/^/    /"; ip rule show 2>/dev/null | grep 100 | sed "s/^/    /"
    echo "--- oci-cvm-net: $(systemctl is-active oci-cvm-net.timer 2>/dev/null) / last run: $(systemctl show -p Result oci-cvm-net.service 2>/dev/null)"
    echo "--- failed units";           systemctl --failed --no-legend 2>/dev/null | sed "s/^/    /"
    echo "--- CVM";                    virsh list --all 2>/dev/null | sed "s/^/    /"
  ' 2>&1 || true
  info "VNIC2 MAC expected on br0: $VNIC_MAC"
  info "re-applying the OCI host settings through the boot NIC (pins br0 to the VNIC MAC, routes, CVM path)"
  scp_pw "$REMOTE_DIR/ahv-host-setup.sh" "root@$IBFT_IP:/root/"
  ssh_bootnic "bash /root/ahv-host-setup.sh $CVM_IP" 2>&1 | sed 's/^/    /' || warn "ahv-host-setup.sh returned an error (see above)"
  wait_for "AHV host SSH ($HOST_IP)" 900 30 ssh_ok "root@$HOST_IP"
fi

say "2/5 Host health check (validate-ahv-bm.sh)"
scp_to_host "$REMOTE_DIR/validate-ahv-bm.sh" "$REMOTE_DIR/ahv-host-setup.sh"
# wait for the first boot to finish: the CVM must at least be defined
cvm_defined() { ssh_host "virsh list --all --name | grep -q -- '-CVM\$'"; }
wait_for "CVM definition on the host (first boot)" 1800 30 cvm_defined
if ssh_host "bash /root/validate-ahv-bm.sh"; then
  info "host checks passed"
else
  warn "some host checks failed. 'time synchronised' and the CVM checks are expected to fail until the cluster exists."
  warn "if anything else failed, run scripts/ops/reapply-host-setup.sh (idempotent) and re-run this step."
fi

say "3/5 Waiting for the CVM $CVM_IP"
wait_for "CVM ping" 1800 20 ping -c1 -W2 "$CVM_IP"
genesis_up() { ssh_cvm 'genesis status' | grep -q 'genesis:'; }
wait_for "genesis on the CVM" 1800 30 genesis_up

say "4/5 Cluster"
if ssh_cvm 'cluster status' 2>/dev/null | grep -q 'The state of the cluster'; then
  info "cluster already exists - skipping create"
else
  info "creating a single-node cluster (RF1) on $CVM_IP ... (a few minutes)"
  ssh_cvm "cluster -s $CVM_IP --redundancy_factor=1 create"
fi
info "NTP and DNS -> $OCI_SERVICES_IP (OCI services; pool.ntp.org is not reachable from a private subnet)"
ssh_cvm "ncli cluster add-to-ntp-servers servers=$OCI_SERVICES_IP" | sed 's/^/    /' || true
ssh_cvm "ncli cluster add-to-name-servers servers=$OCI_SERVICES_IP" | sed 's/^/    /' || true

say "5/5 Final check"
info "waiting 60 s for the services to settle ..."
sleep 60
UP=$(ssh_cvm 'cluster status' 2>/dev/null | grep -c ' UP' || true)
STATE=$(ssh_cvm 'cluster status' 2>/dev/null | grep -m1 'The state of the cluster' | sed 's/^\s*//' || true)
info "$STATE; services UP: $UP (45 when fully up)"
ssh_host "bash /root/validate-ahv-bm.sh" || warn "host checks still failing - see scripts/ops/validate.sh and docs/TROUBLESHOOTING.md"
mark_done cluster
cat <<EOF

=============================================================================
Nutanix CE is running on OCI bare metal.

  AHV host   : ssh root@$HOST_IP        (password: CE default)
  CVM        : ssh nutanix@$CVM_IP      (password: CE default)
  Prism      : https://$CVM_IP:9440     user admin, CE default password; change it at
               first login and complete the Nutanix NEXT account registration
  Health     : scripts/ops/validate.sh
  Power      : scripts/ops/power.sh  (never use OCI soft Stop/Reboot - see docs/OPERATIONS.md)
=============================================================================
EOF
