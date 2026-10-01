# Ubuntu Server Golden Image (Packer + cloud-init)

[![ci](https://github.com/yaserkaka/ubuntu-golden-image/actions/workflows/ci.yml/badge.svg)](https://github.com/yaserkaka/ubuntu-golden-image/actions/workflows/ci.yml)

Builds a hardened, generalized **Ubuntu 24.04 LTS** golden image, the Linux equivalent of a Windows Sysprep image, and clones it at scale on **KVM/libvirt** and **VMware vSphere**. Every clone boots as a unique machine with its own hostname, network, machine-id and SSH host keys, and **turns itself into a specific server (NFS, HPC compute, Docker, Kubernetes node, web) on first boot** based on the roles assigned at deploy time.

```
 Ubuntu ISO ──► Packer ──► autoinstall ──► provision/*.sh ──► generalize.sh ──► golden image
                (qemu /     (unattended     (baseline,         ("sysprep":       qcow2 / vSphere
                vsphere)    OS install)     hardening,         strip identity)   template
                                            tuning,                                   │
                                            monitoring)                               ▼
                                                     clone + cloud-init seed (hostname, IP, user, key)
                                                     KVM: bash + virt-install   vSphere: Terraform
                                                                                     │
                                                              verify-clones.sh ◄─────┘
```

## Sysprep on Linux

| Windows | This project |
|---|---|
| `unattend.xml` | Subiquity **autoinstall** (`packer/autoinstall/user-data.pkrtpl.hcl`) |
| `sysprep /generalize` | `scripts/generalize.sh` |
| SID reset | `/etc/machine-id` emptied, regenerated on first boot |
| Machine certificates | SSH host keys deleted, regenerated on first boot |
| OOBE / specialize pass | **cloud-init** applies per-clone hostname, network, users |
| DISM capture | Packer output: compressed qcow2 + vSphere template |

`generalize.sh` also removes the installer's network and cloud-init datasource settings, logs, history and apt caches. Packer then deletes the temporary build user right before power-off.

## What's in the image

Each step is a plain bash script in `scripts/provision/`, run in order by Packer:

| Script | Configures |
|---|---|
| `10-common.sh` | Baseline packages, latest patches, timezone, chrony, journald limits, automatic security updates, `/etc/golden-image-release` metadata |
| `20-hardening.sh` | Key-only SSH (no root, no passwords), kernel/network sysctl, auditd, ufw (deny inbound except 22/9100) |
| `30-tuning.sh` | `tuned` profile (`virtual-guest`) plus sysctl for swappiness, caches and network backlog |
| `40-node-exporter.sh` | Prometheus node_exporter on `:9100` |
| `50-firstboot.sh` | cloud-init for NoCloud and VMware datasources, SSH host key fallback, **automatic root LVM growth** when a clone gets a bigger disk |
| `60-roles.sh` | The `golden-role` command and the role scripts (see below) |

## Per-clone roles: one image, many server types

The image stays generic. Each clone is given roles at deploy time, and on first boot cloud-init runs `golden-role apply`, which configures the clone for those roles.

| Role | Turns the clone into |
|---|---|
| `nfs-server` | Shared storage: exports `/srv/shared` to the local subnet |
| `hpc-compute` | HPC compute node: OpenMPI, Slurm `slurmd` + munge, `throughput-performance` tuning, trusted cluster network, `/shared` mounted from the NFS server |
| `docker` | Container host: Docker Engine + Compose v2, log rotation, admins in the `docker` group |
| `k8s-node` | Kubernetes node: swap off, kernel modules/sysctl, containerd (systemd cgroups), kubeadm/kubelet/kubectl, firewall ports, ready for `kubeadm init/join` |
| `web` | nginx with a status page showing the clone's hostname, roles and image version |

**KVM:** add roles in the last column of `deploy/kvm/hosts.csv`, joined with `+`. Shared settings go in `deploy/kvm/roles.env`:

```csv
node01,192.168.122.11/24,2,2048,20,nfs-server+web
node02,192.168.122.12/24,2,2048,30,hpc-compute
node03,192.168.122.13/24,2,2048,20,hpc-compute
```

**vSphere:** set `roles = ["hpc-compute"]` per VM and the shared `role_env` map in `terraform.tfvars`.

On a clone:

```bash
golden-role list            # roles in this image
golden-role status          # what was applied, and when
sudo golden-role apply web  # add a role later
```

Role names are checked before anything is deployed. Each role runs once; failures are logged to `/var/log/golden-role.log` and reported by `make verify`. To add a role, drop a script into `files/roles/` and rebuild the image.

## Repository layout

```
packer/              Packer template (qemu + vsphere-iso sources), variables, autoinstall seed
scripts/provision/   OS configuration scripts, run in numeric order during the build
scripts/             prepare.sh, generalize.sh, inspect-image.sh, verify-clones.sh
files/               Files copied into the image: cloud-init cfg, systemd units, golden-role, roles/
deploy/kvm/          hosts.csv + roles.env + deploy.sh / destroy.sh (qcow2 overlays + cloud-init seed ISOs)
deploy/vsphere/      Terraform: clones from the template, config via guestinfo
.github/workflows/   CI: packer validate, terraform validate, shellcheck, cloud-init schema
```

## Prerequisites

- Packer ≥ 1.10, `make`
- **KVM build/deploy:** `qemu-system-x86`, `libvirt-daemon-system`, `virtinst`, `cloud-image-utils`, access to `/dev/kvm`
- **vSphere build:** vCenter account allowed to create VMs/templates; `xorriso` on the build host (for the seed CD)
- **vSphere deploy:** Terraform ≥ 1.5
- Optional: `libguestfs-tools` for `make inspect`

## Quick start: KVM

```bash
make build-qemu        # ~15-25 min: install, configure, generalize -> output/qemu/*.qcow2
make inspect           # offline check: no machine-id, host keys, netplan or build user left
make deploy-kvm        # clone node01..03 from deploy/kvm/hosts.csv: an NFS server + 2 HPC compute nodes
make verify            # every clone unique, healthy, and its roles applied?
make destroy-kvm
```

Clone settings live in `deploy/kvm/hosts.csv` (`name,ip_cidr,vcpus,memory_mb,disk_gb,roles`). Use `dhcp` instead of an address for DHCP. Overrides go through environment variables: `ADMIN_USER`, `SSH_PUBKEY_FILE`, `GATEWAY`, `DNS_SERVERS`, `LIBVIRT_NETWORK`.

## Quick start: vSphere

```bash
cp packer/vsphere.pkrvars.hcl.example packer/vsphere.pkrvars.hcl   # edit
export PKR_VAR_vsphere_password='...'
make build-vsphere     # creates template ubuntu-2404-golden-<YYYYMMDD-hhmm>

cp deploy/vsphere/terraform.tfvars.example deploy/vsphere/terraform.tfvars   # set template_name + vms
export TF_VAR_vsphere_password='...'
make tf-init tf-apply
./scripts/verify-clones.sh 10.10.20.21 10.10.20.31 10.10.20.32 10.10.20.41
```

## Example `make verify` output

```
HOST             HOSTNAME   CLOUDINIT  ROOT   IMAGE           ROLES
192.168.122.11   node01     done       19G    20261001-1430   nfs-server+web
192.168.122.12   node02     done       29G    20261001-1430   hpc-compute
192.168.122.13   node03     done       19G    20261001-1430   hpc-compute

PASS: 3 clone(s) are unique and healthy.
```

node02 was deployed with a 30 GB disk, and its root volume grew automatically on first boot.

## Customizing

- Settings sit at the top of each script in `scripts/provision/` (packages, timezone, firewall ports, tuned profile). To add a step, drop in a new numbered script and list it in the `scripts` block of `packer/ubuntu.pkr.hcl`.
- Role settings are documented at the top of each `files/roles/<role>.sh`.
- For a different Ubuntu release, change `iso_url`/`ubuntu_version` in `packer/variables.pkr.hcl`. When a new 24.04 point release ships, older ISOs move to `old-releases.ubuntu.com`.
- Change the temporary build password with `-var build_password=... -var build_password_hash="$(openssl passwd -6 ...)"`. The account is deleted at the end of every build.

## Troubleshooting

- **Packer stuck at "Waiting for SSH":** the installer takes 10–20 minutes. Set `headless = false` to watch it. On hosts without KVM, use `-var qemu_accelerator=tcg` (slow).
- **`virt-install` unknown OS variant:** run with `OS_VARIANT=ubuntu22.04` (older osinfo-db).
- **A clone has no network:** check `/var/log/cloud-init.log` on the clone; the seed must provide a `network-config`/`metadata.network`.
- **A role failed:** run `golden-role status` and read `/var/log/golden-role.log` on the clone. Roles install packages, so clones need internet access on first boot. Fix the cause, then `sudo golden-role apply --force <role>`.
