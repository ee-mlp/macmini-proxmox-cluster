# Proxmox VE 9.0 + Ceph Cluster: 3× Mac Mini 2018 with Thunderbolt Networking

State: docs: beta, ansible playbooks: untested - proceed with caution. PR-s for improvements and fixes are always welcome

## Architecture Overview

```
          ┌──────────┐
     ┌────┤  Mini 1  ├────┐
     │    │ (pve1)   │    │
     │    └──────────┘    │        1GbE (management/corosync)
     │ TB3    ▲    TB3    │        ─── each node to LAN switch
     │        │ 1GbE      │
  ┌──┴──────┐ │   ┌───────┴─┐      Thunderbolt 3 (Ceph traffic)
  │ Mini 2  ├─┘───┤ Mini 3  │      ─── direct point-to-point cables
  │ (pve2)  ├─────┤ (pve3)  │          full mesh, no switch needed
  └─────────┘ TB3 └─────────┘
```

**Networks:**

| Network          | Interface       | Subnet            | Purpose                              |
|-----------------|-----------------|-------------------|--------------------------------------|
| Management/LAN  | Ethernet (1GbE) | 10.10.15.0/24     | Proxmox GUI, corosync, VM traffic    |
| Ceph (public+cluster) | Thunderbolt mesh | 10.10.16.0/24 | All Ceph replication + client traffic |

**Hardware per node:** Mac Mini 2018 (i7-8700B, 32GB RAM (max 64GB), 4× Thunderbolt 3 ports, 1× 1GbE, 2× USB-A)

**Cables needed:** 3× Thunderbolt 3 cables (one per link in the full mesh)

**Storage per node:** Internal Apple NVMe works out of the box with PVE 9.0 (kernel 6.14 has T2 support). Optionally add an external USB/TB NVMe for dedicated Ceph OSD.

---

## Phase 1: Prepare Mac Mini Hardware

### 1.1 Disable Secure Boot (all 3 nodes)

1. Shut down the Mac Mini completely
2. Press and hold the **power button** until you see "Loading startup options" — then release
3. In macOS Recovery, go to **Utilities → Startup Security Utility**
4. Set **Secure Boot** to **No Security**
5. Set **Allowed Boot Media** to **Allow booting from external media**
6. If SIP is enabled, open **Terminal** from the Utilities menu and run:
   ```
   csrutil disable
   ```
7. Restart the Mac Mini

### 1.2 Prepare Boot Media

1. Download the latest **Proxmox VE 9.x ISO** from https://www.proxmox.com/downloads
2. Flash it to a USB drive using **balenaEtcher** or `dd`
3. Plug the USB into the Mac Mini
4. Reboot and hold the **Option (⌥)** key immediately
5. Select the orange **EFI Boot** icon

---

## Phase 2: Install Proxmox VE

### 2.1 Run Installer (each node)

1. Select **Install Proxmox VE**
2. Accept the license agreement
3. **Target disk:** Select the internal Apple NVMe (recognized out of the box — kernel 6.14 includes T2 support for Mac Mini 2018).
4. **Filesystem:** Choose **ext4** or **xfs** (xfs is slightly better for VMs)
5. **IMPORTANT — Click "Options" on the disk selection screen** to limit Proxmox's disk usage:
   - **hdsize:** Set to `64` (GB). This tells the installer to only use 64 GB of the NVMe for the Proxmox LVM volume group, leaving the rest of the disk unpartitioned and available for Ceph.
   - **swapsize:** Set to `8` (GB) — sufficient for a 32-64 GB RAM node
   - **maxroot:** Set to `48` (GB) — the root filesystem. ISOs and container templates are stored here (under `/var/lib/vz/`), so give it enough room. A few ISOs at 1-4 GB each plus Proxmox itself fits comfortably in 48 GB.
   - **maxvz:** Set to `0` — disables the `local-lvm` thin pool. All VM disks go on Ceph, so you don't need local thin-provisioned storage. This also avoids wasting space on a thin pool you won't use.
   - The 64 GB breaks down roughly as: 1 GB EFI + 8 GB swap + 48 GB root + overhead
6. **Country/Timezone/Keyboard:** Set appropriately (Estonia, Europe/Tallinn)
7. **Password and email:** Set root password and admin email
8. **Network configuration:**
   - **Management interface:** Select the 1GbE Ethernet port (usually `ens5` or `enp0s...`)
   - **Hostname:** `pve1.local` / `pve2.local` / `pve3.local`
   - **IP addresses:** `10.10.15.11/24`, `.12`, `.13` respectively
   - **Gateway:** `10.10.15.1`
   - **DNS:** Your DNS server
9. Complete installation and reboot (remove USB when prompted)

### 2.2 Post-Install: Configure Repositories

SSH into each node and run:

```bash
# Disable enterprise repo (unless you have a subscription)
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list

# Add no-subscription repo (PVE 9.x uses Debian Trixie)
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > \
  /etc/apt/sources.list.d/pve-no-subscription.list

# Update and upgrade
apt update && apt full-upgrade -y
reboot
```

### 2.3 Fan Control (important!)

Without macOS, the fan controller defaults to low RPM. The `mbpfan` daemon is available directly from the Debian Trixie repos:

```bash
apt install mbpfan
systemctl enable mbpfan
systemctl start mbpfan
```

Verify it's working with `systemctl status mbpfan`. The daemon reads CPU temperatures via `coretemp` and controls fans via `applesmc`. You can tune thresholds in `/etc/mbpfan.conf` if needed.

> **Optional — PCIe passthrough:** If you plan to pass through a GPU or NVMe to a VM, enable IOMMU: `sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' /etc/default/grub && update-grub`

---

## Phase 3: Set Up Thunderbolt Mesh Network

### 3.1 Physical Cabling

The Mac Mini 2018 has 4 Thunderbolt 3 ports on the back, managed by 2 independent controllers (Intel JHL7540). Each controller handles a pair of ports. The Thunderbolt signaling rate is 40 Gbps per port, but both ports on the same controller share a **PCIe 3.0 ×4 upstream link (~32 Gbps / ~4 GB/s)** to the CPU:

```
Back of Mac Mini 2018 (looking at the rear)

 Power  Ethernet  ①  ②  ③  ④  HDMI  USB-A  USB-A  3.5mm
                  └Bus A┘  └Bus B┘
                  (shared  (shared
                  ~32Gbps  ~32Gbps
                  PCIe3×4) PCIe3×4)
```

**For maximum performance, use one port from each bus per node** — this gives each Thunderbolt network link its own PCIe upstream bandwidth. Connect cables to ports ② and ③ (one from Bus A, one from Bus B):

| Cable | From             | To               |
|-------|------------------|------------------|
| 1     | pve1 port ② (Bus A) | pve2 port ② (Bus A) |
| 2     | pve1 port ③ (Bus B) | pve3 port ② (Bus A) |
| 3     | pve2 port ③ (Bus B) | pve3 port ③ (Bus B) |

Each node uses both of its Thunderbolt controllers, one cable to each of the other two nodes. This ensures each link has the full ~32 Gbps PCIe upstream bandwidth available without sharing.

> **Does it matter which specific port within a bus?** No — ports ① and ② are interchangeable (both on Bus A), as are ③ and ④ (both on Bus B). Just make sure you pick one from each bus. If you accidentally put both cables on the same bus, it still works — you'd get ~16 Gbps per link (both sharing the ~32 Gbps PCIe uplink), which is still more than sufficient for Ceph.

### 3.2 Identify Thunderbolt PCI Paths (all 3 nodes)

With cables plugged in, run:

```bash
udevadm monitor
```

Then unplug and replug each Thunderbolt cable to identify the PCI paths for each port. On Mac Mini 2018, the confirmed paths are:

| Port | Bus | PCI path       |
|------|-----|----------------|
| ②   | A   | `0000:07:00.0` |
| ③   | B   | `0000:7d:00.0` |

These are already set in `ansible/inventory/group_vars/all.yml` (`tb_pci_paths.en03` and `tb_pci_paths.en02` respectively).

### 3.3 Load Kernel Modules and Create Persistent Interface Names (all 3 nodes)

Thunderbolt interface names are not stable by default — systemd `.link` files pin them by PCI path. Adjust paths if they differ from the confirmed values above.

```bash
# Load thunderbolt networking modules at boot
grep -qxF thunderbolt /etc/modules || echo thunderbolt >> /etc/modules
grep -qxF thunderbolt-net /etc/modules || echo thunderbolt-net >> /etc/modules

# Pin interface names by PCI path
cat > /etc/systemd/network/00-thunderbolt0.link << 'EOF'
[Match]
Path=pci-0000:07:00.0
Driver=thunderbolt-net
[Link]
MACAddressPolicy=none
Name=en02
EOF

cat > /etc/systemd/network/00-thunderbolt1.link << 'EOF'
[Match]
Path=pci-0000:7d:00.0
Driver=thunderbolt-net
[Link]
MACAddressPolicy=none
Name=en03
EOF
```

### 3.5 Create udev Rules for Auto-UP (all 3 nodes)

Thunderbolt interfaces need help coming up on boot/cable insertion:

```bash
# Create udev rule
cat > /etc/udev/rules.d/10-tb-en.rules << 'EOF'
ACTION=="move", SUBSYSTEM=="net", KERNEL=="en02", RUN+="/usr/local/bin/pve-en02.sh"
ACTION=="move", SUBSYSTEM=="net", KERNEL=="en03", RUN+="/usr/local/bin/pve-en03.sh"
EOF

# Create script for en02
cat > /usr/local/bin/pve-en02.sh << 'SCRIPT'
#!/bin/bash
LOGFILE="/tmp/udev-debug.log"
IF="en02"
echo "$(date): pve-$IF.sh triggered by udev" >> "$LOGFILE"
for i in {1..10}; do
    echo "$(date): Attempt $i to bring up $IF" >> "$LOGFILE"
    /usr/sbin/ifup $IF >> "$LOGFILE" 2>&1 && {
        echo "$(date): Successfully brought up $IF on attempt $i" >> "$LOGFILE"
        break
    }
    echo "$(date): Attempt $i failed, retrying in 3 seconds..." >> "$LOGFILE"
    sleep 3
done
SCRIPT

# Create script for en03
cat > /usr/local/bin/pve-en03.sh << 'SCRIPT'
#!/bin/bash
LOGFILE="/tmp/udev-debug.log"
IF="en03"
echo "$(date): pve-$IF.sh triggered by udev" >> "$LOGFILE"
for i in {1..10}; do
    echo "$(date): Attempt $i to bring up $IF" >> "$LOGFILE"
    /usr/sbin/ifup $IF >> "$LOGFILE" 2>&1 && {
        echo "$(date): Successfully brought up $IF on attempt $i" >> "$LOGFILE"
        break
    }
    echo "$(date): Attempt $i failed, retrying in 3 seconds..." >> "$LOGFILE"
    sleep 3
done
SCRIPT

# Make scripts executable
chmod +x /usr/local/bin/pve-en02.sh /usr/local/bin/pve-en03.sh
```

### 3.6 Configure Network Interfaces (all 3 nodes)

The TB interfaces run **unnumbered** — no IP assigned directly. Each node gets a **loopback IP** from 10.10.16.0/24 via OpenFabric routing (configured in step 4.4 after the cluster forms).

Create `/etc/network/interfaces.d/thunderbolt`:

```
auto en02
iface en02 inet manual
    mtu 65520

auto en03
iface en03 inet manual
    mtu 65520
```

> **MTU 65520** (jumbo frames) recommended for Ceph, 17Gbps thruput tested using iperf3 and FRR routing from pve1 to pve3 via pve2 with one cable disconnected. With MTU 9000 thruput was 2-3Mbps.

Apply and reboot:

```bash
update-initramfs -u -k all
reboot
```

| Node | Management IP | Ceph/Loopback IP | TB Interfaces         |
|------|--------------|------------------|-----------------------|
| pve1 | 10.10.15.11  | 10.10.16.11      | en02, en03 (unnumbered) |
| pve2 | 10.10.15.12  | 10.10.16.12      | en02, en03 (unnumbered) |
| pve3 | 10.10.15.13  | 10.10.16.13      | en02, en03 (unnumbered) |

### 3.7 Verify Thunderbolt Interfaces (all 3 nodes)

```bash
ip link show en02 en03   # both should be UP, no IP yet (assigned by OpenFabric in step 4.4)
lldpctl                  # should show TB neighbours
```

### 3.8 Install Diagnostic Tools (all 3 nodes)

```bash
# LLDP — essential for verifying Thunderbolt L2 neighbor visibility
apt install lldpd iperf3 -y
systemctl enable lldpd

# Verify neighbors after all nodes are cabled
lldpctl
```

---

## Phase 4: Create Proxmox Cluster

### 4.1 Create the Cluster (on pve1 only)

```bash
pvecm create my-cluster
```

Or via the web GUI at `https://10.10.15.11:8006`:
**Datacenter → Cluster → Create Cluster**

### 4.2 Join Other Nodes

On pve1, get the join information:
```bash
pvecm add pve1 --join-information
```

On pve2 and pve3:
```bash
pvecm add 10.10.15.11
# Enter the root password of pve1 when prompted
```

Or use the GUI: **Datacenter → Cluster → Join Cluster** and paste the join info.

### 4.3 Verify Cluster

```bash
pvecm status
# Should show 3 nodes, all online
# Expected votes: 3, Quorum: 2
```

### 4.4 Configure OpenFabric SDN Fabric (GUI)

1. **Datacenter → SDN → Fabrics → Add → OpenFabric**
2. Set fabric name `ceph`, IPv4 Prefix `10.10.16.0/24`
3. Optionally set Hello-Interval `1`, CSNP-Interval `2` for faster failover
4. Add each node:

   | Node | Router-ID   | Interfaces |
   |------|-------------|------------|
   | pve1 | 10.10.16.11 | en02, en03 |
   | pve2 | 10.10.16.12 | en02, en03 |
   | pve3 | 10.10.16.13 | en02, en03 |

   Leave interface IP fields empty — unnumbered mode, loopback IP inherited from Router-ID.

5. **Datacenter → SDN → Apply Configuration**

This generates FRR config on each node and establishes routing adjacencies over the TB links.

### 4.5 Verify Thunderbolt Connectivity

```bash
vtysh -c "show openfabric neighbor"   # 2 peers per node
vtysh -c "show openfabric route"      # routes to all 3 loopback IPs
ping -c 3 10.10.16.12                 # from pve1
ping -c 3 10.10.16.13                 # from pve1

# Test failover: unplug pve1↔pve3 cable, then:
traceroute 10.10.16.13   # should route via pve2 (10.10.16.12)
```

---

## Phase 5: Install and Configure Ceph

### 5.0 Configure NTP (all 3 nodes — do this first!)

Ceph is extremely sensitive to clock skew between nodes. Even a few seconds of drift can cause health warnings or degraded operation. Proxmox ships with `chrony` by default:

```bash
# Verify chrony is running
systemctl status chronyd

# If not installed:
apt install chrony -y
systemctl enable chronyd
systemctl start chronyd

# Check sync status
chronyc sources
chronyc tracking

# Verify all nodes are within ~1ms of each other
# If nodes are isolated from the internet, configure one node
# as a local NTP server and point the others at it
```

### 5.1 Install Ceph (all 3 nodes)

Via GUI: Navigate to any node → **Ceph** → **Install Ceph**

- **Version:** Squid (19.2) — the default for PVE 9.0
- **Repository:** No-Subscription

Or via CLI on each node:
```bash
pveceph install --repository no-subscription
```

### 5.2 Initialize Ceph (on pve1)

This is done only once, on the first node:

```bash
pveceph init --network 10.10.16.0/24 --cluster-network 10.10.16.0/24
```

> **Critical lesson from the community:** Set **both** the public network and cluster network to use the Thunderbolt network. If you set only the cluster network to Thunderbolt and leave the public network on 1GbE, Ceph traffic will bottleneck through the slow link and you'll see dramatically reduced performance (~175 MB/s instead of ~1.3 GB/s).

> **Note on SDN Fabrics:** Since the Thunderbolt IPs are configured via FRR/OpenFabric (not in `/etc/network/interfaces`), the Ceph GUI wizard may not show the 10.10.16.0/24 network in its dropdown. Use the CLI command above instead. The Proxmox wiki explicitly notes this for the routed mesh setup.

### 5.3 Create Monitors and Managers (all 3 nodes)

Run on each node (pve1 first, then pve2, pve3):

```bash
pveceph mon create
pveceph mgr create
```

Or via GUI: each node → **Ceph → Monitor → Create** and **Ceph → Manager → Create**. One manager will be active, the others standby.

### 5.5 Create OSDs (from the unallocated space on the internal NVMe)

Since you limited Proxmox to 64 GB during install (via `hdsize`), the rest of the NVMe is unpartitioned. You need to create a new partition in that free space, then use it as a Ceph OSD.

**Step 1: Verify free space** (on each node)

```bash
lsblk   # 3 partitions totalling ~64GB, rest of NVMe unallocated
```

**Step 2: Create a partition for Ceph** (on each node)

```bash
# Find where the last partition ends
parted /dev/nvme0n1 print free

# Create a new partition using all remaining space
parted -s -a optimal /dev/nvme0n1 mkpart primary 64GB 100%

# Verify — you should now see nvme0n1p4
lsblk
```

**Step 3: Create the OSD** (on each node)

The new partition should appear in the Proxmox GUI under **Ceph → OSD → Create OSD**. If it does, select it there.

If the GUI doesn't show the partition, create via CLI:

```bash
pveceph osd create /dev/nvme0n1p4
```

Or using ceph-volume directly:

```bash
ceph-volume lvm create --bluestore --data /dev/nvme0n1p4
```

Repeat on all 3 nodes. Each node gets 1 OSD from its remaining NVMe space.

> **Notes:**
> - **Memory planning:** Proxmox recommends at least 8 GiB of RAM per OSD for good performance. With 1 OSD + MON + MGR per node, budget ~12 GiB for Ceph services, leaving ~52 GiB (on a 64 GB node) for VMs and containers. During recovery/rebalancing, Ceph may temporarily use more memory.
> - The Mac Mini 2018 internal NVMe is a consumer Apple SSD without power-loss protection (PLP). This means Ceph write performance will be lower than with enterprise SSDs, and the drive will wear faster under sustained Ceph writes. For a homelab this is acceptable, but keep good backups.
> - With 3 nodes × 1 OSD each, Ceph will work but this is the bare minimum. Proxmox recommends at least 12 OSDs evenly distributed. If you later add external NVMe drives, you can add more OSDs per node for better performance and resilience.
> - With a ~936 GB OSD per node and `size=3` replication, your usable Ceph capacity will be approximately **936 GB** (not 936×3, since each write is replicated 3 times).

### 5.6 Create a Ceph Pool

```bash
pveceph pool create ceph-pool --size 3 --min_size 2
```

- **size 3:** Data is replicated to all 3 nodes
- **min_size 2:** I/O continues even if 1 node is down

Or via GUI: Any node → **Ceph → Pools → Create**

### 5.7 Add Ceph as Proxmox Storage

Via GUI: **Datacenter → Storage → Add → RBD**

- **ID:** `ceph-storage`
- **Pool:** `ceph-pool`
- **Monitor(s):** Auto-detected from cluster
- **Content:** Disk image, Container

### 5.8 Verify Ceph Health

```bash
ceph status
# Should show:
#   health: HEALTH_OK
#   mon: 3 daemons
#   mgr: active, 1 standbys
#   osd: 3 osds: 3 up, 3 in
```

---

## Phase 6: Enable High Availability

1. **Datacenter → HA → Groups → Create** (optional group)
2. **Datacenter → HA → Add** → select VMs on the Ceph pool. On node failure they restart on a surviving node automatically.
3. Set migration network — edit `/etc/pve/datacenter.cfg`:
   ```
   migration: network=10.10.16.0/24,type=secure
   ```

---

## Phase 7: Shared ISO Storage with CephFS (optional)

```bash
pveceph mds create   # on pve1
pveceph mds create   # on pve2
pveceph fs create --pg_num 32 --add-storage
```

Then **Datacenter → Storage → cephfs → Edit** → set Content to ISO image, Container template, Snippets, VZDump backup file. Upload an ISO once, available on all 3 nodes.

---

## Phase 8: Backup Strategy

With Ceph replication, your VM data survives a single node failure. But Ceph does **not** protect against accidental deletion, corruption, or multi-node failures. You need real backups.

### Option A: Proxmox Backup Server (PBS)

The recommended approach. Install PBS on a separate machine (your 4th Mac Mini, a NAS, or any Linux box) and configure backup jobs via the PVE GUI.

### Option B: vzdump to CephFS or local storage

```bash
# Manual backup of a VM
vzdump 100 --storage cephfs --mode snapshot --compress zstd

# Or schedule via GUI:
# Datacenter → Backup → Add → select schedule, VMs, and storage
```

### Backup best practices

- Schedule daily backups with retention (e.g., keep 7 daily, 4 weekly, 3 monthly)
- Store backups on storage that is **not** on the same Ceph cluster — a USB drive, NAS, or remote PBS
- Test restores periodically

---

## Troubleshooting

### Thunderbolt interfaces don't appear
- Check `dmesg | grep -i thunder` for errors
- Verify kernel modules: `lsmod | grep thunderbolt`
- Try `modprobe thunderbolt-net` manually
- Check cables are genuine Thunderbolt 3 (not just USB-C)
- Check `/tmp/udev-debug.log` for udev script activity

### Ceph is slow despite fast iperf3 results
- Ensure both Ceph **public** and **cluster** networks point to the Thunderbolt subnet
- Check `/etc/ceph/ceph.conf` for `public_network` and `cluster_network` values
- Consumer SSDs without power-loss protection severely limit Ceph IOPS

### Node can't reach another node over Thunderbolt
- Check OpenFabric adjacencies: `vtysh -c "show openfabric neighbor"`
- Check routes: `vtysh -c "show openfabric route"`
- Verify FRR is running: `systemctl status frr`
- Check SDN config was applied: **Datacenter → SDN → Apply Configuration**
- Install and run `lldpd` / `lldpctl` to verify L2 visibility

### Fan running at full speed or not at all
- Verify `mbpfan` is running: `systemctl status mbpfan`
- Check if `applesmc` module loads: `modprobe applesmc`
- Check if `coretemp` module loads: `modprobe coretemp`
- Tune thresholds in `/etc/mbpfan.conf` if temps are too high or fan is too aggressive

---

## Key References

- [Proxmox: SDN Fabrics Documentation](https://pve.proxmox.com/pve-docs/chapter-pvesdn.html#pvesdn_config_fabrics)
- [Proxmox: Deploy Hyper-Converged Ceph Cluster](https://pve.proxmox.com/wiki/Deploy_Hyper-Converged_Ceph_Cluster)
- [Proxmox: Full Mesh Network for Ceph](https://pve.proxmox.com/wiki/Full_Mesh_Network_for_Ceph_Server)
- [scyto's Thunderbolt Networking Guide (GitHub Gist)](https://gist.github.com/scyto/67fdc9a517faefa68f730f82d7fa3570)
- [scyto's Proxmox Cluster Setup (GitHub Gist)](https://gist.github.com/scyto/645193291b9a81eb3cb6ebefe68274ae)
- [T2 Linux Wiki](https://wiki.t2linux.org/)
- [Proxmox Forum: Thunderbolt as Ceph Network](https://forum.proxmox.com/threads/thunderbolt-as-ceph-network-in-pve-cluster.119019/)
- [Linux Kernel: Thunderbolt Networking](https://docs.kernel.org/admin-guide/thunderbolt.html)

## Inspired by
- https://gist.github.com/scyto/76e94832927a89d977ea989da157e9dc
- https://github.com/linucksrox/proxmox-cluster/blob/main/thunderbolt-net.md
- https://git.k-space.ee/k-space/ansible/src/branch/main/proxmox

## Code and documentation Generated by
- Claude Opus
- Claude Sonnet

## Design and ML models supervision by
- martin@mlp.ee (@martinl)