# Usage Examples

## Basic Usage

### Example 1: Installing Ubuntu 22.04 LTS

```bash
# Run the script as root
sudo ./reimage.sh

# Select option 2 from the menu
# Enter '2' for Ubuntu 22.04 LTS

# Review the configuration shown
# Type 'YES' when prompted to confirm

# Wait for installation to complete (typically 10-30 minutes)
# Choose 'yes' to reboot immediately or 'no' to reboot later
```

### Example 2: Installing Debian 12

```bash
sudo ./reimage.sh

# Select option 4 for Debian 12
# Confirm with 'YES'
# Wait for completion
```

### Example 3: Using a Custom Image

```bash
sudo ./reimage.sh

# Select option 9 for Custom Image
# Enter the image URL when prompted:
# https://example.com/myos-cloud-image.qcow2
# 
# Enter SHA256 checksum (or press Enter to skip):
# abc123def456...
#
# Confirm with 'YES'
```

## Pre-Installation Steps

### 1. Create a Backup (Recommended)

Using Azure CLI:

```bash
# Create a snapshot of the OS disk
az snapshot create \
  --resource-group myResourceGroup \
  --name myVM-os-snapshot-$(date +%Y%m%d) \
  --source $(az vm show -g myResourceGroup -n myVM --query "storageProfile.osDisk.managedDisk.id" -o tsv)
```

Using Azure Portal:
1. Navigate to your VM
2. Select "Disks" from left menu
3. Click on the OS disk
4. Click "Create snapshot"
5. Name it and create

### 2. Test Network Access

Ensure you can access the VM via Azure Serial Console:

1. Azure Portal → Virtual Machine → Support + troubleshooting → Serial Console
2. Log in to verify serial console works
3. This is your backup access if SSH fails

### 3. Document Current Configuration

```bash
# Save current network configuration
sudo cp /etc/netplan/*.yaml ~/backup/
# or for older systems
sudo cp /etc/network/interfaces ~/backup/

# Save SSH configuration
sudo cp -r /etc/ssh ~/backup/

# Save cloud-init configuration
sudo cp -r /etc/cloud ~/backup/
```

## Post-Installation Verification

### 1. Check SSH Access

After reboot, test SSH connection:

```bash
ssh user@your-vm-ip
```

If SSH works, your SSH keys were preserved correctly!

### 2. Verify Network Configuration

```bash
# Check network interfaces
ip addr show

# Check network connectivity
ping -c 4 8.8.8.8

# Check DNS resolution
nslookup google.com

# For netplan systems
sudo netplan status
```

### 3. Verify Cloud-Init Status

```bash
# Check cloud-init status
sudo cloud-init status

# View cloud-init logs
sudo cat /var/log/cloud-init.log

# Verify SSH keys weren't regenerated
sudo grep "ssh_deletekeys" /etc/cloud/cloud.cfg.d/99-azure-preserve.cfg
```

### 4. Verify Azure Agent

```bash
# Check waagent status
sudo systemctl status walinuxagent

# View waagent logs
sudo cat /var/log/waagent.log

# Verify SSH key settings
sudo grep "RegenerateSshHostKeyPair" /etc/waagent.conf
```

### 5. Check Installed OS

```bash
# Verify OS version
cat /etc/os-release

# Check kernel version
uname -a

# Check disk partitions
lsblk
```

## Troubleshooting Scenarios

### Scenario 1: Lost SSH Access After Reboot

**Symptom**: Cannot SSH to the VM after reboot

**Solution via Azure Serial Console**:

```bash
# 1. Access VM via Azure Serial Console
# 2. Log in (you may need to reset password via Azure Portal first)

# 3. Restore SSH keys from backup
sudo cp -a /tmp/azure_backup_*/ssh/ssh_host_* /etc/ssh/
sudo cp -a /tmp/azure_backup_*/ssh/root_ssh/* /root/.ssh/
sudo chmod 600 /root/.ssh/*

# 4. Restart SSH service
sudo systemctl restart sshd

# 5. Test SSH connection
```

### Scenario 2: Network Not Working

**Symptom**: No network connectivity after reboot

**Solution via Azure Serial Console**:

```bash
# 1. Check if network config was restored
ls /etc/netplan/

# 2. If missing, restore from backup
sudo cp -a /tmp/azure_backup_*/network/*.yaml /etc/netplan/

# 3. Apply netplan configuration
sudo netplan apply

# 4. Restart networking
sudo systemctl restart systemd-networkd

# 5. For legacy systems
sudo cp -a /tmp/azure_backup_*/network/interfaces /etc/network/
sudo systemctl restart networking
```

### Scenario 3: Boot Failure

**Symptom**: VM doesn't boot, stuck at boot screen

**Solution**:

1. Stop the VM from Azure Portal
2. Create a recovery VM in same region
3. Detach OS disk from original VM
4. Attach OS disk to recovery VM as data disk
5. Mount the disk on recovery VM:
   ```bash
   sudo mkdir /mnt/rescue
   sudo mount /dev/sdc2 /mnt/rescue  # Adjust device as needed
   sudo mount /dev/sdc1 /mnt/rescue/boot/efi
   ```
6. Check and fix boot configuration:
   ```bash
   # Check fstab
   sudo cat /mnt/rescue/etc/fstab
   
   # Check GRUB
   sudo cat /mnt/rescue/boot/grub/grub.cfg
   
   # Reinstall GRUB if needed
   sudo mount --bind /dev /mnt/rescue/dev
   sudo mount --bind /proc /mnt/rescue/proc
   sudo mount --bind /sys /mnt/rescue/sys
   sudo chroot /mnt/rescue
   grub-install /dev/sdc  # Adjust device
   update-grub
   exit
   ```
7. Unmount and reattach to original VM

### Scenario 4: Cloud-Init Regenerated SSH Keys

**Symptom**: SSH keys changed after reboot, "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"

**Prevention**:

The script should have created `/etc/cloud/cloud.cfg.d/99-azure-preserve.cfg` with:
```yaml
ssh_deletekeys: false
ssh_genkeytypes: []
```

**Fix if it happened**:

```bash
# Via Azure Serial Console or password auth

# 1. Restore keys from backup
sudo cp -a /tmp/azure_backup_*/ssh/ssh_host_* /etc/ssh/

# 2. Ensure cloud-init won't regenerate
sudo tee /etc/cloud/cloud.cfg.d/99-preserve-keys.cfg << 'EOF'
ssh_deletekeys: false
ssh_genkeytypes: []
EOF

# 3. Restart SSH
sudo systemctl restart sshd

# 4. On your local machine, remove old key from known_hosts
ssh-keygen -R your-vm-ip
```

## Advanced Usage

### Using with Ansible/Automation

```bash
# Non-interactive usage (requires modification)
# Create an answer file
cat > /tmp/reimage-answers.txt << 'EOF'
2
YES
yes
EOF

# Run script with input redirection
sudo ./reimage.sh < /tmp/reimage-answers.txt
```

### Parallel Installation on Multiple VMs

```bash
#!/bin/bash
# parallel-reimage.sh

VMS=("vm1" "vm2" "vm3")

for vm in "${VMS[@]}"; do
    (
        echo "Reimaging $vm..."
        ssh "$vm" 'bash -s' < reimage.sh << 'ANSWERS'
2
YES
yes
ANSWERS
    ) &
done

wait
echo "All VMs reimaged!"
```

### Creating a Custom Image with Your Configuration

After successful reimage, you can create a custom Azure image:

```bash
# 1. Generalize the VM (makes it reusable)
sudo waagent -deprovision+user -force

# 2. From your local machine, create image
az vm deallocate --resource-group myRG --name myVM
az vm generalize --resource-group myRG --name myVM
az image create \
  --resource-group myRG \
  --name myCustomImage \
  --source myVM

# 3. Create new VMs from this image
az vm create \
  --resource-group myRG \
  --name newVM \
  --image myCustomImage \
  --admin-username azureuser \
  --generate-ssh-keys
```

## Monitoring the Installation

### Follow the Log in Real-Time

In a separate SSH session (before running reimage.sh):

```bash
# Monitor the log file
tail -f /reinstall.log
```

### Estimate Completion Time

Typical timings:
- Download (varies by internet speed): 2-10 minutes
- Disk operations: 5-10 minutes
- Filesystem copy: 5-15 minutes
- Bootloader installation: 2-5 minutes

**Total**: 15-40 minutes depending on image size and system speed

## Recovery Plan

If something goes wrong, you have several recovery options:

### Option 1: Use the Backup Directory

```bash
# Backup is preserved at /tmp/azure_backup_*
ls /tmp/azure_backup_*

# Restore specific files manually
sudo cp -a /tmp/azure_backup_*/ssh/* /etc/ssh/
```

### Option 2: Use Azure Snapshot

```bash
# List snapshots
az snapshot list --resource-group myRG -o table

# Create disk from snapshot
az disk create \
  --resource-group myRG \
  --name recovered-os-disk \
  --source myVM-os-snapshot-20251207

# Swap OS disk
az vm update \
  --resource-group myRG \
  --name myVM \
  --os-disk recovered-os-disk
```

### Option 3: Rollback via Azure Portal

1. Stop the VM
2. Go to Disks
3. Swap OS disk back to snapshot-based disk
4. Start the VM

## Best Practices

1. **Always test in dev environment first**
2. **Create Azure snapshots before running**
3. **Verify SSH access via Serial Console works**
4. **Document your custom configurations**
5. **Run during maintenance window**
6. **Have rollback plan ready**
7. **Monitor the log file during installation**
8. **Verify all services after reboot**

## Common Questions

**Q: Will this delete my data?**
A: Yes! This script completely wipes the OS disk. Always backup data first.

**Q: Can I run this on a production VM?**
A: Only during scheduled maintenance with proper backups.

**Q: How long does it take?**
A: Typically 15-40 minutes depending on image size and internet speed.

**Q: Will I lose SSH access?**
A: No, if everything works correctly. SSH keys are preserved. But always have Azure Serial Console access ready.

**Q: Can I cancel once started?**
A: Not safely. Once disk partitioning begins, cancellation will leave the system unbootable.

**Q: What if my network is different after reboot?**
A: The script preserves /etc/netplan/ and /etc/network/interfaces. If network is different, restore from /tmp/azure_backup_*.

**Q: Does this work on ARM-based Azure VMs?**
A: The current script is designed for x86_64 architecture. ARM support would require modifications.

**Q: Can I add more OS options?**
A: Yes! Edit the `get_image_info()` function and add your image URL and SHA256.
