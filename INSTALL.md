# Quick Installation Guide

## Prerequisites

- Azure VM running Ubuntu or Debian
- Root/sudo access
- Internet connectivity
- Sufficient disk space in `/tmp` (at least 5GB free)

## Installation Steps

### 1. Download the Script

**Option A: Using wget**
```bash
wget https://raw.githubusercontent.com/Toton-dhibar/Azch/main/reimage.sh
```

**Option B: Using curl**
```bash
curl -O https://raw.githubusercontent.com/Toton-dhibar/Azch/main/reimage.sh
```

**Option C: Using git**
```bash
git clone https://github.com/Toton-dhibar/Azch.git
cd Azch
```

### 2. Make Script Executable

```bash
chmod +x reimage.sh
```

### 3. Verify Script

```bash
# Check script syntax
bash -n reimage.sh

# View script size
wc -l reimage.sh

# View first few lines
head -20 reimage.sh
```

### 4. Create Backup (CRITICAL!)

**Using Azure Portal:**
1. Go to your VM in Azure Portal
2. Click on "Disks" in the left menu
3. Click on the OS disk name
4. Click "Create snapshot"
5. Give it a name like "pre-reimage-backup-YYYYMMDD"
6. Click "Review + Create"
7. Wait for snapshot creation to complete

**Using Azure CLI:**
```bash
# Get your VM's OS disk ID
DISK_ID=$(az vm show \
  --resource-group YOUR_RESOURCE_GROUP \
  --name YOUR_VM_NAME \
  --query "storageProfile.osDisk.managedDisk.id" \
  --output tsv)

# Create snapshot
az snapshot create \
  --resource-group YOUR_RESOURCE_GROUP \
  --name "pre-reimage-$(date +%Y%m%d-%H%M%S)" \
  --source "$DISK_ID"
```

### 5. Test Azure Serial Console Access

**IMPORTANT**: Ensure you can access the VM via Serial Console before proceeding!

1. Azure Portal → Your VM → Support + troubleshooting → Serial Console
2. Press Enter to get login prompt
3. Log in to verify it works
4. This is your emergency access if SSH fails

### 6. Run the Script

```bash
sudo ./reimage.sh
```

### 7. Follow Interactive Prompts

1. Select OS from menu (0-9)
2. Review configuration details
3. Type `YES` (in capitals) to confirm
4. Wait for completion (15-40 minutes)
5. Choose whether to reboot immediately

### 8. Post-Reboot Verification

After the VM reboots:

```bash
# Test SSH connection
ssh user@your-vm-ip

# Check OS version
cat /etc/os-release

# Verify network
ip addr
ping -c 4 google.com

# Check disk layout
lsblk
df -h
```

## Quick Reference

### File Locations

- **Script**: `reimage.sh`
- **Log**: `/reinstall.log`
- **Backup**: `/tmp/azure_backup_*`
- **Documentation**: `README.md`, `USAGE.md`

### Menu Options

```
1) Ubuntu 24.04 LTS
2) Ubuntu 22.04 LTS
3) Ubuntu 20.04 LTS
4) Debian 12
5) AlmaLinux 8
6) Rocky Linux 8
7) CentOS Stream 9
8) Alpine Linux 3.19
9) Custom Image
0) Exit
```

### Typical Timeline

| Phase | Duration |
|-------|----------|
| Dependency Installation | 1-2 min |
| Backup Creation | <1 min |
| Image Download | 2-10 min |
| Disk Operations | 5-10 min |
| Filesystem Copy | 5-15 min |
| Bootloader Install | 2-5 min |
| **Total** | **15-40 min** |

### Emergency Recovery

**If SSH is lost after reboot:**

1. Access via Azure Serial Console
2. Restore SSH keys:
   ```bash
   sudo cp -a /tmp/azure_backup_*/ssh/ssh_host_* /etc/ssh/
   sudo cp -a /tmp/azure_backup_*/ssh/root_ssh/* /root/.ssh/
   sudo systemctl restart sshd
   ```

**If boot fails:**

1. Stop VM in Azure Portal
2. Create recovery VM
3. Attach OS disk to recovery VM as data disk
4. Mount and fix boot issues
5. Or restore from snapshot

### Support

- **Documentation**: See `README.md` for full details
- **Examples**: See `USAGE.md` for scenarios
- **Logs**: Check `/reinstall.log` for errors
- **Backup**: Files in `/tmp/azure_backup_*`

### Warning

⚠️ **THIS SCRIPT WILL DESTROY ALL DATA ON THE OS DISK**

- Always create Azure snapshots first
- Test in dev environment first
- Have rollback plan ready
- Ensure Serial Console access works
- Run during maintenance window

---

## One-Line Install & Run

**For the brave** (not recommended without testing):

```bash
wget -O reimage.sh https://raw.githubusercontent.com/Toton-dhibar/Azch/main/reimage.sh && \
chmod +x reimage.sh && \
sudo ./reimage.sh
```

## Minimum System Requirements

- **OS**: Ubuntu 18.04+ or Debian 10+
- **RAM**: 1GB+ (2GB+ recommended)
- **Disk**: 30GB+ OS disk
- **Temp Space**: 5GB+ free in `/tmp`
- **Network**: Stable internet connection
- **Permissions**: Root/sudo access

## Recommended Pre-Checks

```bash
# Check available space in /tmp
df -h /tmp

# Check current OS
cat /etc/os-release

# Check root access
sudo -v

# Check internet connectivity
ping -c 2 google.com

# Check current disk layout
lsblk
```

## Post-Installation Checklist

- [ ] SSH access restored
- [ ] Network connectivity working
- [ ] OS version correct (`cat /etc/os-release`)
- [ ] Disk partitions correct (`lsblk`)
- [ ] Services running (`systemctl status`)
- [ ] Azure agent running (`systemctl status walinuxagent`)
- [ ] Cloud-init configured (`cloud-init status`)
- [ ] Log file reviewed (`cat /reinstall.log`)
- [ ] Backup still available (`ls /tmp/azure_backup_*`)

## Cleanup After Success

Once everything is verified working:

```bash
# Optional: Remove backup (only if you're sure!)
# sudo rm -rf /tmp/azure_backup_*

# Optional: Remove downloaded images
# sudo rm -rf /tmp/os_download_*

# Optional: Archive log
sudo gzip /reinstall.log
sudo mv /reinstall.log.gz ~/reimage-$(date +%Y%m%d).log.gz
```

## Getting Help

If you encounter issues:

1. Check `/reinstall.log` for error messages
2. Review `README.md` troubleshooting section
3. Check `USAGE.md` for similar scenarios
4. Use Azure Serial Console for emergency access
5. Restore from snapshot if needed

---

**Ready to proceed? Good luck! 🚀**

Remember: **Test first, backup always, deploy carefully!**
