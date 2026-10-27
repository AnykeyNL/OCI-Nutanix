#!/bin/bash
# =============================================================================
# ce-bm-prep.sh — prepare the Nutanix CE installer (Phoenix) on OCI bare metal
# =============================================================================
# WHERE IT RUNS : inside Phoenix on the bare-metal instance, as root, over SSH
#                 on IBFT_IP (root password: nutanix/4u).
#                 usage: bash ce-bm-prep.sh <name>.iscsi
#                 (scripts/05-install.sh copies and runs it for you)
# DIFFERENCE TO A VM: the firmware reached the boot volume over iSCSI, but
# Linux must log in itself before it sees any disk:
#   0. iSCSI: log in to the boot volume from the firmware's iBFT table (-> sda)
#      and to the CVM/data volumes (-> sdb, sdc).
# Then:
#   1. Hypervisor detection fallback (harmless on bare metal).
#   2. Boot-disk detection: no SATADOM/M.2; the boot volume (sda) is H.
#   2b. Disk-controller walk: stop at /sys/devices for iSCSI disks (no PCI
#       controller above them; the stock loop never ends).
#   3. SSD flag on the block volumes.
#   4. Copy the CE ISO into RAM, freeing sda for AHV.
#   5/6. vgchange and mount wrappers (loop devices for sda partitions).
#   7. Check that the installer finds AHV and AOS.
# All changes live in RAM; re-run after any reboot of the installer.
# =============================================================================
ISCSI=${1:?usage: $0 <name>.iscsi}
say()  { echo; echo "=== $* ==="; }
info() { echo "    -> $*"; }

say "0/7 iSCSI logins"
# the BM ISO (remaster-ce-iso-bm.sh) already logged in to the boot volume at boot
# added by the BM ISO under /lib/oci-bm (survives the installer's switch_root)
ISCSISTART=/lib/oci-bm/sbin/iscsistart
[ -x $ISCSISTART ] || ISCSISTART=$(command -v iscsistart) || { echo "iscsistart missing: boot from the BM ISO"; exit 1; }
[ -f /tmp/oci-bm.env ] || { echo "/tmp/oci-bm.env missing: installer not booted from the BM ISO"; exit 1; }
. /tmp/oci-bm.env
[ -b /dev/sda ] || { echo "boot volume not visible - check the console log"; exit 1; }
INITIATOR=$IBFT_INITIATOR
info "initiator: $INITIATOR"
while read -r IQN IP PORT; do
  [ -z "$IQN" ] && continue
  ls /sys/class/iscsi_session/*/targetname 2>/dev/null | xargs -r cat | grep -qx "$IQN" && continue
  ip route show "$IP" | grep -q . || ip route add "$IP/32" dev "$IBFT_NIC"
  $ISCSISTART -i "$INITIATOR" -t "$IQN" -g 1 -a "$IP" -p "$PORT" \
    -P node.session.timeo.replacement_timeout=86400 && info "logged in: $IQN"
done < "$ISCSI"
sleep 5
lsblk -d -o NAME,SIZE,TRAN,MODEL | sed 's/^/    /'
[ -b /dev/sda ] || { echo "no sda - stop"; exit 1; }

say "1/7 Hypervisor detection"
F=/root/.local/lib/python3.9/site-packages/tartarus/base/environment.py
grep -q 'sys_vendor"):' $F || \
  sed -i 's|if not is_virtualized():|if not is_virtualized() or not os.path.exists("/sys/class/dmi/id/sys_vendor"):|' $F

say "2/7 Boot-disk detection"
S=/root/phoenix/sysUtil.py
sed -i 's|boot_disk = boot_dev.dev$|boot_disk = boot_dev.dev if boot_dev else "sda"|' $S
sed -i 's|boot_dev = boot_disk.dev$|boot_dev = boot_disk.dev if boot_disk else "sda"|' $S
info "patches applied: $(grep -c 'else "sda"' $S)   (expected 5)"

say "2b/7 Disk-controller walk (iSCSI disks)"
info "hardware detection walks up /sys from a disk's SCSI host until it finds a"
info "driver link (the PCI controller). iSCSI hosts sit under /sys/devices/platform"
info "with no driver above them, so the walk never ends. Stop it at the top of"
info "/sys/devices; the existing except: pass then leaves the controller unknown."
LOOP='sysfs_path = os.path.join(sysfs_path, "..")'
for P in $(grep -rlF "$LOOP" /root/.local/lib/python3.9/site-packages /root/phoenix 2>/dev/null | grep '\.py$'); do
  grep -q 'oci-bm: no controller driver' $P && { info "already patched: $P"; continue; }
  sed -i 's|^\(\s*\)sysfs_path = os.path.join(sysfs_path, "\.\.")$|&\n\1if os.path.realpath(sysfs_path) in ("/", "/sys", "/sys/devices", "/sys/devices/platform"): raise OSError("oci-bm: no controller driver")|' $P
  info "patched: $P ($(grep -c 'oci-bm: no controller driver' $P))"
done
info "the controller's PCI vendor/device read fails for iSCSI too (its 'PCI"
info "address' is /sys/devices/platform); treat it like a USB disk: no IDs"
D=/root/.local/lib/python3.9/site-packages/hardware_inventory/disk_info.py
grep -q 'not pci_path.startswith("/sys/devices/platform")' $D || \
  sed -i '/except IOError as e:/{n;s|if not dev_info.isUSB:|if not dev_info.isUSB and not pci_path.startswith("/sys/devices/platform"):|}' $D
info "PCI-ID patch: $(grep -c 'not pci_path.startswith("/sys/devices/platform")' $D)   (expected 1)"
info "AHV customisation un-blacklists the CVM disks' controller drivers; iSCSI"
info "disks have none (None), which breaks that loop: skip them"
K=/root/phoenix/customize_kvm.py
sed -i 's|if (disk.controller_driver != "nvme" and|if (disk.controller_driver and disk.controller_driver != "nvme" and|' $K
info "driver-list patch: $(grep -c 'if (disk.controller_driver and disk.controller_driver != "nvme"' $K)   (expected 1)"

say "3/7 SSD flag on block volumes"
for d in /sys/block/sd[b-z]; do [ -e $d ] && echo 0 > $d/queue/rotational; done
grep . /sys/block/sd*/queue/rotational | sed 's/^/    /'

say "4/7 Copy the CE ISO into RAM"
mkdir -p /mnt/iso /root/isocopy
if [ -e /root/isocopy/.oci-bm-copied ]; then
  info "already copied (re-run); keeping the bind mount"
  mountpoint -q /mnt/iso || mount --bind /root/isocopy /mnt/iso
else
  mountpoint -q /mnt/iso || mount -t iso9660 -o ro /dev/sda /mnt/iso
  info "copying ~8 GB, takes a few minutes..."
  cp -a /mnt/iso/. /root/isocopy/ || { echo "COPY FAILED - stop"; exit 1; }
  umount /mnt/iso && mount --bind /root/isocopy /mnt/iso
  : > /root/isocopy/.oci-bm-copied
fi
info "sda mounts (expected: none): $(grep -c sda /proc/mounts)"

say "5/7 vgchange wrapper"
rm -f /usr/sbin/vgchange
cat > /usr/sbin/vgchange <<'EOF'
#!/bin/sh
if echo "$*" | grep -q -- '-ay'; then
  L=$(losetup -j /dev/sda3 | cut -d: -f1)
  [ -z "$L" ] && L=$(losetup -f --show /dev/sda3)
  exec /usr/sbin/lvm vgchange "$@" --config "devices { filter=[ \"a|$L|\", \"r|.*|\" ] }"
fi
losetup -D 2>/dev/null
exec /usr/sbin/lvm vgchange "$@"
EOF
chmod +x /usr/sbin/vgchange

say "6/7 mount wrapper"
M=/usr/bin/mount
[ -e ${M}.real ] || mv $M ${M}.real
cat > $M <<EOF
#!/bin/bash
a=()
for x in "\$@"; do
  r=\$(readlink -f -- "\$x" 2>/dev/null)
  if [[ \$r =~ ^/dev/sda[0-9]+\$ ]]; then
    l=\$(losetup -j "\$r" | cut -d: -f1 | head -1)
    [ -z "\$l" ] && l=\$(losetup -f --show "\$r")
    x=\$l
  fi
  a+=("\$x")
done
exec ${M}.real "\${a[@]}"
EOF
chmod +x $M

say "7/7 Check that the installer finds AHV and AOS"
export COMMUNITY_EDITION=1
cd /root/phoenix
python3 -c "import images as i; print('    HYP=', i.get_packaged_hyp()); print('    NOS=', i.get_packaged_nos())"
echo
echo "Ready. Start the installer:"
echo "  export COMMUNITY_EDITION=1; cd /root/phoenix; ./phoenix"
echo "Disks: sda = H, CVM volume = C, data volume = D.  Host IP = HOST_IP (not IBFT_IP)."
echo "At the end answer N, then run: bash ahv-bm-finalize.sh $ISCSI   (do NOT reboot first)"
