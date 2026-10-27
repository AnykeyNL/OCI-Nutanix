#!/bin/bash
# =============================================================================
# ops/validate.sh — run the read-only health check on the AHV host
# =============================================================================
# usage: scripts/ops/validate.sh
# Copies scripts/remote/validate-ahv-bm.sh to the host and runs it (30 checks,
# exit code = number of failures). Run it after every power event.
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_config
need_cmd sshpass ssh scp
load_node
scp_to_host "$REMOTE_DIR/validate-ahv-bm.sh" || die "cannot reach the AHV host at $HOST_IP"
ssh_host "bash /root/validate-ahv-bm.sh"
