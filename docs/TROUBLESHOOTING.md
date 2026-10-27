# Troubleshooting

## Known harmless messages

| Message | Where | Why it is harmless |
|---|---|---|
| `systemd-udevd: giving up waiting for workers`, `device-mapper: remove ioctl on sdX_crypt … busy` | end of every host shutdown | AHV's host-swap disks are served by the CVM and are gone once it is off. The root disk shows "busy" only because it is still mounted at power-off |
| `[FAILED] LSB: Bring up/down networking` | first boot only | Runs before AHV's first-boot network setup has written its configuration |
| failed unit `ahv_first_boot.service` (`/usr/bin/env: 'python': No such file`) | every boot | Legacy first-boot script; the installer marks it unused (`firstboot-method: noop`), AHV's newer services do the work |
| failed unit `systemd-modules-load.service` (`ipmi_si: No such device`) | every boot | OCI bare metal exposes no IPMI to the OS |
| failed unit `ahv-status-cvm.service` (`Permission denied (publickey)`), ~25 min after boot | every boot after `cluster create` | AHV's status monitor logs in to the CVM with the generic factory key, which AOS removes when the cluster is created |
| `setup_rdma.py: No ports reserved for iSER` | boot | iSER is not used |
| `SyntaxWarning: "is not" with a literal` | installer | Python warning in Nutanix's installer code |

`validate-ahv-bm.sh` already ignores the three stock failed units.

## Installation problems

| Symptom | Cause / fix |
|---|---|
| `00-prereqs`: `sshpass could not be installed` | Enable EPEL: `dnf install oracle-epel-release-el10` or `dnf config-manager --enable ol10_developer_EPEL`, re-run |
| `02-build-iso`: `config change would alter built-in options - stop` | The kernel configuration extracted from the ISO differs from what the script expects — probably a different CE ISO version. The procedure is validated for `fnd_5.6.1 / aos_6.8.1` only |
| `02-build-iso`: `vermagic mismatch` | Same: another installer kernel. Adjust `KV`/`VERMAGIC` in `remaster-ce-iso-bm.sh` only if you know what you are doing |
| `02-build-iso`: module build errors | See `WORK_DIR/remaster/build.log`; usually a missing `-devel` package or a newer gcc. The script already strips `-Werror` from the build helpers |
| `03-import-image`: image stays `IMPORTING` for more than an hour | Normal for a 6.7 GB object can be 30 min; check the image in the OCI console. An import error ends in a non-`AVAILABLE` state and the script stops |
| `04-launch-instance`: `Out of host capacity` | No `BM.Standard3.64` capacity in that AD. Set `AD` in the config to another AD (volumes and instance must share it) and re-run |
| `05-install`: waiting for installer SSH never ends | Watch the console (set `CONSOLE_SSH_PUBKEY_FILE`, or create a console connection in the OCI console). Expected console lines: `oci-bm: iBFT found, logging in to the iSCSI boot volume`, `oci-bm: boot volume visible as sda`. If `NOT visible`: the iSCSI login from the initrd failed — check the subnet's security rules allow the node to reach `169.254.0.2:3260` (they do by default) and that the image was imported from the *remastered* ISO. `Failed to find Phoenix ISO` + kernel panic = the stock ISO was used |
| `05-install`: `ce-bm-prep.sh` shows `patches applied: 0` or `PCI-ID patch: 0` | A different installer version — the sed patterns did not match. Validated for `fnd_5.6.1` only |
| `05-install`: the installer does not show `sdb`/`sdc` | The block volume logins failed. On the installer: `cat /tmp/oci-bm.env`, `iscsiadm -m session`, `cat /root/<node>.iscsi`; check the volumes are `ATTACHED` in OCI |
| `05-install`: the installer hangs looking for an old CVM | `/tmp/phoenix_iso_marker` missing — the wrapper did not see `sda`. Re-boot the installer (`oci compute instance action --action RESET`) and re-run step 05 |
| `06-finalize`: `initramfs is missing …` | `dracut` did not include the module. Check `/usr/lib/dracut/modules.d/99ocibm/` exists in the chroot and the AHV kernel has `iscsi_tcp.ko` |
| `06-finalize`: `mount: … already mounted` on a re-run | A previous run died midway. On the installer: `umount -R /mnt/ahv; vgchange -an ahv`, then re-run |
| `07-create-cluster` (or any step): `waiting for … SSH` never ends although you can log in by hand | The wait prints the ssh error every 4th attempt; read it. Reproduce on the admin host with `sshpass -p 'nutanix/4u' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no root@<HOST_IP> true; echo $?`. Exit 5 = password rejected: `CE_PASSWORD` differs from the real password, or root is locked by AHV's `pam_faillock` after repeated failures (on the host console: `faillock --user root --reset`, or wait ~15 min). "Too many authentication failures" / exit 4 = ssh offered local keys before the password (fixed in `common.sh` with `PubkeyAuthentication=no`; update the repo). Exit 255 with "Connection refused/timed out" = sshd not up yet or a security-list rule blocks port 22 from the admin host to the node's subnet |
| `07-create-cluster`: host SSH never comes up | On the console: does AHV boot (`oci-bm: … logging in to iqn.2015-02.oracle.boot:uefi`) or does it drop into the dracut emergency shell? In the shell, `cat /tmp/oci-bm.done`, `ip addr`, `dmesg \| grep -i iscsi`. If the hook never found the NIC: the MAC in `/etc/oci-bm-boot-nic` must be the primary VNIC's MAC |
| `07-create-cluster`: host up, no CVM defined after 30 min | `journalctl -u ahv-define-cvm -u oci-bm-volumes` on the host. Usually the volumes were not logged in: `iscsiadm -m session`; then `scripts/ops/reapply-host-setup.sh` (it logs them in and re-runs `ahv-define-cvm`) |
| `07-create-cluster`: CVM pings, `genesis status` never answers | The CVM is still booting (3–5 min after start) or its network path is wrong: on the host `ip route get <CVM_IP>` must say `dev ocicvm src <HOST_IP>`; `bridge link show \| grep ocicvm` must list the CVM's tap. `systemctl start oci-cvm-net.service` |
| `cluster create` fails with `Zookeeper host port list is not set` | Running without a login shell. The scripts use `bash -lc`; by hand, do the same |
| `time synchronised` FAIL | Expected until the cluster exists. After `cluster create` the cluster pushes `169.254.169.254` to the host's chrony. Check `chronyc sources` on the host; the CVM reaches NTP through the NAT rule on the boot NIC (`iptables -t nat -L POSTROUTING`) |

## When a health check fails

1. `scripts/ops/validate.sh` — see which checks fail.
2. `scripts/ops/reapply-host-setup.sh` — rewrites every setting, fixes SELinux labels, logs in volumes, starts the CVM if needed, applies the network settings. Safe to repeat.
3. `scripts/ops/validate.sh` again.
4. Still failing: on the host, `journalctl -b -p err`, `journalctl -u oci-bm-volumes -u oci-cvm-net -u ahv-define-cvm`, `iscsiadm -m session -P3`, `ovs-vsctl show`, `ip rule; ip route show table 100`. The previous boot's log is in `journalctl -b -1` (persistent journal).

## Useful places

| On | What | Where |
|---|---|---|
| installer | iBFT values the wrapper read | `/tmp/oci-bm.env` |
| installer | installer log | `/root/phoenix/*.log`, `screen -r` if the UI is running |
| host | boot NIC MAC that AHV must not touch | `/etc/oci-bm-boot-nic` |
| host | block-volume records | `/root/oci-bm-volumes.iscsi`, `iscsiadm -m node` |
| host | OCI scripts | `/usr/local/sbin/oci-bm-volumes.sh`, `/usr/local/sbin/oci-cvm-net.sh` |
| host | initramfs hook | `/usr/lib/dracut/modules.d/99ocibm/oci-bm-iscsi.sh`; `lsinitrd /boot/initramfs-$(uname -r).img \| grep oci-bm` |
| host | AHV first-boot config and log | `/root/firstboot/first_boot_config.json`, `/var/log/firstboot.log` |
| CVM | genesis / cluster | `genesis status`, `cluster status`, `~/data/logs/genesis.out` |
| admin host | node state | `state/<node>.env`, `state/<node>.iscsi`, `state/<node>.*.done` |
