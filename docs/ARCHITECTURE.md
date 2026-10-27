# Architecture — how Nutanix CE runs on OCI bare metal

Condensed from the reference implementation (v3, October 2026). Read this to understand *why* the scripts do what they do.

## The problem

OCI bare-metal servers have **no local disks**. The boot volume and all block volumes are iSCSI. The UEFI firmware logs in to the boot volume (target `iqn.2015-02.oracle.boot:uefi` at `169.254.0.2:3260`, LUN 1, through physical NIC0), loads the boot loader, kernel and initramfs, and publishes the connection parameters in the **iBFT** (iSCSI Boot Firmware Table, an ACPI table). From then on the operating system must log in to its own root disk again.

Nutanix expects the opposite: local SATA/SAS/NVMe disks behind a PCI controller, and AHV owning every physical NIC.

| Area | What OCI bare metal does differently | What this project does |
|---|---|---|
| Installation media | The CE installer kernel (5.10.2) has no iSCSI driver and cannot see the disk it booted from | Builds the missing iSCSI modules for that exact kernel and adds them, a login helper and an iBFT reader to the installer's initrd. Kernel, GRUB and all Nutanix files unchanged |
| Installer hardware detection | Disks sit behind an iSCSI session, not a PCI storage controller | Three small in-memory adjustments so iSCSI disks are treated like disks with an unknown controller |
| AHV boot | AHV's initramfs does not log in to the iSCSI boot volume | An added dracut module logs in with the values the firmware published |
| AHV networking | Root-disk traffic and VM traffic would share the server's NICs | Storage on NIC0 (kept out of AHV's network management), host and CVM on NIC1 via a second VNIC |

## Target architecture

```
OCI bare-metal instance BM.Standard3.64 — AHV is the operating system
┌──────────────────────────────────────────────────────────────────────────┐
│  CVM (AOS 6.8.1)   eth0 <CVM_IP> (external)   eth1 192.168.5.2 (host link)│
│                    disks: CVM volume (sdb) + data volume (sdc) by WWN     │
│                                                                          │
│  AHV host networking                                                     │
│    br0 (OVS)      <HOST_IP>  ← uplink eth0 = NIC1, MAC pinned to VNIC2   │
│    ocicvm (Linux bridge) → CVM eth0, routed + proxy-ARP through br0      │
│    ahv0 = NIC0    <IBFT_IP>  iSCSI only, not in OVS, routing table 100   │
│                                                                          │
│  iSCSI sessions (all over NIC0 to OCI's 169.254.x.x targets)             │
│    boot volume  100 GB  169.254.0.2:3260  → sda  (EFI, /boot, LVM "ahv") │
│    CVM volume   400 GB  169.254.2.x:3260  → sdb                          │
│    data volume  600 GB  169.254.2.y:3260  → sdc                          │
└──────────────────────────────────────────────────────────────────────────┘
   NIC0 · primary VNIC  · <IBFT_IP>                  NIC1 · secondary VNIC · <HOST_IP> + <CVM_IP>
```

| Component | Value |
|---|---|
| Boot volume | 100 GB, holds AHV (`sda1` EFI, `sda2` /boot, `sda3` LVM VG `ahv`) — logged in by the firmware, then by the `99ocibm` initramfs hook |
| CVM volume | 400 GB iSCSI block volume — `sdb`, CVM boot disk + metadata (SSD tier) — logged in by `oci-bm-volumes.service` |
| Data volume | 600 GB iSCSI block volume — `sdc`, storage pool — logged in by `oci-bm-volumes.service` |
| NIC0 / primary VNIC | iSCSI only; AHV name `ahv0`; never renamed, never in OVS |
| NIC1 / secondary VNIC | primary IP = AHV host (`br0`), secondary IP = CVM |
| Cluster | single node, RF1, NTP and DNS `169.254.169.254` (OCI services) |

## Boot chains

**A. CE installer (step 05)**
firmware iSCSI boot (iBFT) → stock GRUB → stock kernel 5.10.2 → **`/ce_installer` wrapper (added)**: reads the iBFT, loads the NIC and iSCSI modules, configures the boot NIC, `iscsistart` → `sda` → stock `livecd.sh` finds the ISO by label on `sda` → Phoenix (CentOS) with **our units**: SSH enabled, iSCSI path kept.

**B. AHV (from step 06 on)**
firmware → `BOOTX64.EFI` from the boot volume → stock AHV GRUB → AHV kernel 5.10.194 → **dracut `99ocibm` (added)**: boot NIC by MAC, IP, `iscsistart` → `sda` → stock dracut LVM → `/dev/mapper/ahv-root` → AHV systemd: first boot, OVS, CVM (+ our OCI services).

Red Hat CoreOS and Oracle Linux do the same thing on OCI bare metal with `rd.iscsi.firmware=1`; AHV's initramfs was built for a VM-style disk, so the hook is added explicitly.

## What was changed, and what was not

| | CE ISO (media) | Installer at run time (RAM) | Installed AHV host (disk) |
|---|---|---|---|
| **Unchanged** | installer kernel, GRUB, EFI image, `squashfs.img`, AHV installer ISO, AOS package, `livecd.sh` (kernel md5 and grub.cfg verified equal) | installer workflow and UI, AHV/AOS images, CVM imaging, first-boot config generation, disk layout | AHV kernel, packages, GRUB; AOS 6.8.1 in the CVM; cluster services, Prism, OVS, libvirt |
| **Added / adjusted** | 5 iSCSI kernel modules, `iscsistart` + `ibft-parse`, `/ce_installer` wrapper, 2 systemd units, `/tmp/phoenix_iso_marker` | boot disk = `sda`; disk-controller walk stops at `/sys/devices`; PCI IDs optional for iSCSI disks; empty controller driver skipped; volumes flagged SSD; ISO → RAM | dracut module `99ocibm`; 7-line filter in `hostsetup/.../network.py`; `iscsi`/`iscsi-shutdown` masked; `oci-bm-volumes.service`; `br0` uplink in `first_boot_config.json`; `oci-cvm-net` timer; iscsid/LVM/chrony/sysctl settings |

Only one file inside the ISO changes: the installer's `/boot/initrd`, repacked with all original contents plus the additions. No binaries, packages or kernels are replaced; module signing is not enforced and symbol versioning is off in the Nutanix kernel, so the freshly built modules load.

### Changes to the CE ISO (`remaster-ce-iso-bm.sh`)

| Addition | Where in the initrd | Why |
|---|---|---|
| `scsi_transport_iscsi.ko`, `libiscsi.ko`, `libiscsi_tcp.ko`, `iscsi_tcp.ko`, `md5.ko` | `/lib/oci-bm/modules/` | The installer kernel was built with `CONFIG_ISCSI_TCP` and `CONFIG_SCSI_ISCSI_ATTRS` disabled. Compiled from Linux 5.10.2 with the configuration embedded in Nutanix's kernel (IKCONFIG); vermagic `5.10.2 SMP mod_unload` |
| `iscsistart` with its libraries and loader | `/lib/oci-bm/{bin,lib,sbin}` | One iSCSI login without a daemon; independent of the installer's libc |
| `ibft-parse` | `/lib/oci-bm/bin` | Reads the iBFT from `/sys/firmware/acpi/tables/iBFT` and prints initiator, target, IP, port, LUN, MAC. The kernel's `iscsi_ibft` driver would need a built-in option |
| `/ce_installer` wrapper | initrd root | The kernel starts `init=/ce_installer`. Reads the iBFT, loads drivers, configures the boot NIC, logs in (→ `sda`), then starts Nutanix's `livecd.sh` through a link named `ce_installer` (it selects CE mode from that name). Without an iBFT it does nothing |
| `/tmp/phoenix_iso_marker` | created by the wrapper | Tells the installer it was booted from the Phoenix ISO (normally detected from a CD-ROM); otherwise it searches the disks for an older CVM |
| `oci-bm-ssh.service`, `oci-bm-path.service` | `/lib/systemd/system` | After the installer switches into its CentOS environment: run Nutanix's `enable_ssh`, keep the route to the iSCSI target |

### Installer adaptations in RAM (`ce-bm-prep.sh`)

| Adaptation | Why |
|---|---|
| Log in to the two block volumes (`iscsistart`) | They become `sdb` and `sdc` |
| Boot-disk detection falls back to `sda` (`sysUtil.py`) | Nutanix looks for a SATADOM/M.2; here the boot volume is the hypervisor disk |
| Disk-controller walk stops at `/sys/devices` (`disk_info.py`) | The walk up from a disk to its PCI controller never ends for iSCSI disks; one line ends it, the disk is listed with an unknown controller |
| PCI vendor/device read optional for iSCSI disks | Same function; skipped like the installer already does for USB disks |
| Empty controller driver skipped (`customize_kvm.py`) | The AHV customisation un-blacklists the CVM disks' controller drivers; iSCSI disks have none |
| Volumes flagged SSD; ISO copied to RAM; `vgchange`/`mount` wrappers | Volumes report "rotational"; the ISO lives on the boot volume AHV is installed onto; LVM on `sda3` is accessed through a loop device |

All of it disappears when the installer reboots.

### Adaptations on the installed AHV host (`ahv-bm-finalize.sh`, `ahv-host-setup.sh`)

| Adaptation | File / unit | Why |
|---|---|---|
| dracut module `99ocibm` + regenerated initramfs | `/usr/lib/dracut/modules.d/99ocibm/` | Early-boot login to the boot volume: finds NIC0 by MAC, sets its IP and the route to `169.254.0.0/16`, `iscsistart` with the iBFT values |
| Storage NIC excluded from AHV network setup | `/etc/oci-bm-boot-nic` + 7 lines in `hostsetup/platforms/base/network.py` | AHV's first boot renames, configures and bridges every PCI NIC. NIC0 carries the root disk and must never be touched |
| `br0` uplink pinned to NIC1 | `first_boot_config.json` (`vswitches`) | Otherwise AHV adds every Mellanox port to `br0` |
| `iscsi.service`, `iscsi-shutdown.service` masked | systemd | Both log out iSCSI sessions on stop — including the root disk's |
| `iscsid` enabled; `oci-bm-volumes.service` | `/usr/local/sbin/oci-bm-volumes.sh` | At boot, before `ahv-define-cvm` and libvirt: creates the records for the two block volumes from `/root/oci-bm-volumes.iscsi` and logs them in; raises the boot session's recovery timeout. No stop action |
| OCI-recommended iSCSI values | `/etc/iscsi/iscsid.conf`, node records | `replacement_timeout 6000`, NOP-out off, `HeaderDigest None`, `startup automatic` — sessions survive network interruptions of up to 100 minutes |
| Mellanox driver kept loaded at shutdown | `/etc/infiniband/openib.conf` `ALLOW_STOP=no`, drop-in for `openibd.service` | OFED's stop action unloads `mlx5_core`, the root disk's NIC driver |
| LVM scans only the AHV disk | `global_filter` in `/etc/lvm/lvm.conf` | Otherwise LVM's stop job waits minutes for AHV's host-swap disks, unreachable once the CVM is off |
| iSCSI hook kept across initramfs rebuilds | `/etc/dracut.conf.d/oci-bm.conf` | Any future `dracut` run (kernel or AHV update) includes `99ocibm` again |
| SELinux labels | `setfiles` from finalize | Files written by the installer would be `unlabeled_t` and denied at boot |
| Persistent journal | `/var/log/journal` | The previous boot's log survives (`journalctl -b -1`) |
| `oci-cvm-net.service` + timer (60 s) | `/usr/local/sbin/oci-cvm-net.sh` | `br0` carries NIC1's MAC; boot-NIC traffic in routing table 100; default route via `br0`; `rp_filter=2`; `arp_ignore` per interface; CVM routed via `ocicvm` with source = host IP and proxy-ARP; CVM traffic to `169.254.0.0/16` masqueraded through NIC0 |
| Time | `chrony` → `169.254.169.254` | `pool.ntp.org` is not reachable from a private subnet |
| Sysctls | `/etc/sysctl.d/90-oci-bm.conf` | Two NICs in one subnet |

## Networking in depth

Three kinds of traffic on two VNICs in one subnet:

| Path | Interface | Addresses | Carries |
|---|---|---|---|
| Storage | `ahv0` = NIC0 (primary VNIC) | `IBFT_IP`, set by the initramfs; route `169.254.0.0/16 dev ahv0`; rule `from IBFT_IP → table 100` | 3 iSCSI sessions. Not renamed, not in OVS, no ifcfg file |
| Management | `eth0` = NIC1 → OVS bridge `br0` | `HOST_IP`; `br0` MAC = VNIC2 MAC; default route via the subnet gateway on `br0` | Host management |
| CVM | CVM `eth0` → Linux bridge `ocicvm` | `CVM_IP`; host route `CVM_IP/32 → ocicvm src HOST_IP`; proxy-ARP on `br0` and `ocicvm`; `ip_forward=1` | CVM / Prism traffic, leaves `br0` with the VNIC MAC |

Why: **OCI forwards only frames whose source MAC is the VNIC's MAC.** OVS gives `br0` a random MAC, so it is pinned to NIC1's. The CVM has its own MAC, which OCI would drop, so its NIC sits on a plain Linux bridge and the host routes to it and answers ARP for it (same as the companion VM deployment). **Any action that renames, re-addresses or brings down NIC0** would stall the root disk, so NIC0 is hidden from AHV's network setup — the same rule OpenShift uses on OCI bare metal.

Kernel settings re-applied every 60 s by `oci-cvm-net.timer`: `rp_filter=2` on all interfaces (two NICs share one subnet), `arp_ignore=0` globally and on `ocicvm`, `2` on `br0`/`eth0`/`ahv0`, `arp_announce=2`, NAT `MASQUERADE` from the CVM to `169.254.0.0/16` via `ahv0` (OCI NTP/DNS accept traffic on NIC0 only from NIC0's own IP).

## Storage in depth

| Disk | OCI object | Target | Logged in by | Linux | Nutanix role |
|---|---|---|---|---|---|
| Boot volume 100 GB | boot volume of the instance | `iqn.2015-02.oracle.boot:uefi` @ `169.254.0.2:3260` LUN 1 | firmware → `99ocibm` initramfs hook | `sda` | AHV: `sda1` EFI, `sda2` /boot, `sda3` LVM `ahv` (root, var, varlog, varlogaudit, tmp, home) |
| CVM volume 400 GB | block volume `<node>-cvm` | `iqn.2015-12.com.oracleiaas:…` @ `169.254.2.x:3260` | `oci-bm-volumes.service` | `sdb` | CVM boot disk + metadata (SSD tier) |
| Data volume 600 GB | block volume `<node>-data` | `iqn.2015-12.com.oracleiaas:…` @ `169.254.2.y:3260` | `oci-bm-volumes.service` | `sdc` | Data disk (SSD tier) |

All three sessions run over NIC0 with recovery timeout 6000 s and NOP-out off. The CVM receives `sdb` and `sdc` by WWN (`/dev/disk/by-id/scsi-36…`), identical in the installer and in AHV. AHV additionally logs in to its own host-swap target served by the CVM (`127.0.0.1:3261`), as on any Nutanix node.

## Terms

| Term | Meaning |
|---|---|
| AHV / CVM / AOS / Prism | Nutanix hypervisor / Controller VM / software in the CVM / web console |
| Phoenix | The Nutanix installer environment booted from the CE ISO; runs from RAM |
| initrd / initramfs | The small root file system the kernel starts first; it must find and mount the real root disk |
| iBFT | iSCSI Boot Firmware Table — ACPI table where the UEFI firmware publishes how it reached the boot volume |
| `iscsistart` | open-iscsi tool that performs one iSCSI login without a daemon; used by every Linux initramfs for iSCSI root |
| dracut | The tool that builds AHV's initramfs; extended through modules |
| VNIC | OCI virtual NIC. On bare metal each VNIC maps to a physical port; OCI forwards only frames whose source MAC is the VNIC's MAC |
