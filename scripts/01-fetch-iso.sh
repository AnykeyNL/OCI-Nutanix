#!/bin/bash
# =============================================================================
# 01-fetch-iso.sh — download the stock Nutanix CE ISO from Object Storage
# =============================================================================
# Reads SRC_BUCKET / SRC_ISO_OBJECT from the config and downloads the ISO into
# WORK_DIR. Skipped when a file of the same size is already there.
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
load_config
need_cmd oci

say "Stock CE ISO: $SRC_BUCKET/$SRC_ISO_OBJECT"
NS=$(oci_ns)
SIZE=$(oci_q os object head --namespace "$NS" --bucket-name "$SRC_BUCKET" --name "$SRC_ISO_OBJECT" --query '"content-length"') || true
[ -n "$SIZE" ] || die "object '$SRC_ISO_OBJECT' not found in bucket '$SRC_BUCKET'"
info "size in bucket: $((SIZE / 1024 / 1024)) MB"
if [ -f "$SRC_ISO" ] && [ "$(stat -c %s "$SRC_ISO")" = "$SIZE" ]; then
  info "already downloaded: $SRC_ISO"
else
  info "downloading to $SRC_ISO ..."
  oci os object get --namespace "$NS" --bucket-name "$SRC_BUCKET" --name "$SRC_ISO_OBJECT" \
    --file "$SRC_ISO.part" --multipart-download-threshold 128 --part-size 128 --parallel-download-count 8
  [ "$(stat -c %s "$SRC_ISO.part")" = "$SIZE" ] || die "download incomplete ($(stat -c %s "$SRC_ISO.part") of $SIZE bytes)"
  mv -f "$SRC_ISO.part" "$SRC_ISO"
  info "done"
fi
ls -lh "$SRC_ISO" | sed 's/^/    /'
echo
echo "Next: scripts/02-build-iso.sh"
