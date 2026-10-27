#!/bin/bash
# =============================================================================
# 04-launch-instance.sh — create the OCI bare-metal instance for the CE node
# =============================================================================
# (from oci-ce-bm.sh in the reference document)
#   1. Launches NODE_NAME (SHAPE) from the custom image with a BOOT_VOLUME_GB
#      boot volume. The boot volume first holds the installer and later AHV
#      itself; on bare metal the firmware reaches it over iSCSI.
#   2. Creates the CVM and data block volumes and attaches them as iSCSI (the
#      only attachment type on bare metal); records IQN/IP/port for the installer.
#   3. Adds a second VNIC on physical NIC1 with a secondary IP:
#        primary VNIC (NIC0) = iSCSI only, kept out of OVS
#        VNIC2 (NIC1)        = AHV host IP on br0 + CVM IP (secondary)
#   4. Writes state/<NODE_NAME>.env and state/<NODE_NAME>.iscsi.
#   5. Optionally creates a console connection (CONSOLE_SSH_PUBKEY_FILE).
# Bare-metal provisioning takes 10-15 minutes. Re-running with an existing
# node state is refused unless the instance is gone (use ops/destroy.sh).
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
load_config
need_cmd oci
AD=$(oci_ad)

if [ -f "$NODE_ENV" ]; then
  # shellcheck disable=SC1090
  . "$NODE_ENV"
  ST=$(oci_instance_state "$INSTANCE_ID") || true
  case $ST in
    ""|TERMINATED|TERMINATING) warn "previous instance $INSTANCE_ID is $ST; starting over"; rm -f "$NODE_ENV" "$NODE_ISCSI" "$STATE_DIR/$NODE_NAME".*.done ;;
    *) info "node $NODE_NAME already exists ($INSTANCE_ID, $ST) - nothing to do"; echo "Next: scripts/05-install.sh"; exit 0 ;;
  esac
fi

say "Image and network"
IMAGE_ID=$(oci_image_id)
[ -n "$IMAGE_ID" ] || die "custom image '$IMAGE_NAME' not found (run scripts/03-import-image.sh)"
info "image:  $IMAGE_ID"
info "subnet: $SUBNET_ID"
info "AD:     $AD"
oci compute image-shape-compatibility-entry add --image-id "$IMAGE_ID" --shape-name "$SHAPE" >/dev/null 2>&1 || true

say "Launching $NODE_NAME ($SHAPE) - bare metal takes 10-15 min"
INSTANCE_ID=$(oci compute instance launch \
  --compartment-id "$COMPARTMENT_ID" --availability-domain "$AD" \
  --display-name "$NODE_NAME" --shape "$SHAPE" \
  --subnet-id "$SUBNET_ID" --assign-public-ip false \
  --image-id "$IMAGE_ID" --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
  --wait-for-state RUNNING --max-wait-seconds 3600 --query 'data.id' --raw-output)
info "instance: $INSTANCE_ID"
# save early, so a failure below can be cleaned up with ops/destroy.sh
cat > "$NODE_ENV" <<EOF
NAME=$NODE_NAME
INSTANCE_ID=$INSTANCE_ID
AD=$AD
EOF

say "Block volumes (iSCSI)"
: > "$NODE_ISCSI"
VOL_IDS=()
create_and_attach () {   # $1 = role, $2 = size GB
  local VOL_ID
  VOL_ID=$(oci bv volume create \
    --compartment-id "$COMPARTMENT_ID" --availability-domain "$AD" \
    --display-name "$NODE_NAME-$1" --size-in-gbs "$2" --vpus-per-gb "$VOLUME_VPUS_PER_GB" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  info "volume $1 ($2 GB): $VOL_ID"
  oci compute volume-attachment attach \
    --instance-id "$INSTANCE_ID" --volume-id "$VOL_ID" \
    --type iscsi --wait-for-state ATTACHED \
    --query 'data.[iqn,ipv4,port]' --raw-output | tr -d '[]", ' | paste -sd' ' >> "$NODE_ISCSI"
  info "attached $1 (iSCSI)"
  VOL_IDS+=("$VOL_ID")
}
create_and_attach cvm "$CVM_VOLUME_GB"
create_and_attach data "$DATA_VOLUME_GB"

say "Second VNIC on NIC1 (host + CVM IPs for br0)"
# with --wait, attach-vnic returns the VNIC itself (not the attachment)
VNIC2_ID=$(oci compute instance attach-vnic --instance-id "$INSTANCE_ID" \
  --subnet-id "$SUBNET_ID" --nic-index 1 --vnic-display-name "$NODE_NAME-br0" \
  --assign-public-ip false --wait --query 'data.id' --raw-output)
oci network vnic assign-private-ip --vnic-id "$VNIC2_ID" --display-name "$NODE_NAME-cvm" >/dev/null
VNIC1_ID=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
  --query 'data[?"is-primary"]|[0].id' --raw-output)
IBFT_IP=$(oci network vnic get --vnic-id "$VNIC1_ID" --query 'data."private-ip"' --raw-output)
IBFT_MAC=$(oci network vnic get --vnic-id "$VNIC1_ID" --query 'data."mac-address"' --raw-output)
HOST_IP=$(oci network private-ip list --vnic-id "$VNIC2_ID" --query 'data[?"is-primary"]."ip-address" | [0]' --raw-output)
CVM_IP=$(oci network private-ip list --vnic-id "$VNIC2_ID" --query 'data[?!"is-primary"]."ip-address" | [0]' --raw-output)
VNIC_MAC=$(oci network vnic get --vnic-id "$VNIC2_ID" --query 'data."mac-address"' --raw-output)
SUBNET_CIDR=$(oci network subnet get --subnet-id "$SUBNET_ID" --query 'data."cidr-block"' --raw-output)
GATEWAY=$(oci network subnet get --subnet-id "$SUBNET_ID" --query 'data."virtual-router-ip"' --raw-output)
NETMASK=$(cidr_netmask "$SUBNET_CIDR")

cat > "$NODE_ENV" <<EOF
NAME=$NODE_NAME
INSTANCE_ID=$INSTANCE_ID
AD=$AD
IMAGE_ID=$IMAGE_ID
CVM_VOLUME_ID=${VOL_IDS[0]}
DATA_VOLUME_ID=${VOL_IDS[1]}
VNIC1_ID=$VNIC1_ID
VNIC2_ID=$VNIC2_ID
IBFT_IP=$IBFT_IP
IBFT_MAC=$IBFT_MAC
HOST_IP=$HOST_IP
CVM_IP=$CVM_IP
VNIC_MAC=$VNIC_MAC
SUBNET_CIDR=$SUBNET_CIDR
NETMASK=$NETMASK
GATEWAY=$GATEWAY
EOF

if [ -n "$CONSOLE_SSH_PUBKEY_FILE" ] && [ -f "$CONSOLE_SSH_PUBKEY_FILE" ]; then
  say "Console connection (VNC)"
  CC=$(oci compute instance-console-connection create --instance-id "$INSTANCE_ID" \
      --ssh-public-key-file "$CONSOLE_SSH_PUBKEY_FILE" --wait-for-state ACTIVE --query 'data.id' --raw-output) || true
  if [ -n "$CC" ]; then
    echo "CONSOLE_CONNECTION_ID=$CC" >> "$NODE_ENV"
    info "VNC connection string:"
    oci compute instance-console-connection get --instance-console-connection-id "$CC" \
      --query 'data."vnc-connection-string"' --raw-output | sed 's/^/       /'
  fi
fi

echo
echo "Done. Values saved to $NODE_ENV:"
sed 's/^/    /' "$NODE_ENV"
echo "iSCSI volumes ($NODE_ISCSI: iqn ip port):"; sed 's/^/    /' "$NODE_ISCSI"
echo
echo "The server now boots the CE installer over iSCSI (no input needed)."
echo "Next: scripts/05-install.sh"
