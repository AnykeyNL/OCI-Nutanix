#!/bin/bash
# =============================================================================
# ahv-bm-finalize.sh — make the freshly installed AHV boot from iSCSI
# =============================================================================
# WHERE IT RUNS : inside Phoenix, after ./phoenix finished (answered N), BEFORE
#                 the reboot.   usage: bash ahv-bm-finalize.sh <name>.iscsi
#                 (scripts/06-finalize.sh copies and runs it for you)
# HOW AHV BOOTS : firmware -> EFI/centos/grub.cfg, a static menuentry (BLS
#   entries and grubby are not used) -> /boot/vmlinuz + /boot/initramfs-<kver>.img
#   -> root=/dev/mapper/ahv-root (LVM on sda3). NICs are named by rename_device
#   from ifcfg HWADDR; first boot builds br0 from first_boot_config.json
#   "vswitches", defaulting to every mlx5 port.
# WHAT IT DOES  (in a chroot of AHV on sda):
#   0. Reads the iBFT values the BM ISO saved in /tmp/oci-bm.env.
#   1. Checks AHV has iscsistart and the iscsi_tcp module.
#   2. initramfs: adds our own iSCSI login hook (finds the boot NIC by MAC,
#      static IP, iscsistart with the iBFT values) - no dependency on dracut's
#      iscsi/network modules or on kernel arguments. Verified with lsinitrd.
#   3. Running AHV: the boot NIC is left out of AHV's network setup (hostsetup
#      _get_pci_net_devices filtered by MAC) and has no ifcfg, so nothing
#      renames, reconfigures or takes it down; iscsi-shutdown and iscsi.service
#      masked (no logout of the root session); iscsid enabled; sysctls.
#   4. First boot: br0 uplink = NIC1 only (by MAC), so the iSCSI NIC never
#      joins OVS.
#   5. Checks the UEFI fallback loader, SELinux labels, unmounts.
#   Also runs ahv-host-setup.sh --install-only in the chroot (must sit next to
#   this script): OCI iscsid values, oci-bm-volumes.service, openibd fix, LVM
#   filter, oci-cvm-net timer; and /etc/dracut.conf.d/oci-bm.conf so later
#   initramfs rebuilds (AHV upgrades) keep the iSCSI hook.
# =============================================================================
set -euo pipefail
ISCSI=${1:?usage: $0 <name>.iscsi}
R=/mnt/ahv
say()  { echo; echo "=== $* ==="; }
info() { echo "    -> $*"; }
. /tmp/oci-bm.env
BOOT_MAC=$(echo "$IBFT_MAC" | tr 'A-F' 'a-f')
info "boot volume: $IBFT_TARGET @ $IBFT_TARGET_IP:$IBFT_TARGET_PORT lun $IBFT_LUN"
info "boot NIC: $BOOT_MAC  $IBFT_IP/$IBFT_PREFIX  initiator $IBFT_INITIATOR"
[ -f "$(dirname "$0")/ahv-host-setup.sh" ] || { echo "ahv-host-setup.sh must be next to this script"; exit 1; }

say "Mount AHV (sda)"
vgchange -ay ahv
mkdir -p $R
mount /dev/ahv/root $R
for lv in var varlog tmp home; do
  [ -e /dev/ahv/$lv ] || continue
  # first mount point only (AHV mounts ahv-tmp at both /tmp and /var/tmp)
  mp=$(awk -v d="/dev/mapper/ahv-$lv" '$1==d {print $2; exit}' $R/etc/fstab)
  [ -n "$mp" ] && mount /dev/ahv/$lv $R$mp
done
mount /dev/sda2 $R/boot
mount /dev/sda1 $R/boot/efi
for d in dev proc sys run; do mount --bind /$d $R/$d; done

say "1/5 iSCSI support in AHV"
chroot $R rpm -q iscsi-initiator-utils
KVER=$(ls $R/lib/modules | sort -V | tail -1)
find $R/lib/modules/$KVER -name 'iscsi_tcp.ko*' | grep -q . || { echo "AHV kernel $KVER has no iscsi_tcp - stop"; exit 1; }
[ -x $R/usr/sbin/iscsistart ] || { echo "AHV has no iscsistart - stop"; exit 1; }
info "AHV kernel $KVER: iscsi_tcp + iscsistart present"

say "2/5 initramfs with the OCI iSCSI login hook"
# the iBFT values are written into the hook itself (a single --include)
cat > $R/etc/oci-bm-iscsi-hook.sh <<EOF
#!/bin/sh
# OCI bare metal (ahv-bm-finalize.sh): log in to the iSCSI boot volume.
# dracut initqueue/settled hook: sourced repeatedly until the root appears.
OCI_MAC=$BOOT_MAC
OCI_IP=$IBFT_IP
OCI_PREFIX=$IBFT_PREFIX
OCI_INITIATOR=$IBFT_INITIATOR
OCI_TARGET=$IBFT_TARGET
OCI_TARGET_IP=$IBFT_TARGET_IP
OCI_TARGET_PORT=$IBFT_TARGET_PORT
EOF
cat >> $R/etc/oci-bm-iscsi-hook.sh <<'EOF'
[ -e /tmp/oci-bm.done ] && return 0
modprobe -q mlx5_core; modprobe -q iscsi_tcp
NIC=
for n in /sys/class/net/*; do
  [ "$(cat $n/address 2>/dev/null)" = "$OCI_MAC" ] && NIC=${n##*/}
done
[ -z "$NIC" ] && return 0
ip link set $NIC up
ip addr add $OCI_IP/$OCI_PREFIX dev $NIC 2>/dev/null
ip route add 169.254.0.0/16 dev $NIC 2>/dev/null
echo "oci-bm: $NIC up, logging in to $OCI_TARGET" > /dev/kmsg
iscsistart -i "$OCI_INITIATOR" -t "$OCI_TARGET" -g 1 -a "$OCI_TARGET_IP" -p "$OCI_TARGET_PORT" \
  -P node.session.timeo.replacement_timeout=6000 \
  -P 'node.conn[0].timeo.noop_out_interval=0' -P 'node.conn[0].timeo.noop_out_timeout=0' \
  && : > /tmp/oci-bm.done
EOF
chmod +x $R/etc/oci-bm-iscsi-hook.sh
# a small dracut module of our own: the standard way to add a hook (inst_hook)
M=$R/usr/lib/dracut/modules.d/99ocibm
mkdir -p $M
mv -f $R/etc/oci-bm-iscsi-hook.sh $M/oci-bm-iscsi.sh
cat > $M/module-setup.sh <<'EOF'
#!/bin/bash
# OCI bare metal: log in to the iSCSI boot volume (ahv-bm-finalize.sh)
check() { return 0; }
depends() { echo lvm; return 0; }
installkernel() { instmods mlx5_core iscsi_tcp libiscsi_tcp libiscsi scsi_transport_iscsi; }
install() {
  inst_multiple iscsistart ip cat
  inst_hook initqueue/settled 90 "$moddir/oci-bm-iscsi.sh"
}
EOF
chmod +x $M/module-setup.sh
# OCI host settings (iscsid values, volumes service, openibd, LVM filter,
# CVM network timer) before dracut, so the initramfs gets the LVM filter too
CVM_IP=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['svm_ip'])" $R/root/firstboot/first_boot_config.json)
cp -f "$(dirname "$0")/ahv-host-setup.sh" $R/root/ahv-host-setup.sh
echo "$BOOT_MAC" > $R/etc/oci-bm-boot-nic
cp -f $ISCSI $R/root/oci-bm-volumes.iscsi
chroot $R bash /root/ahv-host-setup.sh "$CVM_IP" --install-only
# keep the module in every future initramfs (AHV upgrades, kernel updates)
printf 'add_dracutmodules+=" ocibm lvm "\nhostonly="no"\n' > $R/etc/dracut.conf.d/oci-bm.conf
chroot $R dracut -f --no-hostonly --add "ocibm lvm" /boot/initramfs-$KVER.img $KVER
L=$(chroot $R lsinitrd /boot/initramfs-$KVER.img)
grep -q 'a|^/dev/sda3$|' <<< "$(chroot $R lsinitrd -f etc/lvm/lvm.conf /boot/initramfs-$KVER.img)" \
  && info "initramfs lvm.conf has the sda3 filter" || info "initramfs has no lvm.conf copy (dracut default, fine: the filter matters on the running AHV)"
for want in usr/sbin/iscsistart 90-oci-bm-iscsi.sh iscsi_tcp.ko mlx5_core.ko; do
  # here-string, not echo | grep -q (with pipefail, grep -q's early exit fails the pipe)
  grep -q "$want" <<< "$L" && info "initramfs has $want" || { echo "initramfs is missing $want - stop"; exit 1; }
done

say "3/5 running AHV: boot NIC, iscsid, sysctls"
# No ifcfg for the boot NIC: the initramfs hook sets its address and route, and
# the network service must never take it down (that would cut the iSCSI root).
# Never log the boot session out on shutdown.
rm -f $R/etc/udev/rules.d/70-persistent-net.rules
# nothing may log out the root session: iscsi-shutdown (logout all) and
# iscsi.service (logout automatic on stop). iscsid itself stays enabled.
chroot $R systemctl mask iscsi-shutdown.service iscsi.service
# AHV's network setup (hostsetup: rename_physical_nics, setup_physical_nics,
# configure_ovs) works on every PCI NIC from _get_pci_net_devices(). Leave the
# iSCSI boot NIC out of that list, so AHV never renames, configures or takes
# it down. The MAC comes from /etc/oci-bm-boot-nic.
N=$R/usr/lib/python3.6/nutanix-site-packages/hostsetup/platforms/base/network.py
python3 - "$N" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '        return sorted(net_devices, key=lambda netdev: netdev["path"])\n'
new = ('        # OCI bare metal (ahv-bm-finalize.sh): never touch the iSCSI boot NIC\n'
       '        try:\n'
       '            skip = open("/etc/oci-bm-boot-nic").read().split()\n'
       '        except OSError:\n'
       '            skip = []\n'
       '        net_devices = [d for d in net_devices\n'
       '                       if (d["mac_addr"] or "").lower() not in skip]\n' + old)
if "oci-bm-boot-nic" not in s:
    if s.count(old) != 1:
        sys.exit("expected exactly one _get_pci_net_devices return in %s, found %d" % (p, s.count(old)))
    s = s.replace(old, new)
    open(p, "w").write(s)
print("    -> hostsetup patched: boot NIC excluded from AHV network setup")
PYEOF
chroot $R python3 -m py_compile /usr/lib/python3.6/nutanix-site-packages/hostsetup/platforms/base/network.py \
  && info "patched network.py compiles"
cat > $R/etc/sysctl.d/90-oci-bm.conf <<'EOF'
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.all.rp_filter = 2
EOF
echo "InitiatorName=$IBFT_INITIATOR" > $R/etc/iscsi/initiatorname.iscsi
chroot $R systemctl enable iscsid.service iscsid.socket 2>&1 | grep -v "^Created" || true
info "boot NIC ($BOOT_MAC) configured only by the initramfs, invisible to AHV network setup; iscsi-shutdown + iscsi masked; iscsid enabled"
info "CVM/data volumes: oci-bm-volumes.service logs them in at boot, before the CVM is defined"

say "4/5 first boot: br0 uplink = NIC1 only"
J=$R/root/firstboot/first_boot_config.json
cp -n $J $J.orig
python3 - "$J" "$BOOT_MAC" <<'EOF'
import json, sys
path, boot_mac = sys.argv[1], sys.argv[2].lower()
cfg = json.load(open(path))
macs = [d.get("mac_addr", "").lower() for d in cfg.get("network_devices", {}).values()]
uplinks = [m for m in macs if m and m != boot_mac]
if not uplinks:
    sys.exit("no NIC besides the boot NIC in network_devices - stop")
cfg["vswitches"] = [{"name": "br0", "uplinks": uplinks, "bond-mode": "active-backup"}]
json.dump(cfg, open(path, "w"), indent=2)
print("    -> vswitches:", cfg["vswitches"])
EOF

say "5/5 UEFI loader, SELinux labels, unmount"
ls $R/boot/efi/EFI/BOOT/ | sed 's/^/    /'
# SELinux labels for the files we wrote (AHV enforces; unlabeled_t files are
# denied at boot, e.g. systemd-sysctl). The installer runs without SELinux, so
# restorecon does nothing here: setfiles writes the labels from file_contexts.
P="/etc/sysctl.d /etc/systemd/system /usr/local/sbin /etc/lvm /etc/iscsi /etc/chrony.conf /etc/oci-bm-boot-nic
   /etc/dracut.conf.d /etc/infiniband /usr/lib/dracut/modules.d/99ocibm
   /usr/lib/python3.6/nutanix-site-packages/hostsetup/platforms/base /root"
chroot $R setfiles -F /etc/selinux/targeted/contexts/files/file_contexts $P || true
if python3 -c "import os,sys; sys.exit(b'unlabeled' in os.getxattr(sys.argv[1], 'security.selinux'))" \
     $R/etc/sysctl.d/90-oci-bm.conf 2>/dev/null; then
  info "SELinux labels set: $(python3 -c "import os,sys; print(os.getxattr(sys.argv[1], 'security.selinux').decode().strip(chr(0)))" $R/etc/sysctl.d/90-oci-bm.conf)"
else
  touch $R/.autorelabel
  info "setfiles could not label - AHV will relabel on first boot (one extra reboot)"
fi
sync
umount -R $R
vgchange -an ahv
echo
echo "Done. Now: reboot   (watch the console: 'oci-bm: ... logging in', then AHV)"
