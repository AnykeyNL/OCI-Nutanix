#!/bin/bash
# =============================================================================
# ahv-host-setup.sh — OCI bare-metal settings for the AHV host
# =============================================================================
# WHERE IT RUNS :
#   on the AHV host, as root:        bash ahv-host-setup.sh <CVM_IP>
#     (installs/refreshes everything, defines and starts the CVM if needed)
#   in a chroot of the installed AHV: bash ahv-host-setup.sh <CVM_IP> --install-only
#     (called by ahv-bm-finalize.sh before the first AHV boot: writes the files
#      and enables the units; no virsh / ovs / runtime changes)
# WHAT IT INSTALLS (all idempotent):
#   a. iscsid.conf with OCI's recommended values (replacement_timeout 6000,
#      NOP-out off, HeaderDigest None, startup automatic).
#   b. oci-bm-volumes.service: at boot, before ahv-define-cvm and libvirtd,
#      creates the CVM/data volume records from /root/oci-bm-volumes.iscsi if
#      missing and logs them in. No stop action (never logs anything out).
#   c. openibd stop disabled: Mellanox OFED would rmmod mlx5_core on shutdown,
#      and NIC0 (iSCSI root) is mlx5.
#   d. LVM global_filter = sda3 only (AHV's VG): otherwise lvm2-monitor's stop
#      blocks on AHV's host-swap disks, dead once the CVM is off.
#   e. oci-cvm-net.sh + timer (every 60 s): br0 on the VNIC MAC, routing for
#      the boot NIC (table 100), default via br0, rp_filter/arp_ignore, CVM
#      routed via the Linux bridge ocicvm with proxy-ARP and src = host IP.
#   f. persistent journal (/var/log/journal) for diagnostics.
#   g. chrony -> OCI NTP (169.254.169.254).
#   Online only: define the CVM if first boot could not, start it, apply now.
# =============================================================================
set -u
CVM_IP=${1:?usage: $0 <CVM_IP> [--install-only]}
MODE=${2:-online}
say()  { echo; echo "=== $* ==="; }
info() { echo "    -> $*"; }
online() { [ "$MODE" = online ]; }
BM=no; [ -f /etc/oci-bm-boot-nic ] && BM=yes

if online; then
  CVM=$(virsh list --all --name | grep -- '-CVM$')
  if [ -z "$CVM" ] && [ $BM = yes ]; then
    info "no CVM defined yet - logging in volumes and re-running ahv-define-cvm"
    [ -x /usr/local/sbin/oci-bm-volumes.sh ] && /usr/local/sbin/oci-bm-volumes.sh
    systemctl reset-failed ahv-define-cvm 2>/dev/null; systemctl start ahv-define-cvm
    CVM=$(virsh list --all --name | grep -- '-CVM$')
    [ -z "$CVM" ] && { echo "ahv-define-cvm did not define the CVM - see journalctl -u ahv-define-cvm"; exit 1; }
  fi
  say "AHV host setup for $CVM (CVM IP $CVM_IP)"
else
  say "AHV host setup, install-only (CVM IP $CVM_IP)"
fi

if [ $BM = yes ]; then
  say "a. iscsid.conf: OCI recommended values"
  I=/etc/iscsi/iscsid.conf
  cp -n $I $I.orig
  setp() { grep -q "^$1 *=" $I && sed -i "s|^$1 *=.*|$1 = $2|" $I || echo "$1 = $2" >> $I; }
  setp node.startup automatic
  setp node.session.timeo.replacement_timeout 6000
  setp 'node.conn\[0\].timeo.noop_out_interval' 0
  setp 'node.conn\[0\].timeo.noop_out_timeout' 0
  setp 'node.conn\[0\].iscsi.HeaderDigest' None
  grep -E "^node.startup|replacement_timeout|noop_out|HeaderDigest" $I | sed 's/^/       /'

  say "b. CVM/data volumes at boot (oci-bm-volumes.service)"
  cat > /usr/local/sbin/oci-bm-volumes.sh <<'EOF'
#!/bin/sh
# OCI bare metal: log in to the CVM/data volumes (installed by ahv-host-setup.sh).
# Records are created from /root/oci-bm-volumes.iscsi (iqn ip port) if missing,
# with OCI's recommended values. AHV's own host-swap target (127.0.0.1:3261,
# served by the CVM) is left to AHV. Nothing is ever logged out here.
L=/root/oci-bm-volumes.iscsi
A=/usr/sbin/iscsiadm
if [ -f $L ]; then
  while read -r IQN IP PORT; do
    [ -z "$IQN" ] && continue
    $A -m node -T "$IQN" -p "$IP:$PORT" >/dev/null 2>&1 || $A -m node -o new -T "$IQN" -p "$IP:$PORT" >/dev/null
    for kv in node.startup=automatic node.session.timeo.replacement_timeout=6000 \
              "node.conn[0].timeo.noop_out_interval=0" "node.conn[0].timeo.noop_out_timeout=0" \
              "node.conn[0].iscsi.HeaderDigest=None"; do
      $A -m node -T "$IQN" -p "$IP:$PORT" -o update -n "${kv%%=*}" -v "${kv#*=}"
    done
  done < $L
fi
for t in $($A -m node | awk '/oracleiaas/ {print $2}'); do
  $A -m session 2>/dev/null | grep -q " $t " || $A -m node -T "$t" -l || true
done
# the boot session comes from iscsistart in the initramfs, which ignores the
# -P timeouts (it stays at 120 s): raise its recovery timeout to OCI's value
for s in /sys/class/iscsi_session/session*; do
  [ "$(cat $s/recovery_tmo 2>/dev/null)" -lt 6000 ] 2>/dev/null && echo 6000 > $s/recovery_tmo
done
exit 0
EOF
  chmod +x /usr/local/sbin/oci-bm-volumes.sh
  cat > /etc/systemd/system/oci-bm-volumes.service <<'EOF'
[Unit]
Description=OCI bare metal: log in to the CVM/data iSCSI volumes
After=iscsid.service network-online.target
Wants=iscsid.service network-online.target
Before=libvirtd.service ahv-define-cvm.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/oci-bm-volumes.sh
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable iscsid.service iscsid.socket oci-bm-volumes.service 2>&1 | grep -vE '^Created|chroot' || true
  info "oci-bm-volumes.service enabled (before ahv-define-cvm and libvirtd)"

  say "c. Keep the Mellanox driver loaded at shutdown (openibd)"
  [ -f /etc/infiniband/openib.conf ] && sed -i 's/^ALLOW_STOP=.*/ALLOW_STOP=no/' /etc/infiniband/openib.conf
  mkdir -p /etc/systemd/system/openibd.service.d
  printf '[Service]\nExecStop=\nExecStop=/bin/true\n' > /etc/systemd/system/openibd.service.d/oci-bm-keep-driver.conf
  info "ALLOW_STOP=$(sed -n 's/^ALLOW_STOP=//p' /etc/infiniband/openib.conf 2>/dev/null), stop = /bin/true"

  say "d. LVM scans only the AHV disk"
  L=/etc/lvm/lvm.conf
  if ! grep -q 'oci-bm global_filter' $L; then
    cp -n $L $L.orig
    sed -i '0,/^devices {/s//devices {\n\t# oci-bm global_filter: only the AHV disk (ahv-host-setup.sh)\n\tglobal_filter = [ "a|^\/dev\/sda3$|", "r|.*|" ]/' $L
  fi
  info "global_filter: $(grep -m1 'global_filter = ' $L | sed 's/^\s*//')"
  if online; then
    vgs --noheadings -o vg_name 2>/dev/null | grep -q ahv && info "VG ahv visible" || echo "WARNING: VG ahv not visible with the filter - check $L"
  fi

  say "f. Persistent journal"
  mkdir -p /var/log/journal
  info "/var/log/journal present (previous boots readable with journalctl -b -1)"

  say "g. Time: OCI NTP service (169.254.169.254)"
  # the private subnet cannot reach pool.ntp.org
  C=/etc/chrony.conf
  if ! grep -q '^server 169.254.169.254' $C; then
    cp -n $C $C.orig
    sed -i 's/^\(server\|pool\) /#&/' $C
    echo 'server 169.254.169.254 iburst' >> $C
  fi
  info "$(grep -E '^(server|pool)' $C | tr '\n' ' ')"
fi

say "e. CVM network path on OCI (oci-cvm-net.sh + timer)"
cat > /usr/local/sbin/oci-cvm-net.sh <<EOF
#!/bin/bash
# OCI network path for the CVM (installed by ahv-host-setup.sh). Idempotent.
CVM_IP=$CVM_IP
BR=ocicvm
EOF
cat >> /usr/local/sbin/oci-cvm-net.sh <<'EOF'
# host traffic: br0 must carry the VNIC MAC (= eth0 MAC)
VNIC_MAC=$(cat /sys/class/net/eth0/address)
ovs-vsctl set bridge br0 other-config:hwaddr=$VNIC_MAC
# bare metal: the iSCSI boot NIC (outside OVS, MAC in /etc/oci-bm-boot-nic)
# shares the subnet with br0. Default route via br0; traffic from the boot
# NIC's IP leaves through the boot NIC (table 100); loose rp_filter.
if [ -f /etc/oci-bm-boot-nic ]; then
  BMAC=$(cat /etc/oci-bm-boot-nic)
  BNIC=$(for n in /sys/class/net/*; do [ "$(cat $n/address)" = "$BMAC" ] && echo ${n##*/}; done | head -1)
  BIP=$(ip -4 -o addr show dev "$BNIC" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  GW=$(sed -n 's/^GATEWAY=//p' /etc/sysconfig/network-scripts/ifcfg-br0 | tr -d '"')
  [ -n "$GW" ] || GW=$(ip route show default | awk '{print $3; exit}')
  BNET=$(ip -4 -o route show dev br0 proto kernel | awk '{print $1; exit}')
  for k in all default br0 $BNIC eth0; do sysctl -qw net.ipv4.conf.$k.rp_filter=2; done
  if [ -n "$BIP" ] && [ -n "$GW" ]; then
    ip rule show | grep -q "from $BIP lookup 100" || ip rule add from $BIP table 100 priority 100
    [ -n "$BNET" ] && ip route replace $BNET dev $BNIC src $BIP table 100
    ip route replace 169.254.0.0/16 dev $BNIC table 100
    ip route replace default via $GW dev $BNIC table 100
    ip link show br0 >/dev/null 2>&1 && ip route replace default via $GW dev br0
  fi
fi
# CVM traffic: plain Linux bridge, routed + proxy-ARP through the host
ip link show $BR >/dev/null 2>&1 || ip link add $BR type bridge
ip link set $BR up
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.br0.proxy_arp=1 net.ipv4.conf.$BR.proxy_arp=1
# the CVM ARPs for the host IP (on br0) through ocicvm: answer it there.
# arp_ignore is max(all, iface), so all=0 and the strict value per NIC.
sysctl -qw net.ipv4.conf.all.arp_ignore=0 net.ipv4.conf.$BR.arp_ignore=0
for k in br0 eth0 ${BNIC:-}; do sysctl -qw net.ipv4.conf.$k.arp_ignore=2; done
# host -> CVM must use the host IP (br0) as source, not the boot NIC's IP
HIP=$(ip -4 -o addr show dev br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
ip route replace $CVM_IP/32 dev $BR ${HIP:+src $HIP}
ip rule show | grep -q "lookup 100" && ip route replace $CVM_IP/32 dev $BR ${HIP:+src $HIP} table 100
iptables -C FORWARD -i $BR -j ACCEPT 2>/dev/null || iptables -I FORWARD -i $BR -j ACCEPT
iptables -C FORWARD -o $BR -j ACCEPT 2>/dev/null || iptables -I FORWARD -o $BR -j ACCEPT
# OCI services (NTP/DNS at 169.254.169.254) are reached via the boot NIC, which
# OCI only lets send from its own IP: masquerade the CVM's traffic there.
# The cluster pushes its NTP servers to this host's chrony.conf.
if [ -n "${BNIC:-}" ]; then
  iptables -t nat -C POSTROUTING -s $CVM_IP -d 169.254.0.0/16 -o $BNIC -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s $CVM_IP -d 169.254.0.0/16 -o $BNIC -j MASQUERADE
fi
CVM=$(virsh list --name | grep -- '-CVM$')
[ -z "$CVM" ] && exit 0
# the CVM's eth0 is the first interface on br0 in its definition
CVM_MAC=$(virsh dumpxml --inactive "$CVM" | python3 -c "
import sys, xml.etree.ElementTree as E
for i in E.parse(sys.stdin).findall('./devices/interface'):
    s = i.find('source')
    if s is not None and s.get('bridge') == 'br0':
        print(i.find('mac').get('address')); break")
TAP=$(virsh domiflist "$CVM" | awk -v m="$CVM_MAC" 'tolower($5)==m {print $1}')
[ -z "$TAP" ] && exit 0
if [ "$(basename "$(readlink /sys/class/net/$TAP/master 2>/dev/null)")" != "$BR" ]; then
  OVSBR=$(ovs-vsctl port-to-br $TAP 2>/dev/null) && ovs-vsctl del-port $OVSBR $TAP
  ip link set $TAP master $BR && ip link set $TAP up
  logger -t oci-cvm-net "moved $TAP ($CVM eth0, $CVM_MAC) to $BR"
fi
EOF
chmod +x /usr/local/sbin/oci-cvm-net.sh
cat > /etc/systemd/system/oci-cvm-net.service <<'EOF'
[Unit]
Description=OCI workaround: route CVM external traffic via the host VNIC
After=network-online.target libvirtd.service openvswitch.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/oci-cvm-net.sh
EOF
cat > /etc/systemd/system/oci-cvm-net.timer <<'EOF'
[Unit]
Description=Re-apply OCI CVM network workaround every minute
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
[Install]
WantedBy=timers.target
EOF
systemctl enable oci-cvm-net.timer 2>&1 | grep -vE '^Created|chroot' || true
info "oci-cvm-net.timer enabled"

if ! online; then
  echo; echo "Install-only done (files written, units enabled)."; exit 0
fi

say "Apply now"
# SELinux labels (AHV enforces; files written from the installer are unlabeled_t)
restorecon -R /etc/sysctl.d /etc/systemd/system /usr/local/sbin /etc/lvm /etc/iscsi /etc/chrony.conf \
  /etc/oci-bm-boot-nic /etc/dracut.conf.d /etc/infiniband /usr/lib/dracut/modules.d/99ocibm \
  /usr/lib/python3.6/nutanix-site-packages/hostsetup/platforms/base /root 2>/dev/null
systemctl daemon-reload
systemctl restart systemd-sysctl chronyd
systemctl restart systemd-journald 2>/dev/null
/usr/local/sbin/oci-bm-volumes.sh 2>/dev/null
systemctl start oci-bm-volumes.service oci-cvm-net.timer
virsh domstate "$CVM" | grep -q running || virsh start "$CVM"
sleep 5
/usr/local/sbin/oci-cvm-net.sh
virsh list --all
info "CVM NIC on ocicvm:"; bridge link show | grep ocicvm | sed 's/^/       /'
info "route: $(ip route get $CVM_IP | head -1)"
echo
echo "Done. The CVM takes 3-5 minutes to boot; then: ping $CVM_IP and ssh nutanix@$CVM_IP"
