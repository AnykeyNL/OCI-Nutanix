#!/bin/bash
# =============================================================================
# ops/destroy.sh — terminate the node and delete its volumes (lab cleanup)
# =============================================================================
# usage: scripts/ops/destroy.sh --yes [--keep-image] [--keep-backups]
# Deletes: the instance (with its boot volume), the CVM and data block volumes,
# the console connection, the node state files. Keeps the custom image and the
# boot-volume backups unless told otherwise. THIS DESTROYS THE CLUSTER AND ALL
# DATA ON IT.
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_config
need_cmd oci
load_node
YES=no; KEEP_IMAGE=yes; KEEP_BACKUPS=yes
for a in "$@"; do
  case $a in
    --yes) YES=yes ;;
    --keep-image) KEEP_IMAGE=yes ;;
    --delete-image) KEEP_IMAGE=no ;;
    --keep-backups) KEEP_BACKUPS=yes ;;
    --delete-backups) KEEP_BACKUPS=no ;;
    *) die "unknown option $a" ;;
  esac
done
say "About to destroy $NODE_NAME"
info "instance:     $INSTANCE_ID ($(oci_instance_state "$INSTANCE_ID"))"
info "CVM volume:   ${CVM_VOLUME_ID:-?}"
info "data volume:  ${DATA_VOLUME_ID:-?}"
info "image:        $( [ $KEEP_IMAGE = yes ] && echo kept || echo "DELETED (${IMAGE_ID:-?})")"
info "backups:      $( [ $KEEP_BACKUPS = yes ] && echo kept || echo DELETED)"
[ $YES = yes ] || { echo; echo "Add --yes to proceed. All data on the cluster will be lost."; exit 1; }
confirm "    Really destroy $NODE_NAME and its volumes?" || exit 1

if [ -n "${CONSOLE_CONNECTION_ID:-}" ]; then
  oci compute instance-console-connection delete --instance-console-connection-id "$CONSOLE_CONNECTION_ID" --force >/dev/null 2>&1 || true
fi
say "Terminating the instance (boot volume deleted with it)"
oci compute instance terminate --instance-id "$INSTANCE_ID" --preserve-boot-volume false --force \
  --wait-for-state TERMINATED >/dev/null 2>&1 || warn "terminate returned an error (already gone?)"
say "Deleting block volumes"
for V in "${CVM_VOLUME_ID:-}" "${DATA_VOLUME_ID:-}"; do
  [ -n "$V" ] || continue
  oci bv volume delete --volume-id "$V" --force --wait-for-state TERMINATED >/dev/null 2>&1 && info "deleted $V" || warn "could not delete $V"
done
if [ $KEEP_BACKUPS = no ]; then
  say "Deleting boot-volume backups named $NODE_NAME-*"
  for B in $(oci bv boot-volume-backup list --compartment-id "$COMPARTMENT_ID" --display-name "$NODE_NAME-finalized" --all 2>/dev/null | jq -r '.data[].id'); do
    oci bv boot-volume-backup delete --boot-volume-backup-id "$B" --force >/dev/null 2>&1 && info "deleted backup $B"
  done
fi
if [ $KEEP_IMAGE = no ] && [ -n "${IMAGE_ID:-}" ]; then
  say "Deleting the custom image $IMAGE_ID"
  oci compute image delete --image-id "$IMAGE_ID" --force >/dev/null 2>&1 && info "deleted" || warn "could not delete the image"
  rm -f "$IMAGE_ENV"
fi
say "State files"
rm -f "$NODE_ENV" "$NODE_ISCSI" "$STATE_DIR/$NODE_NAME".*.done "$STATE_DIR/$NODE_NAME.cluster-stopped"
info "removed state for $NODE_NAME"
echo
echo "Done."
