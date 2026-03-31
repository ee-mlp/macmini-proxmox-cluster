# Proxmox VE 9.0 + Ceph Cluster: 3× Mac Mini 2018 with Thunderbolt Networking

## Architecture Overview

```
          ┌──────────┐
     ┌────┤  Mini 1   ├────┐
     │    │ (pve1)    │    │
     │    └──────────┘    │        1GbE (management/corosync)
     │ TB3    ▲    TB3    │        ─── each node to LAN switch
     │        │ 1GbE      │
  ┌──┴─────┐  │  ┌──────┴──┐      Thunderbolt 3 (Ceph traffic)
  │ Mini 2  ├──┘──┤ Mini 3  │      ─── direct point-to-point cables
  │ (pve2)  ├─────┤ (pve3)  │          full mesh, no switch needed
  └─────────┘ TB3 └─────────┘
```

**Networks:**

| Network          | Interface       | Subnet            | Purpose                              |
|-----------------|-----------------|-------------------|--------------------------------------|
| Management/LAN  | Ethernet (1GbE) | 10.10.15.0/24     | Proxmox GUI, corosync, VM traffic    |
| Ceph (public+cluster) | Thunderbolt mesh | 10.10.16.0/24 | All Ceph replication + client traffic |

**Hardware per node:** Mac Mini 2018 (i7-8700B, 32-64GB RAM, 4× Thunderbolt 3 ports, 1× 1GbE, 2× USB-A)

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
3. **Target disk:** Select the internal Apple NVMe. With PVE 9.0 (kernel 6.14), it's recognized out of the box.
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

### 2.3 T2 Support (already included in PVE 9.0)

Proxmox VE 9.0 ships with Linux kernel 6.14, which includes T2 chip support for the Mac Mini 2018 out of the box. The internal NVMe, Thunderbolt ports, and basic hardware all work without additional kernel patches.

> **Note:** Wi-Fi and Bluetooth may still require Apple firmware blobs. Since you'll be using wired Ethernet for management, this is typically not an issue for a server use case. If you need Wi-Fi, follow the [t2linux wiki firmware guide](https://wiki.t2linux.org/guides/postinstall/#apple-firmware).

### 2.4 Fan Control (important!)

Without macOS, the fan controller defaults to low RPM. The `mbpfan` daemon is available directly from the Debian Trixie repos:

```bash
apt install mbpfan
systemctl enable mbpfan
systemctl start mbpfan
```

Verify it's working with `systemctl status mbpfan`. The daemon reads CPU temperatures via `coretemp` and controls fans via `applesmc`. You can tune thresholds in `/etc/mbpfan.conf` if needed.

---

## Phase 3: Set Up Thunderbolt Mesh Network

### 3.1 Physical Cabling

The Mac Mini 2018 has 4 Thunderbolt 3 ports on the back, managed by 2 independent controllers (Intel JHL7540). Each controller handles a pair of ports, sharing 40 Gbps bandwidth within the pair:

```
Back of Mac Mini 2018 (looking at the rear)

 Power  Ethernet  HDMI  USB-A  USB-A  ①  ②  ③  ④
                                       └─Bus A─┘  └─Bus B─┘
                                       (shared    (shared
                                        40 Gbps)   40 Gbps)
```

**For maximum performance, use one port from each bus per node** — this gives each Thunderbolt network link a dedicated 40 Gbps controller instead of sharing bandwidth. Connect cables to ports ② and ③ (one from Bus A, one from Bus B):

| Cable | From             | To               |
|-------|------------------|------------------|
| 1     | pve1 port ② (Bus A) | pve2 port ② (Bus A) |
| 2     | pve1 port ③ (Bus B) | pve3 port ② (Bus A) |
| 3     | pve2 port ③ (Bus B) | pve3 port ③ (Bus B) |

Each node uses both of its Thunderbolt controllers, one cable to each of the other two nodes. This ensures each link gets the full 40 Gbps without contention.

> **Does it matter which specific port within a bus?** No — ports ① and ② are interchangeable (both on Bus A), as are ③ and ④ (both on Bus B). Just make sure you pick one from each bus. If you accidentally put both cables on the same bus, it still works — you'd get ~20 Gbps per link instead of ~40 Gbps, which is still plenty for Ceph.

### 3.2 Load Kernel Modules (all 3 nodes)

```bash
# Add thunderbolt networking modules
cat >> /etc/modules << 'EOF'
thunderbolt
thunderbolt-net
EOF
```

### 3.3 Identify Thunderbolt PCI Paths (all 3 nodes)

With cables plugged in, run:

```bash
udevadm monitor
```

Then unplug and replug each Thunderbolt cable to identify the PCI paths for each port. Look for entries like `0000:00:0d.2` and `0000:00:0d.3` (these are common on Mac Mini 2018 but verify your actual paths).

You can also check:

```bash
ls /sys/bus/thunderbolt/devices/
```

### 3.4 Create Persistent Interface Names (all 3 nodes)

Thunderbolt interface names are not stable by default. PVE 9.0 adds a `pve-network-interface-pinning` CLI tool that can pin interface names via the GUI/TUI. However, for Thunderbolt specifically, the systemd `.link` file approach is still the most reliable since TB MAC addresses change on cable insertion. Adjust the PCI paths to match what you found in step 3.3.

**On each node:**

```bash
# First thunderbolt port → en05
cat > /etc/systemd/network/00-thunderbolt0.link << 'EOF'
[Match]
Path=pci-0000:00:0d.2
Driver=thunderbolt-net
[Link]
MACAddressPolicy=none
Name=en05
EOF

# Second thunderbolt port → en06
cat > /etc/systemd/network/00-thunderbolt1.link << 'EOF'
[Match]
Path=pci-0000:00:0d.3
Driver=thunderbolt-net
[Link]
MACAddressPolicy=none
Name=en06
EOF
```

### 3.5 Configure Network Interfaces (all 3 nodes)

Add to `/etc/network/interfaces` (between `auto lo` and your existing bridge config):

```bash
# Thunderbolt interfaces — do not edit in GUI
iface en05 inet manual
iface en06 inet manual
```

### 3.6 Create udev Rules for Auto-UP (all 3 nodes)

Thunderbolt interfaces need help coming up on boot/cable insertion:

```bash
# Create udev rule
cat > /etc/udev/rules.d/10-tb-en.rules << 'EOF'
ACTION=="move", SUBSYSTEM=="net", KERNEL=="en05", RUN+="/usr/local/bin/pve-en05.sh"
ACTION=="move", SUBSYSTEM=="net", KERNEL=="en06", RUN+="/usr/local/bin/pve-en06.sh"
EOF

# Create script for en05
cat > /usr/local/bin/pve-en05.sh << 'SCRIPT'
#!/bin/bash
LOGFILE="/tmp/udev-debug.log"
IF="en05"
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

# Create script for en06
cat > /usr/local/bin/pve-en06.sh << 'SCRIPT'
#!/bin/bash
LOGFILE="/tmp/udev-debug.log"
IF="en06"
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
chmod +x /usr/local/bin/pve-en05.sh /usr/local/bin/pve-en06.sh
```

### 3.7 Configure IP Addresses for the Thunderbolt Mesh

With failover routing, if the direct TB cable between pve1↔pve3 fails, traffic automatically reroutes through pve2. This requires a routing protocol — we'll use PVE 9.0's built-in **SDN Fabrics with OpenFabric**, which manages this via the GUI.

The TB interfaces run **unnumbered** (no IP assigned directly). Instead, each node gets a **loopback IP** from 10.10.16.0/24 that Ceph and the routing protocol use as the node's identity.

**Step 1: Configure TB interfaces as unnumbered** (all 3 nodes)

Create `/etc/network/interfaces.d/thunderbolt` on each node:

```
auto en05
iface en05 inet manual
    mtu 9000

auto en06
iface en06 inet manual
    mtu 9000
```

> **MTU 9000** (jumbo frames) is recommended for Ceph performance over Thunderbolt. Some guides suggest 65520 but testing shows MTU 9000 is more reliable and avoids packet drops under heavy Ceph replication load.

**Step 2: Apply and reboot**

```bash
update-initramfs -u -k all
reboot
```

**Step 3: Create the OpenFabric fabric via GUI** (after cluster is formed — do this in Phase 4/5)

Once all 3 nodes are in the Proxmox cluster:

1. Navigate to **Datacenter → SDN → Fabrics**
2. Click **Add Fabric** → select **OpenFabric**
3. Set the fabric name to `ceph`
4. Set **IPv4 Prefix** to `10.10.16.0/24` — this defines the subnet for all node IPs in the fabric
5. Optionally set **Hello-Interval** to `1` and **CSNP-Interval** to `2` for faster failover detection
6. Add each node to the fabric (click `+` button):

   | Node | Router-ID (IPv4) | Interfaces |
   |------|-----------------|------------|
   | pve1 | 10.10.16.11     | en05, en06 |
   | pve2 | 10.10.16.12     | en05, en06 |
   | pve3 | 10.10.16.13     | en05, en06 |

   Leave interface IP fields empty — they will operate in unnumbered mode and inherit the router-ID as the loopback address.

7. Click **Create** on each node entry
8. Navigate to **Datacenter → SDN** and click **Apply Configuration**

This generates the FRR (Free Range Routing) config on each node automatically. OpenFabric will create a loopback interface with the router-ID IP on each node and establish routing adjacencies over the TB links.

**Step 4: Verify the fabric**

```bash
# Check FRR routing table
vtysh -c "show openfabric route"

# You should see routes to all 3 loopback IPs:
# 10.10.16.11/32 via en05 (or en06)
# 10.10.16.12/32 via en05 (or en06)
# 10.10.16.13/32 via en05 (or en06)

# Verify adjacencies
vtysh -c "show openfabric neighbor"

# Ping all nodes
ping -c 3 10.10.16.12   # from pve1
ping -c 3 10.10.16.13   # from pve1
```

**Step 5: Test failover**

Unplug the TB cable between pve1 and pve3. Within seconds, OpenFabric should reroute pve1↔pve3 traffic via pve2. Verify with:

```bash
# From pve1:
traceroute 10.10.16.13
# Should show pve2 (10.10.16.12) as an intermediate hop
```

Replug the cable — traffic returns to the direct path automatically.

**Summary:**

| Node | Management IP   | Ceph/Loopback IP | TB Interfaces    |
|------|----------------|------------------|------------------|
| pve1 | 10.10.15.11    | 10.10.16.11      | en05, en06 (unnumbered) |
| pve2 | 10.10.15.12    | 10.10.16.12      | en05, en06 (unnumbered) |
| pve3 | 10.10.15.13    | 10.10.16.13      | en05, en06 (unnumbered) |

> **How does Ceph use this?** When you initialize Ceph (Phase 5), set both the public and cluster network to `10.10.16.0/24`. Ceph monitors and OSDs bind to the loopback IPs (10.10.16.x), which are always reachable via whichever TB path is available. The routing protocol handles the rest.

### 3.8 Apply and Reboot

Done in step 3.7 above.

### 3.9 Verify Thunderbolt Connectivity

After all 3 nodes are up and TB interfaces are renamed:

```bash
# Check interfaces are up
ip addr show en05
ip addr show en06

# At this stage, TB interfaces have no IP — that's correct.
# IPs come from the SDN Fabric loopback after Phase 4.
# For now, just verify the interfaces exist and are UP.
ip link show en05
ip link show en06
```

Full connectivity testing (ping, iperf3, failover) happens after the SDN Fabric is configured in step 3.7, Phase 4.

### 3.10 Install Diagnostic Tools (all 3 nodes)

```bash
# LLDP — essential for verifying Thunderbolt L2 neighbor visibility
apt install lldpd iperf3 -y
systemctl enable lldpd

# Verify neighbors after all nodes are cabled
lldpctl
```

### 3.11 Enable IOMMU (all 3 nodes)

```bash
# Edit GRUB
nano /etc/default/grub

# Add to GRUB_CMDLINE_LINUX_DEFAULT:
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"

# Apply
update-grub
reboot
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

### 5.3 Create Monitors (all 3 nodes)

Each node needs a Ceph Monitor for quorum:

```bash
# On pve1 (usually created automatically during init)
pveceph mon create

# On pve2
pveceph mon create

# On pve3
pveceph mon create
```

Or via GUI: Each node → **Ceph → Monitor → Create**

### 5.4 Create Managers (all 3 nodes)

```bash
# pve1 (usually created during init)
pveceph mgr create

# pve2
pveceph mgr create

# pve3
pveceph mgr create
```

One manager will be active, the other two are standby. This ensures a manager is always available if any single node goes down.

### 5.5 Create OSDs (from the unallocated space on the internal NVMe)

Since you limited Proxmox to 64 GB during install (via `hdsize`), the rest of the NVMe is unpartitioned. You need to create a new partition in that free space, then use it as a Ceph OSD.

**Step 1: Verify free space** (on each node)

```bash
lsblk
# You should see something like:
# nvme0n1         259:0    0   1T  0 disk
# ├─nvme0n1p1     259:1    0   1M  0 part       (BIOS boot)
# ├─nvme0n1p2     259:2    0   1G  0 part       /boot/efi
# └─nvme0n1p3     259:3    0  63G  0 part       (LVM: pve-root, pve-swap, etc.)
#   ├─pve-swap    ...
#   ├─pve-root    ...
#   └─pve-data    ...
# The remaining ~936G is unallocated
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

### 6.1 Create HA Group (optional)

Via GUI: **Datacenter → HA → Groups → Create**

### 6.2 Add VMs to HA

Via GUI: **Datacenter → HA → Add** → select your VMs stored on the Ceph pool.

When a node fails, VMs with HA enabled automatically restart on a surviving node — their disks are already replicated via Ceph across the Thunderbolt mesh.

### 6.3 Set Migration Network

Configure VM live migration to use the fast Thunderbolt network:

```bash
# Edit datacenter config
nano /etc/pve/datacenter.cfg

# Add:
migration: network=10.10.16.0/24,type=secure
```

---

## Phase 7: Shared ISO Storage with CephFS (optional)

Instead of uploading ISOs to each node's local storage separately, create a CephFS filesystem so ISOs are available cluster-wide from a single upload.

### 7.1 Create MDS (Metadata Servers)

CephFS requires at least one MDS. For redundancy, create on 2-3 nodes:

```bash
pveceph mds create   # run on pve1
pveceph mds create   # run on pve2
```

### 7.2 Create CephFS

```bash
pveceph fs create --pg_num 32 --add-storage
```

This creates a CephFS filesystem and automatically adds it as a Proxmox storage. By default the storage ID is `cephfs`.

### 7.3 Configure Storage Content

Via GUI: **Datacenter → Storage → cephfs → Edit**

Set **Content** to: `ISO image, Container template, Snippets, VZDump backup file`

Now you can upload an ISO once and it's instantly available on all 3 nodes.

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
