#!/bin/bash
# =============================================================================
# common.sh — shared helpers for the OCI-Nutanix admin-host scripts
# =============================================================================
# Source it, do not run it:   . "$(dirname "$0")/lib/common.sh"
# Provides: logging, config loading, OCI lookups, node state, SSH helpers.
# =============================================================================
[ -n "${_OCI_NUTANIX_COMMON:-}" ] && return 0
_OCI_NUTANIX_COMMON=1

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPTS_DIR=$REPO_ROOT/scripts
REMOTE_DIR=$SCRIPTS_DIR/remote
CONFIG_FILE=${OCI_NUTANIX_CONFIG:-$REPO_ROOT/config/oci-nutanix.env}
STATE_DIR=${OCI_NUTANIX_STATE:-$REPO_ROOT/state}

# ---------- output ----------
say()  { echo; echo "=== $* ==="; }
info() { echo "    -> $*"; }
warn() { echo "    !! $*" >&2; }
die()  { echo; echo "ERROR: $*" >&2; exit 1; }
ts()   { date +%H:%M:%S; }

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c (run scripts/00-prereqs.sh)"
  done
}
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }

# ---------- configuration ----------
load_config() {
  [ -f "$CONFIG_FILE" ] || die "config not found: $CONFIG_FILE
  cp config/oci-nutanix.env.example config/oci-nutanix.env  and edit it"
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  set +a
  : "${COMPARTMENT_ID:?set COMPARTMENT_ID in $CONFIG_FILE}"
  : "${SUBNET_ID:?set SUBNET_ID in $CONFIG_FILE}"
  : "${SRC_BUCKET:?set SRC_BUCKET in $CONFIG_FILE}"
  SRC_ISO_OBJECT=${SRC_ISO_OBJECT:-phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso}
  IMG_BUCKET=${IMG_BUCKET:-$SRC_BUCKET}
  IMAGE_NAME=${IMAGE_NAME:-nutanix-ce-ocibm-v1}
  NODE_NAME=${NODE_NAME:-ce-bm-01}
  SHAPE=${SHAPE:-BM.Standard3.64}
  BOOT_VOLUME_GB=${BOOT_VOLUME_GB:-100}
  CVM_VOLUME_GB=${CVM_VOLUME_GB:-400}
  DATA_VOLUME_GB=${DATA_VOLUME_GB:-600}
  VOLUME_VPUS_PER_GB=${VOLUME_VPUS_PER_GB:-30}
  BACKUP_BOOT_VOLUME=${BACKUP_BOOT_VOLUME:-yes}
  WORK_DIR=${WORK_DIR:-/var/tmp/oci-nutanix}
  CE_PASSWORD=${CE_PASSWORD:-nutanix/4u}
  OCI_SERVICES_IP=${OCI_SERVICES_IP:-169.254.169.254}
  CONSOLE_SSH_PUBKEY_FILE=${CONSOLE_SSH_PUBKEY_FILE:-}
  [ -n "${OCI_CLI_REGION:-}" ] && export OCI_CLI_REGION
  mkdir -p "$STATE_DIR"
  mkdir -p "$WORK_DIR" 2>/dev/null || true

  # derived paths
  SRC_ISO=$WORK_DIR/$SRC_ISO_OBJECT
  BM_ISO=$WORK_DIR/$IMAGE_NAME.iso
  BM_ISO_OBJECT=$IMAGE_NAME.iso
  IMAGE_ENV=$STATE_DIR/image-$IMAGE_NAME.env
  NODE_ENV=$STATE_DIR/$NODE_NAME.env
  NODE_ISCSI=$STATE_DIR/$NODE_NAME.iscsi
  export SRC_ISO BM_ISO BM_ISO_OBJECT IMAGE_ENV NODE_ENV NODE_ISCSI
}

# ---------- OCI helpers ----------
# OCI CLI prints "None"/"null" for missing values with --raw-output; normalise to ""
nul2empty() { sed -e 's/^None$//' -e 's/^null$//'; }
oci_q() { oci "$@" --raw-output 2>/dev/null | nul2empty; }

oci_ns() {
  if [ -z "${OS_NAMESPACE:-}" ]; then
    OS_NAMESPACE=$(oci_q os ns get --query data) || true
    [ -n "$OS_NAMESPACE" ] || die "cannot read the Object Storage namespace - is the OCI CLI configured? (oci os ns get)"
  fi
  echo "$OS_NAMESPACE"
}

oci_ad() {
  if [ -z "${AD:-}" ]; then
    AD=$(oci_q iam availability-domain list --compartment-id "$COMPARTMENT_ID" --query 'data[0].name') || true
    [ -n "$AD" ] || die "cannot determine an availability domain (set AD in $CONFIG_FILE)"
  fi
  echo "$AD"
}

# id of the custom image, or "" (ignores deleted images)
oci_image_id() {
  oci_q compute image list --compartment-id "$COMPARTMENT_ID" --display-name "$IMAGE_NAME" \
    --query "data[?\"lifecycle-state\"!='DELETED' && \"lifecycle-state\"!='DELETING'] | [0].id"
}

oci_instance_state() { oci_q compute instance get --instance-id "$1" --query 'data."lifecycle-state"'; }

# ---------- node state ----------
load_node() {
  [ -f "$NODE_ENV" ] || die "node state $NODE_ENV not found - run scripts/04-launch-instance.sh first"
  # shellcheck disable=SC1090
  . "$NODE_ENV"
  : "${INSTANCE_ID:?}" "${IBFT_IP:?}" "${HOST_IP:?}" "${CVM_IP:?}"
}
mark_done() { touch "$STATE_DIR/$NODE_NAME.$1.done"; }
is_done()   { [ -f "$STATE_DIR/$NODE_NAME.$1.done" ]; }
clear_done(){ rm -f "$STATE_DIR/$NODE_NAME.$1.done"; }

# ---------- SSH helpers (CE default passwords, no host keys: the IPs are reused) ----------
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
ssh_pw()  { sshpass -p "$CE_PASSWORD" ssh $SSHO "$@"; }
# AHV has no SFTP server, so scp needs the legacy protocol (-O)
scp_pw()  { sshpass -p "$CE_PASSWORD" scp -O $SSHO "$@"; }
ssh_installer() { ssh_pw "root@$IBFT_IP" "$@"; }
ssh_host()      { ssh_pw "root@$HOST_IP" "$@"; }
# cluster, ncli and cvm_shutdown need a login shell (bash -lc), otherwise:
# "Zookeeper host port list is not set"
ssh_cvm()       { ssh_pw "nutanix@$CVM_IP" "bash -lc '$*'"; }
ssh_cvm_tty()   { sshpass -p "$CE_PASSWORD" ssh -t $SSHO "nutanix@$CVM_IP" "bash -lc '$*'"; }
scp_to_installer() { scp_pw "$@" "root@$IBFT_IP:/root/"; }
scp_to_host()      { scp_pw "$@" "root@$HOST_IP:/root/"; }

# wait_for <label> <timeout-seconds> <interval-seconds> <command...>
wait_for() {
  local label=$1 timeout=$2 iv=$3 t=0
  shift 3
  until "$@" >/dev/null 2>&1; do
    [ "$t" -ge "$timeout" ] && { echo; die "timed out after ${timeout}s waiting for $label"; }
    sleep "$iv"; t=$((t + iv))
    printf '\r    ... waiting for %s (%dm%02ds) ' "$label" $((t / 60)) $((t % 60))
  done
  echo
  info "$label: ok"
}
ssh_ok() { ssh_pw -o BatchMode=no "$1" true; }

# ---------- misc ----------
# 10.0.0.0/24 -> 255.255.255.0
cidr_netmask() {
  local p=${1#*/} i b m=()
  for i in 0 1 2 3; do
    b=$(( p >= 8 ? 8 : (p > 0 ? p : 0) ))
    m+=( $(( 256 - 2 ** (8 - b) )) )
    p=$(( p - b ))
  done
  echo "${m[0]}.${m[1]}.${m[2]}.${m[3]}"
}
confirm() { # confirm <prompt>  -> returns 0 on y/yes
  local a
  read -r -p "$1 [y/N] " a
  [[ $a =~ ^[Yy]([Ee][Ss])?$ ]]
}
