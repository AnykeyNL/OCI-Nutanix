#!/bin/bash
# =============================================================================
# 00-prereqs.sh — prepare the Oracle Linux 10 admin host
# =============================================================================
# Installs the packages the ISO build and the orchestration need, checks the
# OCI CLI, the configuration file, the source bucket and the free disk space.
# Safe to re-run.
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
need_root
load_config

say "Packages"
dnf -y -q install xorriso cpio gzip xz gcc make flex bison bc perl elfutils-libelf-devel openssl-devel \
  iscsi-initiator-utils python3 kmod curl tar jq openssh-clients iputils >/dev/null
if ! command -v sshpass >/dev/null 2>&1; then
  dnf -y -q install sshpass >/dev/null 2>&1 \
    || { dnf -y -q install oracle-epel-release-el10 >/dev/null 2>&1 && dnf -y -q install sshpass >/dev/null; } \
    || die "sshpass could not be installed: enable the EPEL repository (dnf config-manager --enable ol10_developer_EPEL) and retry"
fi
info "installed: $(rpm -q --qf '%{NAME} ' xorriso cpio gcc make iscsi-initiator-utils sshpass python3 jq 2>/dev/null)"

say "OCI CLI"
need_cmd oci
info "version $(oci --version)"
info "region: ${OCI_CLI_REGION:-(from the OCI CLI profile)}"
info "Object Storage namespace: $(oci_ns)"
info "availability domain: $(oci_ad)"
CN=$(oci_q iam compartment get --compartment-id "$COMPARTMENT_ID" --query 'data.name') || true
[ -n "$CN" ] || die "compartment $COMPARTMENT_ID not readable"
info "compartment: $CN"
SN=$(oci_q network subnet get --subnet-id "$SUBNET_ID" --query 'data."display-name"') || true
[ -n "$SN" ] || die "subnet $SUBNET_ID not readable"
info "subnet: $SN ($(oci_q network subnet get --subnet-id "$SUBNET_ID" --query 'data."cidr-block"'))"

say "Source ISO in bucket $SRC_BUCKET"
SIZE=$(oci_q os object head --namespace "$(oci_ns)" --bucket-name "$SRC_BUCKET" --name "$SRC_ISO_OBJECT" --query '"content-length"') || true
[ -n "$SIZE" ] || die "object '$SRC_ISO_OBJECT' not found in bucket '$SRC_BUCKET' (upload the stock CE ISO there first)"
info "$SRC_ISO_OBJECT: $((SIZE / 1024 / 1024)) MB"
[ "$IMG_BUCKET" = "$SRC_BUCKET" ] || { oci os bucket get --namespace "$(oci_ns)" --bucket-name "$IMG_BUCKET" >/dev/null 2>&1 || die "image bucket '$IMG_BUCKET' not found"; }

say "Disk space in $WORK_DIR"
mkdir -p "$WORK_DIR"
FREE_GB=$(df -BG --output=avail "$WORK_DIR" | tail -1 | tr -dc '0-9')
info "${FREE_GB} GB free (the build needs about 25 GB: two ISOs, kernel source, work copies)"
[ "$FREE_GB" -ge 25 ] || warn "less than 25 GB free - set WORK_DIR to a bigger file system"

say "Scripts"
chmod +x "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/ops/*.sh "$SCRIPTS_DIR"/build/*.sh "$REMOTE_DIR"/*.sh 2>/dev/null || true
info "state directory: $STATE_DIR"
echo
echo "Prerequisites OK. Next: scripts/01-fetch-iso.sh  (or scripts/install-all.sh)"
