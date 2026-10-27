#!/bin/bash
# =============================================================================
# ops/reapply-host-setup.sh — re-apply every OCI setting on the live AHV host
# =============================================================================
# usage: scripts/ops/reapply-host-setup.sh
# Runs scripts/remote/ahv-host-setup.sh <CVM_IP> on the host. Safe to repeat:
# it rewrites every setting, fixes SELinux labels, starts the CVM if needed
# and applies the network settings at once. Use it when validate.sh fails.
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_config
need_cmd sshpass ssh scp
load_node
scp_to_host "$REMOTE_DIR/ahv-host-setup.sh"
ssh_host "bash /root/ahv-host-setup.sh $CVM_IP"
