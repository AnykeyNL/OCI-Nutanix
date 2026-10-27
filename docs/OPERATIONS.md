# Operations — power, lifecycle, verification

What happens once the node is running: every way the server can be shut down, rebooted or reset, what each one does to AHV, the CVM and the cluster, how long recovery takes, and which script to use. Measured on `BM.Standard3.64`, AHV 20230302.101026, AOS 6.8.1, single-node RF1 cluster.

## Use the scripts, not the OCI console buttons

| What you want | Command | Time until the cluster is fully up |
|---|---|---|
| Health check | `scripts/ops/validate.sh` | — |
| Clean reboot | `scripts/ops/power.sh reboot` | about 15 min; the cluster starts by itself |
| Clean power-off | `scripts/ops/power.sh shutdown` | — (instance ends `STOPPED`) |
| Power on | `scripts/ops/power.sh start` | about 20 min after `START` |
| Maintenance reboot with the cluster stopped | `scripts/ops/power.sh reboot --stop-cluster` | about 15 min + `cluster start` (done by the script) |
| Hung host | `scripts/ops/power.sh reset --force` | about 15 min (services replay their logs) |
| Status | `scripts/ops/power.sh status`, `scripts/ops/cluster.sh status` | — |

**Never use the OCI console "Stop" or "Reboot" with "Force" unticked** (`SOFTSTOP` / `SOFTRESET`). OCI presses the virtual power button and waits about 15 minutes for the OS to power off. AHV ignores the power button by design (`HandlePowerKey=ignore` in `/etc/systemd/logind.conf.d/50-nutanix-logind.conf`, so a button press cannot take down a node and its CVM). OCI then forces the stop or reset with the CVM still running. If someone already pressed Stop, there are about 15 minutes to run `scripts/ops/power.sh shutdown` and turn it into a clean power-off.

## Scenarios

| # | What you do | Signal the server gets | CVM shut down cleanly? | Time until fully up | Comes back by itself? | Recommendation |
|---|---|---|---|---|---|---|
| S1 | Planned reboot: `cluster stop` → `cvm_shutdown -P now` → `reboot` | OS reboot | Yes | ~15 min (+ `cluster start`) | Host and CVM yes; the cluster waits for `cluster start` | `power.sh reboot --stop-cluster` |
| S2 | Planned power-off: as S1, then `shutdown -h now`; later OCI Start | OS power-off | Yes | ~20 min after Start (+ `cluster start`) | Host and CVM yes; the cluster waits for `cluster start` | `power.sh shutdown --stop-cluster`, then `power.sh start` |
| S3 | `cvm_shutdown -P now` without `cluster stop`, then reboot or power-off | OS reboot / power-off | Yes | ~15 min | Yes, fully: the cluster starts by itself | **`power.sh reboot` / `power.sh shutdown`** (default; quickest clean restart on a single node) |
| S4 | `reboot` or `shutdown` on the host with the CVM still running | OS reboot | No: the CVM is cut off | 15–20 min | Yes, fully | Avoid; run `cvm_shutdown` first |
| S5 | OCI console Stop, Force unticked (`SOFTSTOP`) | ACPI power button: ignored by AHV | No, unless you shut down yourself within ~15 min | power-off after ~15 min; then as S2 after Start | Yes, after Start | Avoid; use S2 |
| S6 | OCI console Reboot, Force unticked (`SOFTRESET`) | ACPI power button: ignored by AHV | No: hard reset after ~15 min | ~17 min wait, then ~15 min | Yes, fully | Avoid; use S1 or S3 |
| S7 | OCI console Reboot with Force (`RESET`) | Immediate hardware reset | No | ~15 min | Yes, fully | Only if the host is hung (`power.sh reset --force`) |
| S8 | OCI console Stop with Force (`STOP`) | Immediate power-off | No | ~15 min after Start | Yes, after Start | Only if the host is hung (`power.sh hardstop --force`) |
| S9 | Unplanned: OCI host failure, power loss, OCI-initiated reboot | Same as S7/S8 (S6 if OCI asks for a soft reboot first) | No | ~15 min | Yes | — |

**"Comes back by itself"** means that after the event, without any command, all of this returned: AHV logged in to its iSCSI boot volume and booted; the block volumes were logged in with OCI's timeouts; `br0`, the routing and the CVM path were restored; time was synchronised; the CVM was defined and started. The only manual step that ever appears is `cluster start`, and only after S1 and S2 because those deliberately put the cluster into the "stop" state (`power.sh` does it for you when you used `--stop-cluster`).

### Why the times are what they are

| Phase | Typical time | Why |
|---|---|---|
| `cluster stop` | 10–20 s | Stops the 40+ AOS services |
| `cvm_shutdown -P now` | ~20 s of services, then the CVM powers off | Hands storage off and stops the remaining services |
| AHV host shutdown | 2–3 min | The last ~2.5 min are udev waiting (`giving up waiting for workers`) on AHV's encrypted host-swap disks, served by the CVM over iSCSI and unreachable once it is off. Harmless |
| Bare-metal firmware + AHV boot | 5–8 min | Server POST, iSCSI firmware boot, initramfs iSCSI login, AHV services |
| CVM boot | 3–5 min | The CVM starts once its volumes are logged in |
| Cluster services after a clean stop | 1–2 min after `cluster start` | — |
| Cluster services after the CVM was cut off (S4, S6–S9) | 10–20 min | Genesis restarts every service; Cassandra and Stargate first check and replay their logs |
| OCI soft stop or reset waiting | ~15 min | OCI waits for the OS to power off; AHV ignores the button. Measured: `SOFTSTOP` → `STOPPED` in 14 min; `SOFTRESET` → `RUNNING` in 17 min |
| OCI hard reset | ~1 min | Measured `RESET` → `RUNNING` in 63 s |

### Doing it by hand

```bash
# S1 — planned reboot, cluster stopped
scripts/ops/ssh.sh cvm                      # as nutanix
  cluster stop                              # type "I agree"
  cvm_shutdown -P now
scripts/ops/ssh.sh host                     # as root, once `virsh list --all` shows the CVM "shut off"
  reboot
# ~10 min later, on the CVM
  cluster start

# S2 — planned power-off: as S1, but `shutdown -h now` on the host instead of reboot,
#      then `oci compute instance action --instance-id <id> --action START`, then `cluster start`.

# S3 — quick clean restart (single node): skip `cluster stop`; the cluster starts by itself.
```

## Single node now, multi-node later

| Situation | `cluster stop`? | Procedure |
|---|---|---|
| This single-node cluster | Yes for S1/S2, or skip it and use S3 | The node is the cluster: any node shutdown is a cluster shutdown |
| One node of a 3- or 4-node cluster | No — that would stop the whole cluster | `acli host.enter_maintenance_mode <host>` (live-migrates its VMs) → `cvm_shutdown -P now` → reboot or power off → `acli host.exit_maintenance_mode <host>` → wait for Data Resiliency OK before the next node |
| Whole multi-node cluster | Yes, once | Shut down the user VMs → `cluster stop` → `cvm_shutdown -P now` on every CVM → power off the hosts; to restart, power on, then `cluster start` once |

On a single-node RF1 cluster every crash (S4, S6–S9) is a real outage for the VMs on it.

## Verification checklist

`scripts/ops/validate.sh` runs all of this at once (expected `ALL PASS`, 30 checks). The individual commands, on the AHV host unless noted:

| Check | Command | Expected |
|---|---|---|
| iSCSI sessions | `iscsiadm -m session` | boot volume, CVM volume, data volume (+ host-swap when the CVM is up) |
| Boot NIC untouched | `ip -br addr show ahv0` | `IBFT_IP/24`, not in `ovs-vsctl show` |
| Bridge | `ovs-vsctl show`; `cat /sys/class/net/br0/address` | `br0` with port `eth0`; MAC = NIC1's |
| Routing | `ip route; ip rule` | default via `br0`; rule `from IBFT_IP lookup 100` |
| CVM path | `ip route get <CVM_IP>` | `dev ocicvm src <HOST_IP>` |
| Host ↔ CVM | `ping <CVM_IP>` on the host; `ping <HOST_IP>` on the CVM | both answer |
| Services | `systemctl is-enabled oci-bm-volumes iscsid iscsi iscsi-shutdown` | enabled, enabled, masked, masked |
| Cluster | `cluster status` (CVM) | all services UP |
| Host in cluster | `acli host.list` (CVM) | `AcropolisNormal`, Connected, Schedulable |
| iSCSI timeouts | `cat /sys/class/iscsi_session/session*/recovery_tmo` | `6000` for all three |
| Time | `chronyc tracking` | `Reference ID … (169.254.169.254)`, `Leap status: Normal` |
| Prism | `https://<CVM_IP>:9440` | dashboard, 612.56 GiB |

## Command reference

| Purpose | Command |
|---|---|
| Shell on the installer / AHV host / CVM | `scripts/ops/ssh.sh installer` / `host` / `cvm` |
| Cluster status | `scripts/ops/cluster.sh status` — or `cluster status` on the CVM |
| Planned CVM shutdown | `cvm_shutdown -P now` on the CVM (login shell) |
| Cluster stop / start | `scripts/ops/cluster.sh stop` (answer `I agree`) / `start` |
| Host health check | `scripts/ops/validate.sh` — or `bash /root/validate-ahv-bm.sh` on the host |
| Re-apply all host settings | `scripts/ops/reapply-host-setup.sh` — or `bash /root/ahv-host-setup.sh <CVM_IP>` on the host |
| Instance power | `scripts/ops/power.sh …` — avoid `oci compute instance action --action SOFTSTOP\|SOFTRESET` |
| Host list | `acli host.list` on the CVM |
| iSCSI sessions | `iscsiadm -m session` on the host |
| Re-apply OCI networking | `systemctl start oci-cvm-net.service` on the host |
| Boot-volume backup | `oci bv boot-volume-backup create --boot-volume-id <id> --display-name <name>` |

Over SSH, `cluster`, `ncli`, `acli` and `cvm_shutdown` need a login shell (`bash -lc '…'`); without one they fail with `Zookeeper host port list is not set`. The `ops/` scripts take care of that.
