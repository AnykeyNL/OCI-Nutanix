# Installation guide

Step by step, from the stock CE ISO in an OCI bucket to a running single-node Nutanix cluster on an OCI bare-metal server. Every step is a script; this page tells you what each one does, what to expect, and what to do when it fails.

## 0. Before you start

**You need**

| Item | Detail |
|---|---|
| Nutanix CE ISO | `phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso` (6.7 GB) from the [Nutanix CE download page](https://www.nutanix.com/products/community-edition) (free NEXT account), uploaded to an OCI Object Storage bucket |
| OCI | A compartment, a VCN with a **private subnet**, quota for `BM.Standard3.64` in one AD, a bucket (for the ISO; the remastered ISO goes to the same or another bucket) |
| Admin host | Oracle Linux 10 instance in the same VCN (or peered), OCI CLI configured for a user who can manage compute, block storage, networking and object storage in that compartment; ~25 GB free disk; internet access to `cdn.kernel.org` (kernel source) and the OL yum repos |
| Network rules | The subnet's security list / NSG must allow, from the admin host: SSH (22) to the subnet, ICMP, and 9440 if you want Prism from there. Inside the subnet, allow all traffic between the node's IPs (host, CVM, iSCSI NIC). |

**Configure**

```bash
cp config/oci-nutanix.env.example config/oci-nutanix.env
vi config/oci-nutanix.env
```

Required: `COMPARTMENT_ID`, `SUBNET_ID`, `SRC_BUCKET` (and `SRC_ISO_OBJECT` if the object is not called like the stock ISO). Everything else has a sensible default; see the comments in the file. The Object Storage namespace, the region and the AD are discovered from the OCI CLI (override `AD` if the first AD has no bare-metal capacity).

All scripts run as root on the admin host from the repository directory. Each is idempotent: re-run it after fixing a problem. `scripts/install-all.sh` runs them all; `--from N` resumes.

## 1. Admin host prerequisites — `scripts/00-prereqs.sh`

Installs `xorriso cpio gzip xz gcc make flex bison bc perl elfutils-libelf-devel openssl-devel iscsi-initiator-utils sshpass jq …`, checks the OCI CLI, the compartment, the subnet, that the ISO object exists, and the free space in `WORK_DIR`.

If `sshpass` is not found, enable EPEL (`dnf install oracle-epel-release-el10` or `dnf config-manager --enable ol10_developer_EPEL`) and re-run.

## 2. Fetch the ISO — `scripts/01-fetch-iso.sh`

Downloads `SRC_BUCKET/SRC_ISO_OBJECT` to `WORK_DIR` (multipart, parallel). Skipped if a file of the same size is already there.

## 3. Build the bare-metal ISO — `scripts/02-build-iso.sh`

Runs `scripts/build/remaster-ce-iso-bm.sh build`. 10–20 minutes. What it does:

1. Extracts the installer kernel and initrd from the ISO and reads Nutanix's kernel configuration out of the kernel image (IKCONFIG).
2. Downloads Linux 5.10.2 source and builds the iSCSI modules the installer kernel lacks (`scsi_transport_iscsi`, `libiscsi`, `libiscsi_tcp`, `iscsi_tcp`, plus `crc32c`/`md5` if needed) with that exact configuration. It refuses to continue if any built-in option would change; the vermagic must be `5.10.2 SMP mod_unload`.
3. Compiles `ibft-parse` (reads the firmware's iSCSI Boot Firmware Table from ACPI).
4. Adds modules, `iscsistart` (with its own libc), `ibft-parse`, a `/ce_installer` boot wrapper (logs in to the boot volume when an iBFT is present, then starts the original installer) and two systemd units (enable SSH, keep the iSCSI route) to the initrd.
5. Repacks the initrd and writes the ISO with the original boot setup. Kernel, GRUB, squashfs, AHV and AOS packages are byte-identical.

Expected at the end:

```
-> wrapper self-check: syntax ok, all commands present
-> initrd: 49M (kernel unchanged)
Writing to '…/nutanix-ce-ocibm-v1.iso' completed successfully.
```

Failures are almost always toolchain related (`build.log` in `WORK_DIR/remaster`). `--force` rebuilds.

## 4. Upload and import the image — `scripts/03-import-image.sh`

Uploads `<IMAGE_NAME>.iso` to `IMG_BUCKET`, imports it as a custom image (`--launch-mode NATIVE`), waits for `AVAILABLE` (10–30 minutes), sets the firmware capability to `UEFI_64` and adds `SHAPE` to the compatible shapes. Writes `state/image-<IMAGE_NAME>.env`.

Bump `IMAGE_NAME` whenever you rebuild the ISO; the old image is left in place.

## 5. Launch the bare-metal instance — `scripts/04-launch-instance.sh`

Creates, in `AD`:

- the instance `NODE_NAME` (`SHAPE`) from the custom image with a `BOOT_VOLUME_GB` boot volume (the firmware boots it over iSCSI; it first holds the installer, later AHV);
- two block volumes, `NODE_NAME-cvm` (`CVM_VOLUME_GB`) and `NODE_NAME-data` (`DATA_VOLUME_GB`), attached as **iSCSI** (the only attachment type on bare metal); their IQN/IP/port go to `state/<node>.iscsi`;
- a second VNIC on physical **NIC1** with a primary IP (AHV host) and a secondary IP (CVM).

It writes `state/<node>.env` with `INSTANCE_ID`, `IBFT_IP` (primary VNIC, iSCSI only), `HOST_IP`, `CVM_IP`, MACs, netmask and gateway. Bare-metal provisioning takes 10–15 minutes. Set `CONSOLE_SSH_PUBKEY_FILE` in the config to get a VNC console connection string for watching the boot (no input is ever needed).

## 6. Prepare and run the installer — `scripts/05-install.sh`

1. Waits for SSH on `IBFT_IP`. The bare-metal ISO's wrapper logs in to the boot volume from the iBFT, starts the CE installer and enables SSH; no console interaction.
2. Stops the auto-started installer UI (`screen -S centos_phoenix -X quit`), otherwise an SSH login attaches to it.
3. Copies `scripts/remote/*` and `state/<node>.iscsi`, runs `ce-bm-prep.sh` on the installer. Expected: both volumes logged in; `sda 100G`, `sdb 400G`, `sdc 600G`, all `TRAN=iscsi`; `patches applied: 5`; `PCI-ID patch: 1`; `driver-list patch: 1`; `sda mounts: 0`; `HYP=` and `NOS=` found. (What the patches do: [ARCHITECTURE.md](ARCHITECTURE.md#installer-adaptations-in-ram).)
4. Prints the values to enter and opens `./phoenix` over `ssh -t`. **This is the only interactive step.**

In the installer:

| Field | Value |
|---|---|
| Hypervisor boot (H) | `sda` — the boot volume (100 GB, shown as ~107 GB) |
| CVM boot (C) | `sdb` — move to it, press `c` |
| Data (D) | `sdc` — move to it, press `d` |
| Host IP / CVM IP | `HOST_IP` / `CVM_IP` from `state/<node>.env` (the script prints them). **Not** `IBFT_IP`. |
| Subnet mask / Gateway | printed by the script |
| Create single-node cluster | leave off — step 07 creates it |

Scroll to the end of the EULA, accept, start. About 15 minutes; ends with `Imaging process completed successfully!`. **Answer `N` to the reboot question.** The script then checks that the `ahv` volume group exists on `sda` and asks you to confirm.

If the installer fails, fix the cause and re-run `scripts/05-install.sh`; the prep is re-applied (idempotent) and the installer re-opened. If the server was rebooted meanwhile, the in-RAM prep is gone and is simply applied again.

## 7. Finalize and reboot — `scripts/06-finalize.sh`

Runs `ahv-bm-finalize.sh` inside the installer, on the installed AHV (chroot of `sda`):

- dracut module `99ocibm` + regenerated initramfs: logs in to the boot volume in early boot with the iBFT values (boot NIC by MAC, static IP, `iscsistart`); verified with `lsinitrd`;
- `ahv-host-setup.sh --install-only`: OCI iSCSI timeouts, `oci-bm-volumes.service` (logs in the CVM/data volumes before the CVM is defined), Mellanox driver kept at shutdown, LVM filter, persistent journal, chrony → OCI NTP, `oci-cvm-net` timer (CVM routing, br0 MAC);
- the boot NIC excluded from AHV's network setup (7-line filter in `hostsetup/.../network.py`, MAC in `/etc/oci-bm-boot-nic`), `iscsi`/`iscsi-shutdown` masked, `iscsid` enabled;
- `br0` uplink pinned to NIC1 in `first_boot_config.json`;
- SELinux labels for everything written.

Expected highlights: `initramfs has usr/sbin/iscsistart / 90-oci-bm-iscsi.sh / iscsi_tcp.ko / mlx5_core.ko`, `hostsetup patched`, `vswitches: [{'name': 'br0', 'uplinks': ['<NIC1 MAC>'], …}]`, `SELinux labels set`, `Done. Now: reboot`.

Then (if `BACKUP_BOOT_VOLUME=yes`) a boot-volume backup `<node>-finalized` is taken, and the server is rebooted into AHV. On the console: `oci-bm: ahv0 up, logging in to iqn.2015-02.oracle.boot:uefi`, then AHV boots and runs its first boot. AHV's network log shows the intended result:

```
setting nic ahv1 as eth0
nic ahv0 does not match with uplink in vswitch br0. Dropping from this vswitch.
Adding ['eth0'] to the list of uplinks for vswitch br0
```

## 8. Cluster — `scripts/07-create-cluster.sh`

Nothing is needed on the host: during the first boot AHV logs in the two volumes, defines and starts the CVM, and the network timer sets up routing and the CVM path. The script:

1. waits for SSH on `HOST_IP` (15–20 minutes after the reboot);
2. runs `validate-ahv-bm.sh` (30 checks). Until the cluster exists, *time synchronised* and the CVM/cluster checks may fail; anything else failing → `scripts/ops/reapply-host-setup.sh`, then re-run;
3. waits for the CVM to ping and for `genesis status`;
4. `cluster -s <CVM_IP> --redundancy_factor=1 create` (skipped if a cluster exists), then `ncli cluster add-to-ntp-servers` / `add-to-name-servers` with `169.254.169.254`;
5. final check and summary.

Expected: `The state of the cluster: start`, 45 services `UP`, `ALL PASS` from the health check (chrony shows `Leap status: Normal` once the cluster pushed its NTP server to the host).

## 9. Prism

`https://<CVM_IP>:9440` from a machine that can reach the subnet. Log in as `admin` / `nutanix/4u`, set a new password, complete the CE NEXT-account registration. The dashboard shows 1 host, model `CommunityEdition`, 612.56 GiB storage. `acli host.list` on the CVM shows the host `AcropolisNormal`, `Schedulable: True`.

## Re-running, resuming, starting over

- Every script checks what is already done (file sizes, image state, instance state, markers in `state/`). Re-run freely.
- `scripts/install-all.sh --from 5` continues at step 05.
- To rebuild the node: `scripts/ops/destroy.sh --yes` (terminates the instance, deletes the volumes and the node state), then `scripts/install-all.sh --from 4`.
- To use a new ISO build: bump `IMAGE_NAME`, then `--from 2`.
- The markers in `state/<node>.*.done` record that steps 05/06/07 completed; delete one to force that step to run again.
