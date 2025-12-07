# Universal OS Reimage Installer for Azure VMs

A production-grade bash script to safely reimage Azure VMs with official cloud images while preserving SSH access and network connectivity.

## Features

- ✅ **Interactive Menu**: Choose from 8 popular Linux distributions or provide a custom image URL
- ✅ **Automatic Disk Detection**: Intelligently detects the OS disk (`/dev/sda` or `/dev/nvme0n1`)
- ✅ **SHA256 Verification**: Ensures image integrity before installation
- ✅ **Multiple Mount Methods**: Supports qemu-nbd, kpartx, and dd fallback
- ✅ **GPT Partitioning**: Creates proper EFI + root partition layout
- ✅ **Configuration Preservation**: Backs up and restores:
  - SSH server and user keys
  - Network configuration (netplan/interfaces)
  - Cloud-init settings
  - Waagent configuration
- ✅ **Azure Integration**: Properly configures cloud-init and waagent to prevent key regeneration
- ✅ **GRUB Installation**: Automatically installs bootloader in chroot environment
- ✅ **Comprehensive Logging**: All operations logged to `/reinstall.log`
- ✅ **Safety Checks**: Multiple confirmations and disk size validation

## Supported Operating Systems

1. Ubuntu 24.04 LTS (Noble)
2. Ubuntu 22.04 LTS (Jammy)
3. Ubuntu 20.04 LTS (Focal)
4. Debian 12 (Bookworm)
5. AlmaLinux 8
6. Rocky Linux 8
7. CentOS Stream 9
8. Alpine Linux 3.19
9. Custom Image (user-provided URL + SHA256)

## Requirements

- Root access on an Azure VM
- Ubuntu/Debian-based host OS (for apt package manager)
- Internet connectivity to download images
- Sufficient disk space in `/tmp` for image download

## Installation

```bash
# Download the script
wget https://raw.githubusercontent.com/Toton-dhibar/Azch/main/reimage.sh

# Make it executable
chmod +x reimage.sh

# Run as root
sudo ./reimage.sh
```

## Usage

### Interactive Mode

Simply run the script and follow the prompts:

```bash
sudo ./reimage.sh
```

The script will:
1. Display an interactive menu
2. Ask you to select an OS
3. Show configuration details
4. Ask for final confirmation (type "YES")
5. Perform the installation
6. Offer to reboot

### Menu Example

```
╔═══════════════════════════════════════════════════════════════════════════╗
║         Universal OS Reimage Installer for Azure VMs v1.0                ║
╚═══════════════════════════════════════════════════════════════════════════╝

Select an OS to install:

  1) Ubuntu 24.04 LTS (Noble)
  2) Ubuntu 22.04 LTS (Jammy)
  3) Ubuntu 20.04 LTS (Focal)
  4) Debian 12 (Bookworm)
  5) AlmaLinux 8
  6) Rocky Linux 8
  7) CentOS Stream 9
  8) Alpine Linux 3.19
  9) Custom Image (provide URL + SHA256)
  0) Exit

Enter your choice [0-9]:
```

## How It Works

### 1. Pre-flight Checks
- Verifies root privileges
- Detects the OS disk automatically
- Validates disk is a block device

### 2. Dependency Installation
Automatically installs required tools:
- `qemu-utils` (qemu-img, qemu-nbd)
- `parted`, `gdisk` (partitioning)
- `dosfstools`, `e2fsprogs` (filesystem tools)
- `grub-pc-bin`, `grub-efi-amd64` (bootloader)
- `rsync`, `wget`, `curl` (file operations)
- `kpartx` (loop device mapping)

### 3. Backup Phase
Creates backup of critical files to `/tmp/azure_backup_$$`:
- `/etc/ssh/*` (SSH host keys and config)
- `/root/.ssh` and `/home/*/.ssh` (user SSH keys)
- `/etc/netplan/*` (network configuration)
- `/etc/network/interfaces` (legacy network config)
- `/etc/cloud/*` (cloud-init configuration)
- `/etc/waagent.conf` (Azure agent config)

### 4. Download & Verification
- Downloads the selected cloud image
- Verifies SHA256 checksum (if provided)
- Converts qcow2/vmdk images to raw format if needed

### 5. Disk Partitioning
- Creates new GPT partition table
- Creates 512MB EFI partition (FAT32)
- Creates root partition (ext4, uses remaining space)
- Formats both partitions

### 6. Filesystem Copy
Tries multiple methods in order:
1. Mount via qemu-nbd and rsync
2. Mount via kpartx loop device and rsync
3. Fallback to direct dd copy

### 7. Configuration Restore
- Restores SSH host keys (prevents "host key changed" warnings)
- Restores user SSH keys (maintains access)
- Restores network configuration
- Configures cloud-init to NOT regenerate SSH keys:
  ```yaml
  ssh_deletekeys: false
  ssh_genkeytypes: []
  ```
- Configures waagent to NOT regenerate SSH keys:
  ```
  Provisioning.RegenerateSshHostKeyPair=n
  ```

### 8. Bootloader Installation
- Mounts necessary filesystems in chroot
- Creates proper `/etc/fstab` with UUIDs
- Installs GRUB for EFI or BIOS
- Generates GRUB configuration
- Cleans up chroot mounts

### 9. Cleanup & Reboot
- Unmounts all filesystems
- Preserves backup directory
- Offers to reboot immediately

## Safety Features

### Disk Detection
The script intelligently detects the OS disk:
- Checks root filesystem mount point
- Handles NVMe devices (`/dev/nvme0n1`)
- Handles SCSI/SATA devices (`/dev/sda`)
- Handles LVM and encrypted volumes
- Validates disk size (warns if < 10GB)

### Confirmation Steps
1. Initial menu selection
2. Shows full configuration details
3. Requires typing "YES" in capitals to proceed

### Backup Preservation
- Backup directory is NOT deleted
- Log file preserved at `/reinstall.log`
- Can be used for manual recovery if needed

## Troubleshooting

### SSH Access Lost After Reboot

If SSH access is lost, the backup is still available. From Azure Serial Console:

```bash
# Check if backup exists
ls /tmp/azure_backup_*

# Restore SSH keys manually
cp -a /tmp/azure_backup_*/ssh/ssh_host_* /etc/ssh/
cp -a /tmp/azure_backup_*/ssh/root_ssh/* /root/.ssh/

# Restart SSH
systemctl restart sshd
```

### Network Not Working

Check if network configuration was restored:

```bash
# For netplan systems
ls /etc/netplan/

# For legacy systems
cat /etc/network/interfaces

# Reconfigure cloud-init
cloud-init clean
cloud-init init
```

### Boot Failure

If the system doesn't boot, use Azure Portal:
1. Stop the VM
2. Attach the OS disk to a recovery VM
3. Mount and check `/boot/grub/grub.cfg`
4. Verify `/etc/fstab` has correct UUIDs

### Fallback: Azure Managed Disk Swap

If direct disk modification fails, use Azure CLI:

```bash
# Stop VM
az vm deallocate --resource-group YOUR_RG --name YOUR_VM

# Create snapshot
az snapshot create --resource-group YOUR_RG --name os-backup \
  --source YOUR_OS_DISK_RESOURCE_ID

# Upload new image as managed disk
az disk create --resource-group YOUR_RG --name new-os-disk \
  --source /path/to/image.vhd --os-type Linux

# Swap OS disk
az vm update --resource-group YOUR_RG --name YOUR_VM --os-disk new-os-disk

# Start VM
az vm start --resource-group YOUR_RG --name YOUR_VM
```

## Logs

All operations are logged to `/reinstall.log` with timestamps:

```
[2025-12-07 16:45:23] ==========================================
[2025-12-07 16:45:23] Universal OS Reimage Installer Started
[2025-12-07 16:45:23] ==========================================
[2025-12-07 16:45:23] Detecting OS disk...
[2025-12-07 16:45:23] Root filesystem is on: /dev/sda2
[2025-12-07 16:45:23] Detected OS disk: /dev/sda
...
```

## Security Considerations

### What This Script Does
- ✅ Preserves SSH authorized_keys
- ✅ Preserves SSH host keys
- ✅ Maintains network access
- ✅ Configures cloud-init securely
- ✅ Verifies image checksums

### What This Script Does NOT Do
- ❌ Does NOT preserve user data (backup first!)
- ❌ Does NOT preserve installed applications
- ❌ Does NOT preserve system logs
- ❌ Does NOT create Azure snapshots (do this manually)

### Before Running
1. **Backup all important data** - This script DESTROYS all data!
2. Create an Azure snapshot of the OS disk (optional but recommended)
3. Document any custom configurations
4. Test in a non-production environment first

## Technical Details

### Partition Layout

```
/dev/sda (or /dev/nvme0n1)
├── Partition 1: 512MB EFI System Partition (FAT32)
│   └── Mounted at: /boot/efi
└── Partition 2: Remaining space (ext4)
    └── Mounted at: /
```

### Cloud-Init Configuration

The script creates `/etc/cloud/cloud.cfg.d/99-azure-preserve.cfg`:

```yaml
datasource_list: [ Azure ]
ssh_deletekeys: false
ssh_genkeytypes: []
disable_root: false
preserve_hostname: false
no_ssh_fingerprints: false

datasource:
  Azure:
    apply_network_config: true
```

### Waagent Configuration

Modified settings in `/etc/waagent.conf`:
```
Provisioning.RegenerateSshHostKeyPair=n
Provisioning.DeleteRootPassword=n
```

## Image Sources

### Ubuntu
- 24.04: https://cloud-images.ubuntu.com/releases/24.04/release/
- 22.04: https://cloud-images.ubuntu.com/releases/22.04/release/
- 20.04: https://cloud-images.ubuntu.com/releases/20.04/release/

### Debian
- 12: https://cloud.debian.org/images/cloud/bookworm/latest/

### AlmaLinux
- 8: https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/

### Rocky Linux
- 8: https://download.rockylinux.org/pub/rocky/8/images/x86_64/

### CentOS Stream
- 9: https://cloud.centos.org/centos/9-stream/x86_64/images/

### Alpine Linux
- 3.19: https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/cloud/

## Known Limitations

1. **Requires root access** - Cannot run as non-root user
2. **Ubuntu/Debian host only** - Uses apt package manager
3. **No rollback** - Once started, cannot undo (use Azure snapshots)
4. **Network dependency** - Requires internet to download images
5. **Disk space** - Needs 2x image size in `/tmp` (download + conversion)

## Contributing

This is a production-grade script. If you find issues or have improvements:
1. Test thoroughly in a non-production environment
2. Document the issue and solution
3. Submit a pull request with clear description

## License

This script is provided as-is for use with Azure VMs. Use at your own risk.

## Disclaimer

**⚠️ WARNING: This script will DESTROY ALL DATA on the OS disk. Always backup important data and test in a non-production environment first.**

The author is not responsible for data loss, system failures, or any other issues arising from the use of this script.

## Support

For issues specific to this script:
- Check `/reinstall.log` for detailed error messages
- Review the troubleshooting section above
- Check Azure Serial Console if SSH is lost

For OS-specific issues after reimaging:
- Consult the official documentation for the installed OS
- Check cloud-init logs: `/var/log/cloud-init.log`
- Check waagent logs: `/var/log/waagent.log`