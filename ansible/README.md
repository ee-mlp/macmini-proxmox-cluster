# Proxmox VE 9.0 + Ceph Cluster — Ansible Automation

Automates post-install configuration of a 3-node Proxmox VE 9.0 + Ceph cluster
on Mac Mini 2018 hardware with Thunderbolt 3 mesh networking.

## Cluster layout

| Node | Management IP  | Ceph/TB IP   |
|------|----------------|--------------|
| pve1 | 10.10.15.11    | 10.10.16.11  |
| pve2 | 10.10.15.12    | 10.10.16.12  |
| pve3 | 10.10.15.13    | 10.10.16.13  |

## Prerequisites

1. Proxmox VE 9.0 (Debian Trixie) installed on all 3 nodes.
2. SSH key authentication configured for root on all nodes:
   ```bash
   ssh-copy-id root@10.10.15.11
   ssh-copy-id root@10.10.15.12
   ssh-copy-id root@10.10.15.13
   ```
3. Ansible 2.14+ installed on the control machine.
4. Verify Thunderbolt PCI paths match your hardware (see below).

## Verify Thunderbolt PCI paths

On each node, run:
```bash
udevadm monitor --kernel --property --subsystem-match=net
```
Then plug/unplug a Thunderbolt cable to observe the PCI path reported in `ID_PATH`.
Cross-reference with:
```bash
ls -l /sys/class/net/
lspci | grep -i thunderbolt
```
If the PCI paths differ from `pci-0000:00:0d.2` and `pci-0000:00:0d.3`, update
`ansible/inventory/group_vars/all.yml` and the `.link` file contents in
`ansible/roles/thunderbolt-network/tasks/main.yml`.

## Run order

All playbooks are referenced from `site.yml`. Run from the `ansible/` directory:

```bash
cd ansible/

# Full run (all phases)
ansible-playbook playbooks/site.yml

# Or run each phase individually:
ansible-playbook playbooks/01-post-install.yml
ansible-playbook playbooks/02-thunderbolt.yml
# --- MANUAL STEP REQUIRED HERE (see below) ---
ansible-playbook playbooks/03-cluster.yml
ansible-playbook playbooks/04-ceph.yml
ansible-playbook playbooks/05-cephfs.yml
```

## IMPORTANT: Manual step between playbook 02 and 03

After Thunderbolt networking is configured (playbook 02), you must configure
OpenFabric routing in the Proxmox GUI **before** proceeding to cluster formation:

1. Open the Proxmox web UI on any node (e.g. https://10.10.15.11:8006).
2. Navigate to **Datacenter → SDN → Fabrics → Add**.
3. Select type **OpenFabric** and configure:
   - **Node pve1**: Router ID `10.10.16.11`, interfaces `en02`, `en03`
   - **Node pve2**: Router ID `10.10.16.12`, interfaces `en02`, `en03`
   - **Node pve3**: Router ID `10.10.16.13`, interfaces `en02`, `en03`
4. Click **Apply Configuration**.
5. Verify OpenFabric neighbours are established on each node:
   ```bash
   vtysh -c "show openfabric neighbor"
   ```
   All three nodes should appear as neighbours before continuing.
6. Verify Ceph/TB IPs are reachable:
   ```bash
   ping -c3 10.10.16.12
   ping -c3 10.10.16.13
   ```

Only then run playbook 03 onward.

## Verification commands by phase

### After 01-post-install
```bash
# Confirm no-subscription repo active
ansible proxmox -a "apt-cache policy pve-manager"
# Confirm IOMMU enabled
ansible proxmox -a "grep -i iommu /proc/cmdline"
# Confirm mbpfan running
ansible proxmox -a "systemctl status mbpfan"
```

### After 02-thunderbolt
```bash
# Confirm modules present in initramfs
ansible proxmox -a "lsinitramfs /boot/initrd.img-\$(uname -r) | grep thunderbolt"
# Confirm link files in place
ansible proxmox -a "cat /etc/systemd/network/00-thunderbolt0.link"
# After cables connected: confirm interfaces appear
ansible proxmox -a "ip link show en02; ip link show en03"
```

### After 03-cluster
```bash
# Confirm all nodes in cluster
ansible pve_primary -a "pvecm nodes"
# Confirm quorum
ansible pve_primary -a "pvecm status"
```

### After 04-ceph
```bash
# Cluster health
ansible pve_primary -a "ceph status"
# OSD tree
ansible pve_primary -a "ceph osd tree"
# Pool list
ansible pve_primary -a "ceph osd pool ls detail"
# PVE storage list
ansible pve_primary -a "pvesm status"
```

### After 05-cephfs
```bash
# MDS status
ansible pve_primary -a "ceph mds stat"
# Filesystem list
ansible pve_primary -a "ceph fs ls"
```

## Available tags

The `ceph-init` role does not use Ansible tags directly; host-level conditions
(`when: inventory_hostname == groups['pve_primary'][0]`) control which tasks
execute per node. To re-run specific Ceph phases manually, use `--step` or
limit hosts:

```bash
# Re-run only on primary
ansible-playbook playbooks/04-ceph.yml --limit pve1

# Re-run OSD creation only (skip install)
ansible-playbook playbooks/04-ceph.yml --skip-tags ceph_install
```

## File layout

```
ansible/
├── ansible.cfg
├── inventory/
│   ├── hosts.yml
│   └── group_vars/
│       └── all.yml
├── roles/
│   ├── proxmox-repos/      # Disable enterprise repo, full-upgrade
│   ├── mbpfan/             # Mac fan control daemon
│   ├── iommu/              # Intel IOMMU kernel params
│   ├── diagnostics/        # lldpd, iperf3
│   ├── ntp/                # chrony NTP sync
│   ├── thunderbolt-network/ # TB3 link files, udev rules, ifup scripts
│   ├── proxmox-cluster/    # pvecm create / add
│   ├── ceph-install/       # pveceph install
│   ├── ceph-init/          # mon, mgr, osd, pool, storage, verify
│   └── cephfs/             # MDS + pveceph fs create
└── playbooks/
    ├── site.yml
    ├── 01-post-install.yml
    ├── 02-thunderbolt.yml
    ├── 03-cluster.yml
    ├── 04-ceph.yml
    └── 05-cephfs.yml
```
