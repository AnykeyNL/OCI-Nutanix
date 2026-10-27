#!/bin/bash
# =============================================================================
# validate-ahv-bm.sh — read-only health check of AHV on OCI bare metal
# =============================================================================
# Run on the AHV host as root after every power event:  bash validate-ahv-bm.sh
# (or from the admin host: scripts/ops/validate.sh)
# Exit code = number of FAILs. Changes nothing.
# =============================================================================
F=0
ok()   { echo "  PASS  $*"; }
bad()  { echo "  FAIL  $*"; F=$((F+1)); }
warn() { echo "  WARN  $*"; }
chk()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== boot / iSCSI root =="
chk "root on /dev/mapper/ahv-root"            "findmnt -n -o SOURCE / | grep -q ahv-root"
chk "boot volume session (169.254.0.2)"       "iscsiadm -m session | grep -q '169.254.0.2:3260'"
N=$(iscsiadm -m session 2>/dev/null | grep -c oracleiaas)
[ "$N" -ge 2 ] && ok "CVM/data volume sessions: $N" || bad "CVM/data volume sessions: $N (want 2)"
iscsiadm -m session -P3 2>/dev/null | grep -E 'Recovery Timeout|iSCSI Session State' | sort | uniq -c | sed 's/^/        /'
chk "boot session recovery timeout 6000"     "[ \"\$(cat /sys/class/iscsi_session/session1/recovery_tmo)\" -ge 6000 ]"
chk "no session in FAILED/FREE state"        "! iscsiadm -m session -P3 | grep -E 'Session State: (FAILED|FREE)'"
E=$(journalctl -b -k --no-pager 2>/dev/null | grep -ciE 'I/O error|connection.*error|ping timeout')
[ "$E" = 0 ] && ok "kernel: no I/O / iSCSI errors this boot" || bad "kernel: $E I/O/iSCSI error lines this boot"

echo "== persistence of OCI fixes =="
chk "99ocibm in initramfs"                    "lsinitrd /boot/initramfs-\$(uname -r).img | grep -q oci-bm-iscsi"
chk "dracut.conf.d/oci-bm.conf"               "grep -q ocibm /etc/dracut.conf.d/oci-bm.conf"
chk "iscsi + iscsi-shutdown masked"           "systemctl is-enabled iscsi.service iscsi-shutdown.service | grep -c masked | grep -q 2"
chk "iscsid enabled"                          "systemctl is-enabled iscsid.service"
chk "openibd stop disabled"                   "systemctl cat openibd.service | grep -q 'ExecStop=/bin/true'"
chk "LVM filter sda3 only"                    "grep -q 'oci-bm global_filter' /etc/lvm/lvm.conf"
chk "hostsetup boot-NIC filter"               "grep -rq oci-bm-boot-nic /usr/lib/python3.6/nutanix-site-packages/hostsetup/platforms/base/network.py"
chk "oci-bm-volumes.service ok"               "systemctl is-active oci-bm-volumes.service"
chk "oci-cvm-net.timer active"                "systemctl is-active oci-cvm-net.timer"
# stock CE on OCI, not ours: ahv_first_boot (legacy script, needs 'python';
# firstboot-method is noop), systemd-modules-load (ipmi_si: no IPMI on OCI) and
# ahv-status-cvm (logs in to the CVM with the factory key, which AOS removes
# after cluster create; fails 25 min after each boot)
chk "no failed units (besides stock ones)"   "[ -z \"\$(systemctl --failed --no-legend | grep -vE 'ahv_first_boot|systemd-modules-load|ahv-status-cvm')\" ]"
chk "our files SELinux-labelled"             "! ls -Z /etc/sysctl.d/90-oci-bm.conf /etc/systemd/system/oci-* /usr/local/sbin/oci-* | grep -q unlabeled"

echo "== network =="
BMAC=$(cat /etc/oci-bm-boot-nic 2>/dev/null)
chk "boot NIC not in OVS"                     "! ovs-vsctl show | grep -qi \"\$BMAC\""
chk "br0 MAC = eth0 MAC"                      "[ \"\$(cat /sys/class/net/br0/address)\" = \"\$(cat /sys/class/net/eth0/address)\" ]"
chk "default route via br0"                   "ip route show default | grep -q 'dev br0'"
chk "rule: from boot IP -> table 100"         "ip rule show | grep -q 'lookup 100'"
GW=$(ip route show default | awk '{print $3; exit}')
chk "gateway $GW reachable"                   "ping -c2 -W2 $GW"
chk "time synchronised"                       "chronyc tracking | grep -q 'Leap status *: Normal'"

echo "== CVM / cluster =="
CVM=$(virsh list --all --name | grep -- '-CVM$')
chk "CVM $CVM running"                        "virsh domstate $CVM | grep -q running"
chk "ahv-define-cvm succeeded"                "systemctl is-active ahv-define-cvm.service || systemctl show -p Result ahv-define-cvm | grep -q success"
CIP=$(sed -n 's/^CVM_IP=//p' /usr/local/sbin/oci-cvm-net.sh)
chk "CVM route src = host IP"                 "ip route get $CIP | grep -q \"src \$(ip -4 -o addr show br0 | awk '{print \$4}' | cut -d/ -f1)\""
chk "CVM $CIP answers ping"                   "ping -c2 -W2 $CIP"
if ping -c1 -W2 $CIP >/dev/null 2>&1 && command -v sshpass >/dev/null; then
  D=$(sshpass -p 'nutanix/4u' ssh -o StrictHostKeyChecking=no nutanix@$CIP \
      "/usr/local/nutanix/cluster/bin/cluster status 2>/dev/null | grep -c ' UP '" 2>/dev/null)
  echo "        services UP: ${D:-?} (45 when the cluster is fully up; it needs ~10 min after boot)"
fi
echo
[ $F = 0 ] && echo "ALL PASS" || echo "$F FAIL(s)"
exit $F
