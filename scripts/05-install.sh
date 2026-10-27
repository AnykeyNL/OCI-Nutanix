#!/bin/bash
# =============================================================================
# 05-install.sh — prepare the CE installer and run it
# =============================================================================
#   1. Waits until the installer (booted over iSCSI by the bare-metal ISO) is
#      reachable over SSH on the primary VNIC IP (IBFT_IP).
#   2. Stops the auto-started installer UI (screen session).
#   3. Copies the on-node scripts and runs ce-bm-prep.sh: logs in the two
#      block volumes and adapts the installer in RAM for iSCSI disks.
#   4. Opens the Nutanix installer (./phoenix). This is the ONLY interactive
#      step of the whole procedure: the installer's text UI has no unattended
#      mode. The values to enter are printed first.
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
load_config
need_cmd oci sshpass ssh scp
load_node

say "1/4 Waiting for the CE installer's SSH on $IBFT_IP"
info "a fresh bare-metal server takes 10-15 min to boot; the installer logs in to its boot volume and enables SSH by itself"
wait_for "installer SSH ($IBFT_IP)" 3600 30 ssh_ok "root@$IBFT_IP"

say "2/4 Stop the auto-started installer UI"
# logging in over SSH would otherwise attach to that screen session
ssh_installer 'screen -S centos_phoenix -X quit' >/dev/null 2>&1 || true
info "screen session stopped"

say "3/4 Prepare the installer (ce-bm-prep.sh)"
scp_to_installer "$REMOTE_DIR/ce-bm-prep.sh" "$REMOTE_DIR/ahv-bm-finalize.sh" "$REMOTE_DIR/ahv-host-setup.sh" "$NODE_ISCSI"
# idempotent: on a re-run the volume logins, patches and the ISO copy are skipped
ssh_installer "cd /root && bash ce-bm-prep.sh $NODE_NAME.iscsi"
info "expected above: sda ${BOOT_VOLUME_GB}G, sdb ${CVM_VOLUME_GB}G, sdc ${DATA_VOLUME_GB}G (TRAN=iscsi); patches 5/1/1; HYP= and NOS= found"

say "4/4 Run the Nutanix installer (interactive)"
if is_done install; then
  info "installer already completed for $NODE_NAME (state marker); skipping"
else
  cat <<EOF

    The Nutanix installer opens in this terminal. Enter exactly these values:

      Hypervisor boot (H) : sda   (boot volume, ${BOOT_VOLUME_GB} GB shown as ~$((BOOT_VOLUME_GB * 1073 / 1000)) GB)
      CVM boot (C)        : sdb   (${CVM_VOLUME_GB} GB)  - move to it and press  c
      Data (D)            : sdc   (${DATA_VOLUME_GB} GB)  - move to it and press  d
      Host IP             : $HOST_IP      (NOT $IBFT_IP, that is the iSCSI NIC)
      CVM IP              : $CVM_IP
      Subnet mask         : $NETMASK
      Gateway             : $GATEWAY
      Create single-node cluster? : leave unticked (the cluster is created in step 07)

    Accept the EULA (scroll to the end), start. About 15 minutes.
    It ends with "Imaging process completed successfully!".
    Answer  N  to the reboot question  - do NOT reboot; step 06 finalizes AHV first.

EOF
  read -r -p "    Press Enter to open the installer ... "
  sshpass -p "$CE_PASSWORD" ssh -t $SSHO "root@$IBFT_IP" 'export COMMUNITY_EDITION=1; cd /root/phoenix; ./phoenix' || true
  echo
  if ssh_installer 'lvm vgs --noheadings -o vg_name 2>/dev/null | grep -qw ahv'; then
    info "AHV volume group found on sda: the installation looks complete"
  else
    warn "no AHV volume group on sda yet - the installer may not have finished"
  fi
  if confirm "    Did the installer end with 'Imaging process completed successfully!' and did you answer N?"; then
    mark_done install
  else
    die "re-run scripts/05-install.sh to start the installer again (the prep is kept)"
  fi
fi
echo
echo "Next: scripts/06-finalize.sh"
