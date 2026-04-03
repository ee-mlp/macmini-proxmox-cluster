# CLAUDE.md

## Project Overview

Infrastructure-as-code and documentation for a 3-node Proxmox VE 9.0 + Ceph cluster built on Mac Mini 2018 hardware, using Thunderbolt 3 as the Ceph network.

**Status:** Documentation is beta-quality; Ansible playbooks are untested — proceed with caution.

## Repository Structure

```
README.md                          # Full step-by-step setup guide
ansible/
  ansible.cfg                      # Points to inventory/, roles_path = roles/
  inventory/
    hosts.yml                      # 3 nodes: pve1/pve2/pve3
    group_vars/all.yml             # Shared variables (IPs, subnets, Ceph config)
  playbooks/
    site.yml                       # Runs all playbooks in order
    01-post-install.yml            # Repos, mbpfan, diagnostics
    02-thunderbolt.yml             # TB interface naming + udev rules
    03-cluster.yml                 # Proxmox cluster join
    04-ceph.yml                    # Ceph install, init, OSDs, pool
    05-cephfs.yml                  # CephFS MDS + shared ISO storage
  roles/
    proxmox-repos/                 # Disable enterprise repo, add no-subscription
    mbpfan/                        # Fan control daemon (critical without macOS)
    diagnostics/                   # lldpd, iperf3
    iommu/                         # Optional: PCIe passthrough
    ntp/                           # chrony config (Ceph clock-skew sensitive)
    thunderbolt-network/           # .link files, udev scripts, /etc/network config
    proxmox-cluster/               # pvecm create + join
    ceph-install/                  # pveceph install
    ceph-init/                     # pveceph init, mon, mgr, OSD, pool
    cephfs/                        # pveceph mds + fs create
```

## Cluster Topology

| Node | Management IP  | Ceph/Loopback IP | Hostname    |
|------|---------------|------------------|-------------|
| pve1 | 10.10.15.11   | 10.10.16.11      | pve1.local  |
| pve2 | 10.10.15.12   | 10.10.16.12      | pve2.local  |
| pve3 | 10.10.15.13   | 10.10.16.13      | pve3.local  |

- **Management network:** 1GbE Ethernet, 10.10.15.0/24 (corosync, Proxmox GUI, VM traffic)
- **Ceph network:** Thunderbolt 3 full mesh, 10.10.16.0/24, routed via FRR/OpenFabric (unnumbered interfaces, MTU 65520)
- **Ansible connects as:** `root` via SSH

## Key Configuration (group_vars/all.yml)

- `tb_pci_paths.en02`: `pci-0000:7d:00.0` (port ③, Bus B)
- `tb_pci_paths.en03`: `pci-0000:07:00.0` (port ②, Bus A)
- `nvme_device`: `/dev/nvme0n1`, Ceph OSD starts at 64GB (`nvme0n1p4`)
- `ceph_pool_name`: `ceph-pool`, size 3, min_size 2

## Critical Notes

- **Both** Ceph public and cluster networks must be the Thunderbolt subnet (`10.10.16.0/24`). Setting only the cluster network to TB and leaving public on 1GbE tanks performance (~175 MB/s vs ~1.3 GB/s).
- **mbpfan** is essential — without macOS, fans default to low RPM and the nodes overheat.
- **NTP must be configured before Ceph** — clock skew causes Ceph health warnings.
- Ceph GUI wizard may not show the 10.10.16.0/24 network (because IPs are assigned by FRR, not `/etc/network/interfaces`). Use the CLI: `pveceph init --network 10.10.16.0/24 --cluster-network 10.10.16.0/24`.
- The `iommu` role is commented out in `01-post-install.yml` — only enable for PCIe passthrough.

## Running Ansible

```bash
cd ansible/

# Full setup (run phases in order; review each playbook before running)
ansible-playbook playbooks/site.yml

# Individual phase
ansible-playbook playbooks/01-post-install.yml
ansible-playbook playbooks/02-thunderbolt.yml
ansible-playbook playbooks/03-cluster.yml
ansible-playbook playbooks/04-ceph.yml

# Dry-run
ansible-playbook playbooks/site.yml --check
```

## Software Versions

- Proxmox VE 9.0 (Debian Trixie)
- Ceph Squid 19.2
- Linux kernel 6.14 (includes T2/Apple NVMe support for Mac Mini 2018)
