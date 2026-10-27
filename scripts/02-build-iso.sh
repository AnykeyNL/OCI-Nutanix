#!/bin/bash
# =============================================================================
# 02-build-iso.sh — build the bare-metal edition of the CE ISO
# =============================================================================
# Runs scripts/build/remaster-ce-iso-bm.sh on the downloaded stock ISO. The
# result ($WORK_DIR/<IMAGE_NAME>.iso) is the stock ISO plus iSCSI boot support
# in the installer's initrd; nothing is removed or replaced.
# Takes 10-20 minutes (kernel source download + module build). Skipped when the
# output already exists; pass --force to rebuild.
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
need_root
load_config
FORCE=no; [ "${1:-}" = --force ] && FORCE=yes

say "Bare-metal ISO: $BM_ISO"
[ -f "$SRC_ISO" ] || die "stock ISO not found: $SRC_ISO (run scripts/01-fetch-iso.sh)"
if [ -f "$BM_ISO" ] && [ $FORCE = no ]; then
  info "already built: $BM_ISO  (use --force to rebuild)"
else
  export REMASTER_WORK="$WORK_DIR/remaster"
  bash "$SCRIPTS_DIR/build/remaster-ce-iso-bm.sh" build "$SRC_ISO" "$BM_ISO"
fi
ls -lh "$BM_ISO" | sed 's/^/    /'
echo
echo "Next: scripts/03-import-image.sh"
