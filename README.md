# PVE RAMFS Manager

A systemd service that significantly reduces disk I/O operations on Proxmox VE nodes by storing frequently-written data (pve-cluster configs and RRD statistics) in RAM instead of on disk.

**Based on:** [pmxcfs-ram](https://github.com/isasmendiagus/pmxcfs-ram) by Agustin Santiago Isasmendi

## 🎯 Problem Statement

Proxmox VE clusters can generate significant disk writes (often 5-10GB+ daily) even when no VMs or containers are running. This primarily comes from:

- **pmxcfs** (Proxmox Cluster File System) - constantly syncing cluster configuration
- **rrdcached** - writing performance statistics every few seconds

For systems using consumer-grade NVMe/SSD drives, this constant writing can significantly reduce drive lifespan.

## 💡 Solution

`pve-ramfs-manager` mounts these data directories in RAM (using `/dev/shm`), dramatically reducing disk writes while:
- Periodically persisting data to disk (configurable intervals)
- Ensuring data is safely written during graceful shutdowns
- Automatically restoring data on system startup

## 📊 Expected Results

- **Disk writes reduced by 80-95%** for idle nodes
- Consumer NVMe/SSD lifespan significantly extended
- No performance impact (RAM is faster than disk)
- Negligible RAM usage (~50-200MB depending on cluster size)

---

## 📋 Features

- ✅ Manages both `pve-cluster` and `rrdcached` data
- ✅ Configurable persistence intervals for each service
- ✅ Graceful shutdown with guaranteed data persistence
- ✅ Automatic data restoration on boot
- ✅ Comprehensive logging to `/var/log/pve-ramfs-manager.log`
- ✅ Individual enable/disable toggles for each component
- ✅ Protection against data loss with persistent storage backup

---

## ⚠️ Warnings and Considerations

### **CRITICAL WARNINGS**

1. **TEST IN NON-PRODUCTION FIRST**: Always test on a non-critical node before deploying to production
2. **BACKUP YOUR DATA**: Before installation, backup:
   - `/etc/pve/` directory
   - `/var/lib/pve-cluster/`
   - `/var/lib/rrdcached/db/`
3. **POWER LOSS RISK**: Data written to RAM but not yet persisted will be lost during unexpected power loss
   - Use a UPS (Uninterruptible Power Supply) for production systems
   - Consider shorter persistence intervals for critical environments
4. **KERNEL PANICS**: Unexpected kernel panics may result in data loss of unpersisted changes
5. **DISK SPACE**: Requires additional disk space for persistent storage backups

### **Important Considerations**

- **RAM Usage**: Allocates ~50-200MB of RAM depending on cluster size and RRD data
- **Persistence Trade-off**: Longer intervals = fewer disk writes but higher risk during crashes
- **Cluster Quorum**: In multi-node clusters, other nodes maintain configuration redundancy
- **RRD Data Loss**: Historical statistics lost since last persistence are not critical (regenerate over time)
- **First Boot**: Initial setup may take 30-60 seconds while copying existing data

### **When NOT to Use This**

- Systems without adequate RAM (minimum 4GB recommended)
- Systems without UPS protection (if using long persistence intervals)
- Single-node setups where any config loss is unacceptable
- Environments with unstable power or frequent kernel issues

---

## 🚀 Installation

### Prerequisites

- Proxmox VE 7.x or 8.x
- Root access
- At least 500MB free RAM
- Systemd-based system

### Step 1: Download and Install Script

```bash
# Download the script
wget -O /usr/local/bin/pve-ramfs-manager.sh https://raw.githubusercontent.com/yourusername/pve-ramfs-manager/main/pve-ramfs-manager.sh

# Make it executable
chmod +x /usr/local/bin/pve-ramfs-manager.sh
```

### Step 2: Configure the Script

Edit `/usr/local/bin/pve-ramfs-manager.sh` to adjust settings:

```bash
nano /usr/local/bin/pve-ramfs-manager.sh
```

Key configuration options:

```bash
# Enable/disable components
PVE_CLUSTER_ENABLED=true          # Set to false to disable pve-cluster management
RRDCACHED_ENABLED=true            # Set to false to disable rrdcached management

# Persistence intervals (in seconds)
PVE_CLUSTER_PERSIST_INTERVAL=3600 # 1 hour (0 = only on shutdown)
RRDCACHED_PERSIST_INTERVAL=3600   # 1 hour (0 = only on shutdown)
```

**Recommended intervals:**
- **Conservative**: 1800 (30 minutes)
- **Balanced**: 3600 (1 hour) - default
- **Aggressive**: 7200 (2 hours) - only with UPS

### Step 3: Install Systemd Service

```bash
# Download service file
wget -O /etc/systemd/system/pve-ramfs-manager.service https://raw.githubusercontent.com/yourusername/pve-ramfs-manager/main/pve-ramfs-manager.service

# Reload systemd
systemctl daemon-reload
```

### Step 4: Backup Existing Data

```bash
# Create backup directory
mkdir -p /root/pve-backup

# Backup pve-cluster data
cp -a /var/lib/pve-cluster /root/pve-backup/

# Backup rrdcached data
cp -a /var/lib/rrdcached/db /root/pve-backup/

# Backup Proxmox config
tar czf /root/pve-backup/etc-pve-backup.tar.gz /etc/pve/
```

### Step 5: Enable and Start Service

```bash
# Enable service to start on boot
systemctl enable pve-ramfs-manager.service

# Start the service
systemctl start pve-ramfs-manager.service

# Check status
systemctl status pve-ramfs-manager.service

# Check logs
tail -f /var/log/pve-ramfs-manager.log
```

### Step 6: Verify Installation

```bash
# Check if directories are mounted in RAM
mount | grep shm

# Should show something like:
# /dev/shm/pve-cluster-ram on /var/lib/pve-cluster type none (rw,relatime,bind)
# /dev/shm/rrdcached-ram on /var/lib/rrdcached/db type none (rw,relatime,bind)

# Check persistent directories exist
ls -la /var/lib/pve-cluster-persistent/
ls -la /var/lib/rrdcached-persistent/

# Monitor disk writes (before and after)
iostat -x 1
```

---

## 📊 Monitoring

### Check Service Status

```bash
systemctl status pve-ramfs-manager.service
```

### View Logs

```bash
# Real-time log monitoring
tail -f /var/log/pve-ramfs-manager.log

# View recent logs
journalctl -u pve-ramfs-manager.service -f

# Check for errors
grep ERROR /var/log/pve-ramfs-manager.log
```

### Monitor Disk Writes

```bash
# Install iotop if not present
apt install iotop

# Monitor I/O in real-time
iotop -o

# Check total writes over time
iostat -x -d 5
```

### Check RAM Usage

```bash
# View /dev/shm usage
df -h /dev/shm

# Detailed RAM mount sizes
du -sh /dev/shm/pve-cluster-ram
du -sh /dev/shm/rrdcached-ram
```

---

## 🔧 Configuration Examples

### Conservative (30-minute persistence)

Best for systems without UPS or critical production environments:

```bash
PVE_CLUSTER_PERSIST_INTERVAL=1800
RRDCACHED_PERSIST_INTERVAL=1800
```

### Balanced (1-hour persistence) - Default

Good for most systems with UPS:

```bash
PVE_CLUSTER_PERSIST_INTERVAL=3600
RRDCACHED_PERSIST_INTERVAL=3600
```

### Aggressive (only shutdown persistence)

Maximum disk write reduction, requires reliable UPS:

```bash
PVE_CLUSTER_PERSIST_INTERVAL=0
RRDCACHED_PERSIST_INTERVAL=0
```

### PVE Cluster Only

Only manage cluster configs, leave RRD on disk:

```bash
PVE_CLUSTER_ENABLED=true
RRDCACHED_ENABLED=false
```

---

## 🛠️ Troubleshooting

### Service Fails to Start

```bash
# Check if paths are already mounted
mount | grep -E "pve-cluster|rrdcached"

# If mounted, unmount them
umount /var/lib/pve-cluster
umount /var/lib/rrdcached/db

# Try starting again
systemctl start pve-ramfs-manager.service
```

### Data Not Persisting

```bash
# Manually trigger persistence
systemctl reload pve-ramfs-manager.service

# Check disk space
df -h /var/lib/

# Check permissions
ls -la /var/lib/pve-cluster-persistent/
ls -la /var/lib/rrdcached-persistent/
```

### High Memory Usage

```bash
# Check actual usage
du -sh /dev/shm/pve-cluster-ram
du -sh /dev/shm/rrdcached-ram

# If RRD data is too large, consider:
# 1. Reducing RRD retention period
# 2. Disabling RRDCached RAM management (RRDCACHED_ENABLED=false)
```

### Restoring from Backup

If something goes wrong:

```bash
# Stop the service
systemctl stop pve-ramfs-manager.service
systemctl disable pve-ramfs-manager.service

# Unmount RAM directories
umount /var/lib/pve-cluster
umount /var/lib/rrdcached/db

# Restore from backup
cp -a /root/pve-backup/pve-cluster/* /var/lib/pve-cluster/
cp -a /root/pve-backup/db/* /var/lib/rrdcached/db/

# Restart services
systemctl start pve-cluster.service
systemctl start rrdcached.service
```

---

## 🗑️ Uninstallation

```bash
# Stop and disable service
systemctl stop pve-ramfs-manager.service
systemctl disable pve-ramfs-manager.service

# Remove service file
rm /etc/systemd/system/pve-ramfs-manager.service

# Reload systemd
systemctl daemon-reload

# Remove script
rm /usr/local/bin/pve-ramfs-manager.sh

# Optional: Remove persistent data (CAUTION!)
# rm -rf /var/lib/pve-cluster-persistent
# rm -rf /var/lib/rrdcached-persistent

# Remove log file
rm /var/log/pve-ramfs-manager.log
```

---

## 📈 Expected Disk Write Reduction

**Before pve-ramfs-manager:**
- Typical idle node: 5-10GB writes per day
- Active cluster: 15-30GB writes per day

**After pve-ramfs-manager:**
- Idle node: 0.5-2GB writes per day (80-90% reduction)
- Active cluster: 3-8GB writes per day (70-80% reduction)

Actual results vary based on:
- Cluster size and activity
- Number of VMs/containers
- Persistence interval settings
- Other system processes

---

## 🤝 Contributing

Contributions are welcome! Please:
1. Test thoroughly before submitting
2. Update documentation for any changes
3. Follow the existing code style
4. Add comments for complex logic

---

## 🙏 Credits

This project is based on [pmxcfs-ram](https://github.com/isasmendiagus/pmxcfs-ram) by [Agustin Santiago Isasmendi](https://github.com/isasmendiagus), which provides the original implementation for managing pmxcfs data in RAM.

Key enhancements in this version:
- Consolidated management of both pve-cluster and rrdcached
- Fixed boolean logic bugs from the original
- Added proper unmounting on shutdown
- Enhanced error handling and logging
- Configurable persistence intervals per component
- Comprehensive documentation and safety warnings

---

## 📄 License

MIT License - See script header for full license text

---

## ⚡ Quick Start TL;DR

```bash
# 1. Backup your data
mkdir -p /root/pve-backup
cp -a /var/lib/pve-cluster /root/pve-backup/
cp -a /var/lib/rrdcached/db /root/pve-backup/

# 2. Install script
wget -O /usr/local/bin/pve-ramfs-manager.sh [URL]
chmod +x /usr/local/bin/pve-ramfs-manager.sh

# 3. Install service
wget -O /etc/systemd/system/pve-ramfs-manager.service [URL]
systemctl daemon-reload

# 4. Enable and start
systemctl enable --now pve-ramfs-manager.service

# 5. Verify
tail -f /var/log/pve-ramfs-manager.log
```

---

## 📞 Support

- **Issues**: Open an issue on GitHub
- **Logs**: Always include `/var/log/pve-ramfs-manager.log` when reporting issues
- **System Info**: Include Proxmox version and kernel version

---

**Remember:** Always test in a non-production environment first! 🧪
