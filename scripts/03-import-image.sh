#!/bin/bash
# =============================================================================
# 03-import-image.sh — upload the bare-metal ISO and import it as a custom image
# =============================================================================
#   1. Uploads $BM_ISO to $IMG_BUCKET as <IMAGE_NAME>.iso (skipped if present).
#   2. Imports it as a custom image named IMAGE_NAME (launch mode NATIVE),
#      waits until it is AVAILABLE (10-30 min).
#   3. Sets the image firmware to UEFI_64 and adds the bare-metal shape to the
#      image's compatible shapes.
# Writes state/image-<IMAGE_NAME>.env with IMAGE_ID. Safe to re-run.
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
load_config
need_cmd oci
NS=$(oci_ns)

say "1/3 Upload $BM_ISO_OBJECT to bucket $IMG_BUCKET"
[ -f "$BM_ISO" ] || die "bare-metal ISO not found: $BM_ISO (run scripts/02-build-iso.sh)"
LOCAL=$(stat -c %s "$BM_ISO")
REMOTE=$(oci_q os object head --namespace "$NS" --bucket-name "$IMG_BUCKET" --name "$BM_ISO_OBJECT" --query '"content-length"') || true
if [ "$REMOTE" = "$LOCAL" ]; then
  info "already uploaded ($((LOCAL / 1024 / 1024)) MB)"
else
  info "uploading $((LOCAL / 1024 / 1024)) MB ..."
  oci os object put --namespace "$NS" --bucket-name "$IMG_BUCKET" --file "$BM_ISO" --name "$BM_ISO_OBJECT" \
    --part-size 128 --parallel-upload-count 8 --force
fi

say "2/3 Custom image $IMAGE_NAME"
IMG=$(oci_image_id)
if [ -z "$IMG" ]; then
  info "importing from $IMG_BUCKET/$BM_ISO_OBJECT ..."
  IMG=$(oci compute image import from-object --compartment-id "$COMPARTMENT_ID" --namespace "$NS" \
    --bucket-name "$IMG_BUCKET" --name "$BM_ISO_OBJECT" --display-name "$IMAGE_NAME" \
    --launch-mode NATIVE --operating-system "Nutanix CE" --query 'data.id' --raw-output)
else
  info "image exists: $IMG"
fi
while :; do
  S=$(oci_q compute image get --image-id "$IMG" --query 'data."lifecycle-state"')
  echo "    $(ts) $S"
  case $S in
    AVAILABLE) break ;;
    IMPORTING|PROVISIONING) sleep 60 ;;
    *) die "image $IMG is in state '$S'" ;;
  esac
done

say "3/3 UEFI firmware + $SHAPE compatibility"
SCHEMA=$(oci_q compute image-capability-schema list --compartment-id "$COMPARTMENT_ID" --image-id "$IMG" --query 'data[0].id') || true
if [ -z "$SCHEMA" ]; then
  GS=$(oci_q compute global-image-capability-schema list --query 'data[0].id')
  GV=$(oci_q compute global-image-capability-schema-version list --global-image-capability-schema-id "$GS" --query 'data[0].name')
  oci compute image-capability-schema create --compartment-id "$COMPARTMENT_ID" --image-id "$IMG" \
    --global-image-capability-schema-version-name "$GV" \
    --schema-data '{"Compute.Firmware":{"descriptorType":"enumstring","source":"IMAGE","defaultValue":"UEFI_64","values":["UEFI_64"]}}' >/dev/null
  info "firmware capability set to UEFI_64"
else
  info "image capability schema already present"
fi
oci compute image-shape-compatibility-entry add --image-id "$IMG" --shape-name "$SHAPE" >/dev/null 2>&1 || true
info "$SHAPE added to the compatible shapes"
cat > "$IMAGE_ENV" <<EOF
IMAGE_NAME=$IMAGE_NAME
IMAGE_ID=$IMG
EOF
info "saved $IMAGE_ENV"
echo
echo "Next: scripts/04-launch-instance.sh"
