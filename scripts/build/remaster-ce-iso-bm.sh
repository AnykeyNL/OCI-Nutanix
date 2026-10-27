#!/bin/bash
# =============================================================================
# remaster-ce-iso-bm.sh — add iSCSI boot support to the CE ISO for OCI bare metal
# =============================================================================
# WHERE IT RUNS : the admin host (Oracle Linux 10), as root, next to ibft-parse.c.
#   bash remaster-ce-iso-bm.sh modules <ce.iso>             build + check modules only
#   bash remaster-ce-iso-bm.sh build   <ce.iso> [out.iso]   write the BM ISO
#   Work directory: $REMASTER_WORK (default /var/tmp/ce-remaster).
# WHY           : on bare metal the firmware boots the installer over iSCSI, but
#                 the installer kernel (5.10.2) was built without iSCSI
#                 (CONFIG_ISCSI_TCP / SCSI_ISCSI_ATTRS not set), so it never sees
#                 the boot volume: "Failed to find Phoenix ISO", kernel panic.
# WHAT IT DOES  : ADDS files to the installer initrd. Nothing is removed or
#                 replaced: the Nutanix kernel, squashfs, AHV/AOS packages,
#                 installer code, GRUB and EFI image stay as shipped.
#   1. Builds the iSCSI modules from Linux 5.10.2 source with the Nutanix
#      kernel's own configuration (read from the kernel image, IKCONFIG):
#      scsi_transport_iscsi, libiscsi, libiscsi_tcp, iscsi_tcp (+ crc32c if
#      needed). The kernel accepts them: MODULE_SIG_FORCE and MODVERSIONS are
#      off; vermagic must be "5.10.2 SMP mod_unload".
#   2. Adds iscsistart and ibft-parse (reads the firmware iBFT table from ACPI).
#   3. Wraps /ce_installer (the kernel's init=): if an iBFT table exists (OCI
#      bare metal), load the modules, bring up the boot NIC, log in to the boot
#      volume (-> sda), then start the original installer. No iBFT (VM, normal
#      server): nothing happens. Also runs enable_ssh automatically.
#   4. Repacks the initrd and writes the ISO with the original boot setup.
# =============================================================================
set -euo pipefail
ACTION=${1:?usage: $0 modules|build <ce.iso> [out.iso]}
ISO=$(readlink -f "${2:?ce.iso}")
OUT=$(readlink -f "${3:-${ISO%.iso}-ocibm.iso}")
HERE=$(cd "$(dirname "$0")" && pwd)
W=${REMASTER_WORK:-/var/tmp/ce-remaster}
KV=5.10.2
VERMAGIC="5.10.2 SMP mod_unload"
I=/boot/initrd
K=/boot/kernel
say()  { echo; echo "=== $* ==="; }
info() { echo "    -> $*"; }

say "Tools"
mkdir -p "$W"
dnf -y -q install xorriso cpio gzip xz iscsi-initiator-utils gcc make flex bison bc perl \
  elfutils-libelf-devel openssl-devel python3 >/dev/null 2>&1 || true
for t in xorriso cpio iscsistart gcc make flex bison bc; do command -v $t >/dev/null || { echo "missing $t"; exit 1; }; done
[ -f "$HERE/ibft-parse.c" ] || { echo "ibft-parse.c must be next to this script"; exit 1; }

say "Extract kernel + initrd from $ISO"
rm -rf $W/iso $W/initrd; mkdir -p $W/iso/boot $W/initrd
xorriso -osirrox on -indev "$ISO" -extract $K $W/iso$K -extract $I $W/iso$I >/dev/null 2>&1
chmod u+w $W/iso$K $W/iso$I
(cd $W/initrd && gzip -dc $W/iso$I | cpio -idm --quiet)
info "init=/ce_installer -> $(readlink $W/initrd/ce_installer)"

say "1/4 Nutanix kernel configuration (IKCONFIG)"
python3 - "$W/iso$K" "$W/config-$KV" <<'EOF'
import lzma, zlib, sys
b = open(sys.argv[1], 'rb').read()
k = lzma.LZMADecompressor().decompress(b[b.find(b'\xfd7zXZ\x00'):])
i = k.find(b'IKCFG_ST')
if i < 0: sys.exit('IKCONFIG not embedded')
open(sys.argv[2], 'wb').write(zlib.decompressobj(31).decompress(k[i + 8:]))
EOF
grep -E '^# CONFIG_MODULE_SIG_FORCE is not set|^# CONFIG_MODVERSIONS is not set' $W/config-$KV | sed 's/^/    /'

say "2/4 Build iSCSI modules (Linux $KV)"
SRC=$W/linux-$KV
if [ ! -d $SRC ]; then
  curl -fsSL -o $W/linux-$KV.tar.xz https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-$KV.tar.xz
  tar -C $W -xf $W/linux-$KV.tar.xz
fi
cp $W/config-$KV $SRC/.config
cd $SRC
# build helpers (objtool, libsubcmd) use -Werror; OL-10's newer gcc warns on
# 5.10.2 code. They only check the build and are not part of the modules.
sed -i 's/ -Werror\b//g; s/-Werror //g' tools/objtool/Makefile tools/lib/subcmd/Makefile
grep -l -- '-Werror' tools/objtool/Makefile tools/lib/subcmd/Makefile 2>/dev/null | sed 's/^/    still -Werror: /' || true
scripts/config --module SCSI_ISCSI_ATTRS --module ISCSI_TCP --disable ISCSI_IBFT
make -s olddefconfig
# only new modules (=m) are allowed; any change to built-in options (=y) would
# no longer match the running Nutanix kernel. Compiler-capability flags
# (CC_HAS_*, *_COMPILER, GCC/CLANG/AS/LD versions) describe OL-10's gcc, not
# the kernel, and are ignored.
CCFLAGS='^CONFIG_(CC_|GCC_|CLANG_|AS_|LD_|TOOLS_|HAVE_[A-Z_]*COMPILER)'
NEW_Y=$(diff <(grep '=y' $W/config-$KV | grep -vE "$CCFLAGS" | sort) \
             <(grep '=y' .config | grep -vE "$CCFLAGS" | sort) | grep '^[<>]' || true)
diff <(grep '=y' $W/config-$KV | sort) <(grep '=y' .config | sort) | grep '^>' | grep -E "${CCFLAGS/^/^> }" \
  | sed 's/^> /    compiler flag (ignored): /' || true
[ -z "$NEW_Y" ] || { echo "config change would alter built-in options - stop:"; echo "$NEW_Y"; exit 1; }
diff <(grep '=m' $W/config-$KV | sort) <(grep '=m' .config | sort) | grep '^>' | sed 's/^> /    added: /' || true
MODS="drivers/scsi/scsi_transport_iscsi.ko drivers/scsi/libiscsi.ko drivers/scsi/libiscsi_tcp.ko drivers/scsi/iscsi_tcp.ko"
grep -q '^CONFIG_CRYPTO_CRC32C=m' .config && MODS="$MODS crypto/crc32c_generic.ko" || true
grep -q '^CONFIG_CRYPTO_MD5=m' .config && MODS="$MODS crypto/md5.ko" || true
LOG=$W/build.log
info "compiling (log: $LOG) ..."
if ! make -j"$(nproc)" modules_prepare KCFLAGS="-Wno-error" > $LOG 2>&1; then
  echo "modules_prepare failed - errors in $LOG:"
  grep -E 'error:|Error [0-9]|\*\*\*|fatal' $LOG | grep -v 'warning:' | tail -20; exit 1
fi
make -j"$(nproc)" KCFLAGS="-Wno-error" KBUILD_MODPOST_WARN=1 $MODS >> $LOG 2>&1 || {
  echo "module build failed - errors in $LOG:"
  grep -E 'error:|Error [0-9]|\*\*\*|fatal' $LOG | grep -v 'warning:' | tail -20; exit 1; }
for m in $MODS; do
  [ -f $m ] || { echo "build failed: $m"; exit 1; }
  v=$(modinfo -F vermagic $m | sed 's/ *$//')
  info "$(basename $m): vermagic '$v'"
  [ "$v" = "$VERMAGIC" ] || { echo "vermagic mismatch - stop"; exit 1; }
done
cd - >/dev/null

say "3/4 Helpers"
gcc -O2 -o $W/ibft-parse "$HERE/ibft-parse.c"
[ "$ACTION" = modules ] && { echo; echo "Modules OK. Next: build"; exit 0; }
[ "$ACTION" = build ] || { echo "unknown action $ACTION"; exit 1; }
D=$W/initrd
# Everything lives under /lib/oci-bm: livecd.sh copies /lib/* into the full
# installer environment before switch_root, so the helpers (and the systemd
# units below) are still there after the switch.
O=$D/lib/oci-bm
mkdir -p $O/bin $O/lib $O/modules $O/sbin $D/usr/sbin
for m in $MODS; do cp $SRC/$m $O/modules/; done
for B in $(command -v iscsistart) $W/ibft-parse; do
  cp -L "$B" $O/bin/
  for L in $(ldd "$B" | grep -oE '/[^ ]+\.so[^ ]*'); do cp -L "$L" $O/lib/; done
done
LD=$(basename "$(ldd $W/ibft-parse | grep -oE '/[^ ]*ld-linux[^ ]*')")
for b in iscsistart ibft-parse; do
  cat > $O/sbin/$b <<EOF
#!/bin/sh
exec /lib/oci-bm/lib/$LD --library-path /lib/oci-bm/lib /lib/oci-bm/bin/$b "\$@"
EOF
  chmod +x $O/sbin/$b
  ln -sfn /lib/oci-bm/sbin/$b $D/usr/sbin/$b
done
info "added: $(ls $O/modules | tr '\n' ' ') iscsistart ibft-parse"

# After switch_root (systemd in the full installer environment): keep the
# route to the iSCSI target, and run Nutanix's enable_ssh (copied to /root).
cat > $O/sbin/oci-bm-keep-path <<'EOF'
#!/bin/sh
# keep the boot NIC address and the route to the iSCSI target (OCI bare metal)
. /tmp/oci-bm.env || exit 0
while :; do
  ip addr show dev $IBFT_NIC | grep -q "inet $IBFT_IP/" || ip addr add $IBFT_IP/$IBFT_PREFIX dev $IBFT_NIC
  ip route show $IBFT_TARGET_IP | grep -q . || ip route add $IBFT_TARGET_IP/32 dev $IBFT_NIC
  sleep 5
done
EOF
chmod +x $O/sbin/oci-bm-keep-path
mkdir -p $D/lib/systemd/system/multi-user.target.wants
cat > $D/lib/systemd/system/oci-bm-path.service <<'EOF'
[Unit]
Description=OCI bare metal: keep the path to the iSCSI boot volume
ConditionPathExists=/tmp/oci-bm.env
[Service]
ExecStart=/lib/oci-bm/sbin/oci-bm-keep-path
Restart=always
[Install]
WantedBy=multi-user.target
EOF
cat > $D/lib/systemd/system/oci-bm-ssh.service <<'EOF'
[Unit]
Description=OCI bare metal: enable SSH in the CE installer (enable_ssh)
ConditionPathExists=/tmp/oci-bm.env
After=network.target
[Service]
Type=simple
ExecStart=/bin/sh /root/enable_ssh
[Install]
WantedBy=multi-user.target
EOF
# relative links: valid in the initrd and after the copy into the new root
ln -sfn ../oci-bm-path.service $D/lib/systemd/system/multi-user.target.wants/oci-bm-path.service
ln -sfn ../oci-bm-ssh.service  $D/lib/systemd/system/multi-user.target.wants/oci-bm-ssh.service

# livecd.sh runs in CE mode only when started as "ce_installer" (it checks
# ${0##*/}), so the original is started through /lib/oci-bm/ce/ce_installer, a
# link to the same livecd.sh. /ce_installer itself becomes the wrapper.
TARGET=$(readlink $D/ce_installer)
mkdir -p $O/ce
ln -sfn /$TARGET $O/ce/ce_installer
rm -f $D/ce_installer
cat > $D/ce_installer <<'EOF'
#!/bin/sh
# OCI bare metal (remaster-ce-iso-bm.sh): log in to the iSCSI boot volume from
# the firmware's iBFT table before the CE installer looks for its ISO.
# Runs before livecd.sh, which is where busybox normally installs its applet
# links (sleep, ...) and PATH is set: do both here first.
[ -x /bin/busybox ] && /bin/busybox --install -s 2>/dev/null
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
grep -q ' /dev devtmpfs' /proc/mounts || mount -t devtmpfs devtmpfs /dev
T=/sys/firmware/acpi/tables/iBFT
if [ -f $T ]; then
  echo "oci-bm: iBFT found, logging in to the iSCSI boot volume"
  /usr/sbin/ibft-parse $T > /tmp/oci-bm.env && . /tmp/oci-bm.env
  cat /tmp/oci-bm.env
  # NIC drivers with their dependencies (busybox modprobe does not resolve
  # them; mlx5_core needs pci-hyperv-intf etc.)
  MD=/lib/modules/$(uname -r)
  load_mod() {
    local line d
    # first match only (this busybox has no 'head' applet)
    line=$(grep -E "(^|/)$1\.ko(\.xz)?:" $MD/modules.dep | { IFS= read -r l; echo "$l"; })
    [ -z "$line" ] && return
    for d in ${line#*:}; do d=${d##*/}; load_mod ${d%.ko}; done
    insmod $MD/${line%%:*} 2>/dev/null
  }
  for m in mlx5_core i40e ice bnxt_en ixgbe; do load_mod $m; done
  for m in crc32c_generic md5 scsi_transport_iscsi libiscsi libiscsi_tcp iscsi_tcp; do
    [ -f /lib/oci-bm/modules/$m.ko ] && insmod /lib/oci-bm/modules/$m.ko
  done
  i=0; NIC=
  while [ -z "$NIC" ] && [ $i -lt 30 ]; do
    for n in /sys/class/net/*; do
      [ -e $n/device ] && [ "$(cat $n/address)" = "$IBFT_MAC" ] && NIC=${n##*/}
    done
    sleep 1; i=$((i+1))
  done
  echo "IBFT_NIC=$NIC" >> /tmp/oci-bm.env
  ip link set $NIC up
  ip addr add $IBFT_IP/$IBFT_PREFIX dev $NIC 2>/dev/null
  ip route add $IBFT_TARGET_IP/32 dev $NIC 2>/dev/null
  sleep 3
  /usr/sbin/iscsistart -i "$IBFT_INITIATOR" -t "$IBFT_TARGET" -g 1 -a "$IBFT_TARGET_IP" \
    -p "$IBFT_TARGET_PORT" -P node.session.timeo.replacement_timeout=86400
  i=0; while [ ! -b /dev/sda ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  echo "oci-bm: boot volume $( [ -b /dev/sda ] && echo visible as sda || echo NOT visible)"
  # The installer treats the node as "booted from the Phoenix ISO" only when it
  # finds the ISO the CDROM way, or when this marker exists (sysUtil.py
  # is_node_booted_into_phoenix_iso). Without it, patch_phoenix.py scans for an
  # old CVM home partition and spins. livecd.sh copies /tmp/* into the new root.
  [ -b /dev/sda ] && : > /tmp/phoenix_iso_marker
  # the installer re-runs DHCP on this NIC; keep the path to the target in place
  # until switch_root (afterwards oci-bm-path.service takes over; this loop
  # ends when its sleep disappears with the old root)
  ( while :; do
      ip addr show dev $NIC | grep -q "inet $IBFT_IP/" || ip addr add $IBFT_IP/$IBFT_PREFIX dev $NIC
      ip route show $IBFT_TARGET_IP | grep -q . || ip route add $IBFT_TARGET_IP/32 dev $NIC
      sleep 2 || exit
    done ) >/dev/null 2>&1 &
fi
exec /lib/oci-bm/ce/ce_installer "$@"
EOF
chmod +x $D/ce_installer

# self-check: run the wrapper's commands with the installer's own busybox, in a
# scratch copy (busybox --install would otherwise add links to the initrd)
rm -rf $W/chk; cp -a $D $W/chk
chroot $W/chk /bin/busybox sh -n /ce_installer || { echo "wrapper syntax error - stop"; exit 1; }
MISS=$(chroot $W/chk /bin/busybox sh -c '/bin/busybox --install -s 2>/dev/null
  export PATH=/sbin:/bin:/usr/sbin:/usr/bin
  for c in mount grep cat insmod ip sleep; do command -v $c >/dev/null || echo $c; done')
for c in head tail basename readlink sed awk cut; do
  grep -qE "(^|[^a-z_])$c( |$)" $D/ce_installer && ! chroot $W/chk /bin/busybox sh -c "command -v $c" >/dev/null && MISS="$MISS $c"
done
rm -rf $W/chk
[ -z "$(echo $MISS)" ] || { echo "wrapper uses commands missing in the installer: $MISS - stop"; exit 1; }
info "wrapper self-check: syntax ok, all commands present"

say "4/4 Repack and write $OUT"
(cd $D && find . -print0 | cpio --null -o -H newc --quiet) | gzip -6 > $W/iso$I
info "initrd: $(du -h $W/iso$I | cut -f1) (kernel unchanged)"
rm -f "$OUT"
xorriso -indev "$ISO" -outdev "$OUT" -map $W/iso$I $I -boot_image any replay 2>&1 | tail -3 | sed 's/^/    /'
ls -lh "$OUT"
echo
echo "Done. Upload $OUT to Object Storage and import it as a custom image (scripts/03-import-image.sh)."
