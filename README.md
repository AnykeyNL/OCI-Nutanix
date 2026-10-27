# OCI-Nutanix — Nutanix CE on OCI bare metal

Scripts and a step-by-step runbook to install and run **Nutanix Community Edition (AHV + CVM, single-node cluster)** on an **Oracle Cloud Infrastructure bare-metal instance**, booting AHV directly from the OCI iSCSI boot volume.

Everything that can be scripted is scripted. From the stock CE ISO in an Object Storage bucket to a running cluster there is exactly **one interactive step** (the Nutanix installer's text UI, which has no unattended mode); the scripts print the values to type.

| | |
|---|---|
| Nutanix software | Community Edition 2.1 — AOS 6.8.1, AHV 20230302.101026, Phoenix/Foundation 5.6.1 (`phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso`) |
| OCI shape | `BM.Standard3.64` (Intel, 64 OCPU; other bare-metal shapes with Mellanox NICs should work but are untested) |
| Admin host | Oracle Linux 10 instance in the same VCN, OCI CLI configured, ~25 GB free disk |
| Result | AHV boots from the OCI boot volume; CVM on two iSCSI block volumes (612 GiB pool); Prism Element at `https://<CVM IP>:9440`; every power path (reboot, power-off, OCI stop/reset) comes back by itself |

Based on the reference implementation *Running Nutanix AHV (Community Edition) on an OCI Bare-Metal Instance*, v3 (Vaibhav Tiwari, October 2026). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how and why it works.

> Nutanix CE is licensed for non-production use only. Download the ISO yourself from the [Nutanix Community Edition](https://www.nutanix.com/products/community-edition) page (free NEXT account) and put it in an OCI bucket. This repository contains no Nutanix software; the ISO is extended with a few open-source files (iSCSI kernel modules built from Linux 5.10.2 source, `iscsistart`, a small iBFT reader) — nothing in it is removed or replaced.

## Quick start

On the Oracle Linux 10 admin host, as root:

```bash
git clone https://github.com/AnykeyNL/OCI-Nutanix.git
cd OCI-Nutanix
cp config/oci-nutanix.env.example config/oci-nutanix.env
vi config/oci-nutanix.env          # COMPARTMENT_ID, SUBNET_ID, SRC_BUCKET (+ SRC_ISO_OBJECT if the name differs)
scripts/install-all.sh             # runs steps 00-07; step 05 opens the Nutanix installer
```

About 2–3 hours end to end, most of it waiting (ISO build ~15 min, image import 10–30 min, bare-metal launch 10–15 min, installer ~15 min, first AHV boot 15–20 min). Each step can also be run on its own and is safe to re-run; `install-all.sh --from N` resumes after a fix.

## The steps

| Step | Script | Where | What it does |
|---|---|---|---|
| 00 | `scripts/00-prereqs.sh` | admin host | Installs packages, checks OCI CLI, config, bucket, disk space |
| 01 | `scripts/01-fetch-iso.sh` | admin host | Downloads the stock CE ISO from `SRC_BUCKET` |
| 02 | `scripts/02-build-iso.sh` | admin host | Builds the bare-metal ISO: adds iSCSI boot support to the installer initrd (`scripts/build/remaster-ce-iso-bm.sh`) |
| 03 | `scripts/03-import-image.sh` | admin host → OCI | Uploads the ISO, imports it as a UEFI custom image, adds the shape |
| 04 | `scripts/04-launch-instance.sh` | admin host → OCI | Launches the bare-metal instance, two iSCSI block volumes, second VNIC with host + CVM IPs; writes `state/<node>.env` |
| 05 | `scripts/05-install.sh` | admin host → installer | Waits for the installer's SSH, adapts it in RAM (`ce-bm-prep.sh`), **opens the Nutanix installer UI** (interactive) |
| 06 | `scripts/06-finalize.sh` | admin host → installer | Makes AHV boot from iSCSI and installs all OCI host settings (`ahv-bm-finalize.sh`), backs up the boot volume, reboots |
| 07 | `scripts/07-create-cluster.sh` | admin host → host/CVM | Waits for AHV and the CVM, health check, `cluster create`, OCI NTP/DNS |

Detailed instructions, expected output and what to do when something fails: [docs/INSTALL.md](docs/INSTALL.md).

## Day-2 operations

| Command | Purpose |
|---|---|
| `scripts/ops/validate.sh` | 30-point read-only health check on the AHV host (run after every power event) |
| `scripts/ops/power.sh status\|reboot\|shutdown\|start` | Clean reboot / power-off / power-on (CVM shut down first, cluster restarts by itself) |
| `scripts/ops/cluster.sh status\|start\|stop\|hosts` | Cluster commands on the CVM |
| `scripts/ops/ssh.sh installer\|host\|cvm` | Shell on the installer, the AHV host or the CVM |
| `scripts/ops/reapply-host-setup.sh` | Re-apply every OCI setting on the live host (idempotent fix-all) |
| `scripts/ops/destroy.sh --yes` | Terminate the instance and delete its volumes |

**Do not use the OCI console "Stop" or "Reboot" without "Force" on this node.** AHV ignores the ACPI power button by design; OCI waits about 15 minutes and then cuts the power with the CVM running. Use `scripts/ops/power.sh` instead. All scenarios, timings and the maintenance procedure are in [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Repository layout

```
config/oci-nutanix.env.example   all settings (copy to config/oci-nutanix.env)
scripts/00-…07-*.sh              the installation, one script per step
scripts/install-all.sh           runs them all
scripts/lib/common.sh            shared helpers (config, OCI lookups, SSH)
scripts/build/                   remaster-ce-iso-bm.sh + ibft-parse.c (ISO build)
scripts/remote/                  scripts copied to and run on the node:
                                   ce-bm-prep.sh        installer, before ./phoenix
                                   ahv-bm-finalize.sh   installer, after ./phoenix
                                   ahv-host-setup.sh    AHV host settings (install-only or live)
                                   validate-ahv-bm.sh   health check
scripts/ops/                     day-2: power, cluster, validate, ssh, destroy
state/                           per-node state written by the scripts (git-ignored)
docs/                            INSTALL, ARCHITECTURE, OPERATIONS, TROUBLESHOOTING
```

## Credentials

Nutanix CE defaults, used by the scripts (`CE_PASSWORD` in the config): installer and AHV root `nutanix/4u`, CVM user `nutanix` / `nutanix/4u`, Prism `admin` / `nutanix/4u` (must be changed at first login). The scripts use password authentication with `sshpass` and ignore host keys because the same IPs are reused by the installer and later by AHV; this is a lab setup on a private subnet — harden it before exposing anything.

## Status and limits

- Single node, RF1, tested on `BM.Standard3.64`. CE supports 1, 3 or 4 nodes; multi-node is not covered here yet.
- The node must be in a private subnet reachable from the admin host (SSH to installer/host/CVM, ICMP to the CVM).
- The AHV network setup deliberately keeps the primary VNIC (NIC0) for iSCSI only; user-VM traffic goes through `br0` on NIC1.

## License

MIT — see [LICENSE](LICENSE). Nutanix, AHV, AOS and Prism are trademarks of Nutanix, Inc.; Oracle Cloud Infrastructure is a trademark of Oracle. This project is not affiliated with either.
