#!/bin/bash
# =============================================================================
# 06-finalize.sh — make the installed AHV boot from iSCSI, then reboot into it
# =============================================================================
#   1. Runs ahv-bm-finalize.sh inside the installer: iSCSI login hook in AHV's
#      initramfs, boot NIC excluded from AHV networking, br0 pinned to NIC1,
#      all OCI host settings (ahv-host-setup.sh --install-only), SELinux labels.
#   2. Backs up the finalized boot volume (BACKUP_BOOT_VOLUME=yes).
#   3. Reboots the server into AHV. The first boot logs in the volumes, defines
#      and starts the CVM and configures the network on its own.
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
load_config
need_cmd oci sshpass ssh scp
load_node
is_done install || warn "step 05 did not record a completed installation - continuing anyway"

say "1/3 Finalize AHV for iSCSI boot (ahv-bm-finalize.sh)"
if is_done finalize; then
  info "already finalized and rebooted (state marker) - nothing to do"
  echo "Next: scripts/07-create-cluster.sh"; exit 0
fi
wait_for "installer SSH ($IBFT_IP)" 300 10 ssh_ok "root@$IBFT_IP"
scp_to_installer "$REMOTE_DIR/ahv-bm-finalize.sh" "$REMOTE_DIR/ahv-host-setup.sh" "$NODE_ISCSI"
ssh_installer "cd /root && bash ahv-bm-finalize.sh $NODE_NAME.iscsi"
info "expected above: 'initramfs has ...' x4, 'hostsetup patched', 'vswitches: [{... uplinks: [<NIC1 MAC>] ...}]', 'Done. Now: reboot'"

say "2/3 Boot volume backup"
if [ "$BACKUP_BOOT_VOLUME" = yes ]; then
  BV=$(oci_q compute boot-volume-attachment list --compartment-id "$COMPARTMENT_ID" --availability-domain "$AD" \
       --instance-id "$INSTANCE_ID" --query 'data[0]."boot-volume-id"')
  [ -n "$BV" ] || die "boot volume of $INSTANCE_ID not found"
  info "backing up $BV as $NODE_NAME-finalized (a few minutes) ..."
  oci bv boot-volume-backup create --boot-volume-id "$BV" --display-name "$NODE_NAME-finalized" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output | sed 's/^/    backup: /'
else
  info "skipped (BACKUP_BOOT_VOLUME=$BACKUP_BOOT_VOLUME)"
fi

say "3/3 Reboot into AHV"
ssh_installer reboot >/dev/null 2>&1 || true
mark_done finalize
info "rebooting. On the console: 'oci-bm: ... logging in to iqn.2015-02.oracle.boot:uefi', then AHV boots and runs its first boot"
info "AHV first boot takes 15-20 minutes; nothing to do meanwhile"
echo
echo "Next: scripts/07-create-cluster.sh"
