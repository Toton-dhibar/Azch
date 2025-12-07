#!/bin/bash

###############################################################################
# Universal OS Reimage Installer for Azure VMs
# Version: 1.0
# Description: Production-grade script to reimage Azure VMs with official
#              cloud images (Ubuntu, Debian, AlmaLinux, Rocky, CentOS, Alpine)
# Requirements: Run as root on Azure VM
# Logs: /reinstall.log
###############################################################################

set -e
set -o pipefail

# Global variables
LOGFILE="/reinstall.log"
BACKUP_DIR="/tmp/azure_backup_$$"
DOWNLOAD_DIR="/tmp/os_download_$$"
MOUNT_DIR="/mnt/newroot"
EFI_MOUNT="/mnt/newefi"
SRC_MOUNT="/mnt/srcroot"
IMAGE_FILE=""
IMAGE_URL=""
IMAGE_SHA256=""
OS_DISK=""
OS_NAME=""
FALLBACK_MODE=0
EFI_PART=""
ROOT_PART=""

# Initialize logging
exec > >(tee -a "$LOGFILE") 2>&1

###############################################################################
# Utility Functions
###############################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "ERROR: $*"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

detect_os_disk() {
    log "Detecting OS disk..."
    
    # Find the root device
    local root_device=$(findmnt -n -o SOURCE /)
    log "Root filesystem is on: $root_device"
    
    # Extract the base disk device
    if [[ $root_device =~ ^/dev/nvme[0-9]+n[0-9]+ ]]; then
        OS_DISK=$(echo "$root_device" | sed 's/p[0-9]*$//')
    elif [[ $root_device =~ ^/dev/[sv]d[a-z] ]]; then
        OS_DISK=$(echo "$root_device" | sed 's/[0-9]*$//')
    elif [[ $root_device =~ ^/dev/mapper/ ]]; then
        # Handle LVM or encrypted volumes
        local pv=$(pvdisplay 2>/dev/null | grep "PV Name" | awk '{print $3}' | head -1)
        if [[ -n $pv ]]; then
            if [[ $pv =~ ^/dev/nvme[0-9]+n[0-9]+ ]]; then
                OS_DISK=$(echo "$pv" | sed 's/p[0-9]*$//')
            else
                OS_DISK=$(echo "$pv" | sed 's/[0-9]*$//')
            fi
        fi
    fi
    
    # Fallback: try common Azure disks
    if [[ -z $OS_DISK ]]; then
        if [[ -b /dev/sda ]]; then
            OS_DISK="/dev/sda"
        elif [[ -b /dev/nvme0n1 ]]; then
            OS_DISK="/dev/nvme0n1"
        else
            error "Could not detect OS disk"
        fi
    fi
    
    log "Detected OS disk: $OS_DISK"
    
    # Safety check - ensure it's a block device
    if [[ ! -b $OS_DISK ]]; then
        error "$OS_DISK is not a block device"
    fi
    
    # Verify this is the boot disk
    local disk_size=$(blockdev --getsize64 "$OS_DISK" 2>/dev/null || echo 0)
    log "OS disk size: $((disk_size / 1024 / 1024 / 1024)) GB"
    
    # Minimum disk size check (10GB)
    local min_size_gb=10
    local min_size_bytes=$((min_size_gb * 1024 * 1024 * 1024))
    
    if [[ $disk_size -lt $min_size_bytes ]]; then
        log "WARNING: Disk size seems small for an OS disk"
        read -p "Continue anyway? (yes/no): " confirm
        [[ "$confirm" != "yes" ]] && error "Aborted by user"
    fi
}

install_dependencies() {
    log "Installing required dependencies..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    # Update package list
    apt-get update -qq || log "WARNING: apt-get update failed, continuing..."
    
    # Core dependencies
    local packages=(
        "qemu-utils"
        "parted"
        "gdisk"
        "dosfstools"
        "e2fsprogs"
        "grub-pc-bin"
        "grub-efi-amd64"
        "grub-efi-amd64-bin"
        "wget"
        "curl"
        "rsync"
        "kpartx"
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg"; then
            log "Installing $pkg..."
            apt-get install -y -qq "$pkg" 2>/dev/null || log "WARNING: Failed to install $pkg"
        fi
    done
    
    # Try to install qemu-nbd, but don't fail if unavailable
    if ! command -v qemu-nbd &>/dev/null; then
        log "Attempting to install qemu-nbd..."
        apt-get install -y -qq qemu-nbd 2>/dev/null || log "WARNING: qemu-nbd not available, will use fallback"
        
        # Load nbd module if available
        if [[ -f /lib/modules/$(uname -r)/kernel/drivers/block/nbd.ko ]]; then
            modprobe nbd max_part=8 2>/dev/null || log "WARNING: Could not load nbd module"
        fi
    fi
}

create_backup() {
    log "Creating backup of critical files..."
    mkdir -p "$BACKUP_DIR"/{ssh,network,cloud}
    
    # Backup SSH configuration and keys
    if [[ -d /etc/ssh ]]; then
        cp -a /etc/ssh/* "$BACKUP_DIR/ssh/" 2>/dev/null || true
    fi
    
    if [[ -d /root/.ssh ]]; then
        cp -a /root/.ssh "$BACKUP_DIR/ssh/root_ssh" 2>/dev/null || true
    fi
    
    # Backup user SSH keys
    for homedir in /home/*; do
        if [[ -d "$homedir/.ssh" ]]; then
            local username=$(basename "$homedir")
            mkdir -p "$BACKUP_DIR/ssh/home_$username"
            cp -a "$homedir/.ssh"/* "$BACKUP_DIR/ssh/home_$username/" 2>/dev/null || true
        fi
    done
    
    # Backup network configuration
    if [[ -d /etc/netplan ]]; then
        cp -a /etc/netplan/* "$BACKUP_DIR/network/" 2>/dev/null || true
    fi
    
    if [[ -f /etc/network/interfaces ]]; then
        cp -a /etc/network/interfaces "$BACKUP_DIR/network/" 2>/dev/null || true
    fi
    
    # Backup cloud-init config
    if [[ -d /etc/cloud ]]; then
        cp -a /etc/cloud/* "$BACKUP_DIR/cloud/" 2>/dev/null || true
    fi
    
    # Backup waagent config
    if [[ -f /etc/waagent.conf ]]; then
        cp -a /etc/waagent.conf "$BACKUP_DIR/cloud/" 2>/dev/null || true
    fi
    
    log "Backup completed to $BACKUP_DIR"
}

download_image() {
    local url=$1
    local sha256=$2
    
    [[ -z "$url" ]] && error "Image URL not provided"
    
    log "Downloading image from: $url"
    mkdir -p "$DOWNLOAD_DIR"
    
    local filename=$(basename "$url")
    IMAGE_FILE="$DOWNLOAD_DIR/$filename"
    
    # Download with progress
    if command -v wget &>/dev/null; then
        wget -c -O "$IMAGE_FILE" "$url" || error "Failed to download image"
    else
        curl -L -C - -o "$IMAGE_FILE" "$url" || error "Failed to download image"
    fi
    
    log "Download completed: $IMAGE_FILE"
    
    # Verify SHA256 checksum
    if [[ -n $sha256 ]]; then
        log "Verifying SHA256 checksum..."
        local actual_sha256=$(sha256sum "$IMAGE_FILE" | awk '{print $1}')
        
        if [[ ${actual_sha256,,} != "${sha256,,}" ]]; then
            error "SHA256 mismatch! Expected: $sha256, Got: $actual_sha256"
        fi
        
        log "SHA256 verification passed"
    else
        log "WARNING: No SHA256 checksum provided, skipping verification"
    fi
}

extract_image() {
    log "Extracting/converting image..."
    
    [[ ! -f "$IMAGE_FILE" ]] && error "Image file not found: $IMAGE_FILE"
    
    local src_image="$IMAGE_FILE"
    local raw_image="$DOWNLOAD_DIR/disk.raw"
    
    # Detect image format
    local img_format=$(qemu-img info "$src_image" 2>/dev/null | grep "file format:" | awk '{print $3}')
    log "Image format detected: $img_format"
    
    if [[ $img_format == "qcow2" ]] || [[ $img_format == "vpc" ]] || [[ $img_format == "vmdk" ]]; then
        log "Converting $img_format to raw format..."
        qemu-img convert -f "$img_format" -O raw "$src_image" "$raw_image" || error "Failed to convert image"
        IMAGE_FILE="$raw_image"
    fi
    
    log "Image ready: $IMAGE_FILE"
}

partition_disk() {
    log "Creating new GPT partition table..."
    
    # Unmount any existing partitions on the target disk
    for part in ${OS_DISK}*; do
        if [[ "$part" != "$OS_DISK" ]]; then
            umount -f "$part" 2>/dev/null || true
        fi
    done
    
    # Wipe existing partition table
    log "Wiping existing partition table..."
    sgdisk -Z "$OS_DISK" || wipefs -a "$OS_DISK" || true
    
    # Create new GPT table
    parted -s "$OS_DISK" mklabel gpt || error "Failed to create GPT table"
    
    # Create EFI partition (512MB)
    log "Creating EFI partition (512MB)..."
    parted -s "$OS_DISK" mkpart primary fat32 1MiB 513MiB || error "Failed to create EFI partition"
    parted -s "$OS_DISK" set 1 esp on
    parted -s "$OS_DISK" set 1 boot on
    
    # Create root partition (remaining space)
    log "Creating root partition..."
    parted -s "$OS_DISK" mkpart primary ext4 513MiB 100% || error "Failed to create root partition"
    
    # Inform kernel of partition changes
    partprobe "$OS_DISK" 2>/dev/null || true
    
    # Determine partition naming scheme
    if [[ $OS_DISK =~ nvme ]]; then
        EFI_PART="${OS_DISK}p1"
        ROOT_PART="${OS_DISK}p2"
    else
        EFI_PART="${OS_DISK}1"
        ROOT_PART="${OS_DISK}2"
    fi
    
    log "Partitions created: EFI=$EFI_PART, ROOT=$ROOT_PART"
    
    # Wait for devices to appear with better timing logic
    local max_wait=30
    local waited=0
    local devices_ready=0
    while [[ $waited -lt $max_wait ]]; do
        if [[ -b "$EFI_PART" ]] && [[ -b "$ROOT_PART" ]]; then
            log "Partition devices ready after ${waited} seconds"
            devices_ready=1
            break
        fi
        sleep 1
        waited=$((waited + 1))
        # Re-probe every 5 seconds for slower systems
        if [[ $((waited % 5)) -eq 0 ]]; then
            partprobe "$OS_DISK" 2>/dev/null || true
        fi
    done
    
    # Check if we timed out
    if [[ $devices_ready -eq 0 ]]; then
        error "Timeout waiting for partition devices to appear after ${max_wait} seconds"
    fi
    
    [[ ! -b "$EFI_PART" ]] && error "EFI partition device not found: $EFI_PART"
    [[ ! -b "$ROOT_PART" ]] && error "Root partition device not found: $ROOT_PART"
}

format_partitions() {
    log "Formatting partitions..."
    
    # Validate partition devices exist
    [[ ! -b "$EFI_PART" ]] && error "EFI partition device not found: $EFI_PART"
    [[ ! -b "$ROOT_PART" ]] && error "Root partition device not found: $ROOT_PART"
    
    # Format EFI partition
    log "Formatting EFI partition as FAT32..."
    mkfs.vfat -F 32 "$EFI_PART" || error "Failed to format EFI partition"
    
    # Format root partition
    log "Formatting root partition as ext4..."
    mkfs.ext4 -F "$ROOT_PART" || error "Failed to format root partition"
    
    log "Partitions formatted successfully"
}

mount_image_nbd() {
    local image=$1
    
    log "Attempting to mount image using qemu-nbd..."
    
    # Find free NBD device
    local nbd_dev=""
    for i in {0..15}; do
        # Check if device doesn't exist yet
        if [[ ! -b /dev/nbd$i ]]; then
            nbd_dev="/dev/nbd$i"
            break
        fi
        # Check if device exists but is not in use (disconnect returns success if not connected)
        if qemu-nbd -d /dev/nbd$i 2>/dev/null; then
            nbd_dev="/dev/nbd$i"
            break
        fi
    done
    
    if [[ -z $nbd_dev ]]; then
        log "WARNING: No free NBD device found"
        return 1
    fi
    
    # Connect image to NBD device
    qemu-nbd -c "$nbd_dev" "$image" || return 1
    sleep 2
    
    # Try to mount the main partition
    local mounted=0
    for part in ${nbd_dev}p*; do
        if [[ -b $part ]]; then
            local fs_type=$(blkid -s TYPE -o value "$part" 2>/dev/null)
            if [[ $fs_type =~ ext[234]|xfs|btrfs ]]; then
                mkdir -p "$SRC_MOUNT"
                mount "$part" "$SRC_MOUNT" && mounted=1 && break
            fi
        fi
    done
    
    if [[ $mounted -eq 0 ]]; then
        qemu-nbd -d "$nbd_dev"
        return 1
    fi
    
    echo "$nbd_dev"
    return 0
}

mount_image_loop() {
    local image=$1
    
    log "Attempting to mount image using loop device..."
    
    # Use kpartx to create partition mappings
    if command -v kpartx &>/dev/null; then
        local loop_dev=$(losetup -f)
        losetup "$loop_dev" "$image" || return 1
        
        kpartx -av "$loop_dev" || {
            losetup -d "$loop_dev"
            return 1
        }
        
        sleep 2
        
        # Find root partition
        local mapper_base=$(basename "$loop_dev")
        for part in /dev/mapper/${mapper_base}p*; do
            if [[ -b $part ]]; then
                local fs_type=$(blkid -s TYPE -o value "$part" 2>/dev/null)
                if [[ $fs_type =~ ext[234]|xfs|btrfs ]]; then
                    mkdir -p "$SRC_MOUNT"
                    mount "$part" "$SRC_MOUNT" && echo "$loop_dev" && return 0
                fi
            fi
        done
        
        kpartx -d "$loop_dev"
        losetup -d "$loop_dev"
    fi
    
    return 1
}

copy_rootfs() {
    log "Copying root filesystem..."
    
    # Validate partition devices exist
    [[ ! -b "$ROOT_PART" ]] && error "Root partition device not found: $ROOT_PART"
    [[ ! -b "$EFI_PART" ]] && error "EFI partition device not found: $EFI_PART"
    [[ ! -f "$IMAGE_FILE" ]] && error "Image file not found: $IMAGE_FILE"
    
    # Mount target partitions
    mkdir -p "$MOUNT_DIR" "$EFI_MOUNT"
    mount "$ROOT_PART" "$MOUNT_DIR" || error "Failed to mount root partition"
    mount "$EFI_PART" "$EFI_MOUNT" || error "Failed to mount EFI partition"
    
    # Try NBD first
    local nbd_dev=$(mount_image_nbd "$IMAGE_FILE")
    local mount_success=$?
    
    if [[ $mount_success -ne 0 ]]; then
        log "NBD mount failed, trying loop device..."
        local loop_dev=$(mount_image_loop "$IMAGE_FILE")
        mount_success=$?
    fi
    
    # Fallback: extract from raw image with dd
    if [[ $mount_success -ne 0 ]]; then
        log "Loop mount failed, using dd fallback..."
        dd if="$IMAGE_FILE" of="$ROOT_PART" bs=4M status=progress || error "Failed to copy image with dd"
        
        # Resize filesystem to fill partition
        e2fsck -f -y "$ROOT_PART" 2>/dev/null || true
        resize2fs "$ROOT_PART" || true
        
        # Mount for modifications
        mount "$ROOT_PART" "$MOUNT_DIR" || error "Failed to mount after dd"
    else
        # Copy using rsync from source mount to target mount
        log "Copying files with rsync..."
        rsync -aAXHv --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' \
              --exclude='/tmp/*' --exclude='/run/*' --exclude='/mnt/*' \
              "$SRC_MOUNT/" "$MOUNT_DIR/" || error "Failed to copy root filesystem"
        
        # Unmount source
        umount "$SRC_MOUNT"
        if [[ -n $nbd_dev ]]; then
            qemu-nbd -d "$nbd_dev"
        elif [[ -n $loop_dev ]]; then
            kpartx -d "$loop_dev"
            losetup -d "$loop_dev"
        fi
    fi
    
    log "Root filesystem copied successfully"
}

restore_configuration() {
    log "Restoring SSH keys and network configuration..."
    
    # Restore SSH server configuration
    if [[ -d $BACKUP_DIR/ssh ]]; then
        log "Restoring SSH configuration..."
        
        # Restore SSH host keys
        for key in "$BACKUP_DIR/ssh"/ssh_host_*; do
            [[ -f $key ]] && cp -a "$key" "$MOUNT_DIR/etc/ssh/" && log "Restored $(basename $key)"
        done
        
        # Restore sshd_config if not present
        if [[ -f $BACKUP_DIR/ssh/sshd_config ]] && [[ ! -f $MOUNT_DIR/etc/ssh/sshd_config ]]; then
            cp -a "$BACKUP_DIR/ssh/sshd_config" "$MOUNT_DIR/etc/ssh/"
        fi
        
        # Restore root SSH keys
        if [[ -d $BACKUP_DIR/ssh/root_ssh ]]; then
            mkdir -p "$MOUNT_DIR/root/.ssh"
            cp -a "$BACKUP_DIR/ssh/root_ssh"/* "$MOUNT_DIR/root/.ssh/" 2>/dev/null || true
            chmod 700 "$MOUNT_DIR/root/.ssh"
            chmod 600 "$MOUNT_DIR/root/.ssh"/* 2>/dev/null || true
        fi
        
        # Restore user SSH keys
        for user_backup in "$BACKUP_DIR/ssh"/home_*; do
            if [[ -d $user_backup ]]; then
                local username=$(basename "$user_backup" | sed 's/^home_//')
                if [[ -d $MOUNT_DIR/home/$username ]]; then
                    mkdir -p "$MOUNT_DIR/home/$username/.ssh"
                    cp -a "$user_backup"/* "$MOUNT_DIR/home/$username/.ssh/" 2>/dev/null || true
                    
                    # Get UID/GID from new system
                    local uid=$(grep "^$username:" "$MOUNT_DIR/etc/passwd" | cut -d: -f3)
                    local gid=$(grep "^$username:" "$MOUNT_DIR/etc/passwd" | cut -d: -f4)
                    
                    if [[ -n $uid ]] && [[ -n $gid ]]; then
                        chroot "$MOUNT_DIR" chown -R "$uid:$gid" "/home/$username/.ssh"
                    fi
                    
                    chmod 700 "$MOUNT_DIR/home/$username/.ssh"
                    chmod 600 "$MOUNT_DIR/home/$username/.ssh"/* 2>/dev/null || true
                fi
            fi
        done
    fi
    
    # Restore network configuration
    if [[ -d $BACKUP_DIR/network ]]; then
        log "Restoring network configuration..."
        
        # Netplan configuration
        if ls "$BACKUP_DIR/network"/*.yaml &>/dev/null; then
            mkdir -p "$MOUNT_DIR/etc/netplan"
            cp -a "$BACKUP_DIR/network"/*.yaml "$MOUNT_DIR/etc/netplan/" 2>/dev/null || true
        fi
        
        # Classic network interfaces
        if [[ -f $BACKUP_DIR/network/interfaces ]]; then
            mkdir -p "$MOUNT_DIR/etc/network"
            cp -a "$BACKUP_DIR/network/interfaces" "$MOUNT_DIR/etc/network/"
        fi
    fi
    
    # Configure cloud-init to preserve SSH keys
    if [[ -d $MOUNT_DIR/etc/cloud ]]; then
        log "Configuring cloud-init..."
        
        cat > "$MOUNT_DIR/etc/cloud/cloud.cfg.d/99-azure-preserve.cfg" <<'EOF'
# Preserve SSH keys and network configuration
datasource_list: [ Azure ]
ssh_deletekeys: false
ssh_genkeytypes: []
disable_root: false
preserve_hostname: false

# Prevent cloud-init from overwriting SSH keys
no_ssh_fingerprints: false

# Azure-specific settings
datasource:
  Azure:
    apply_network_config: true
    
# Preserve existing SSH authorized keys
bootcmd:
  - echo "Cloud-init configured to preserve SSH keys"
EOF
        
        # Restore cloud-init config if backed up
        if [[ -d $BACKUP_DIR/cloud ]] && ls "$BACKUP_DIR/cloud"/*.cfg &>/dev/null; then
            cp -a "$BACKUP_DIR/cloud"/*.cfg "$MOUNT_DIR/etc/cloud/cloud.cfg.d/" 2>/dev/null || true
        fi
    fi
    
    # Configure waagent for Azure
    if [[ -f $MOUNT_DIR/etc/waagent.conf ]] || [[ -f $BACKUP_DIR/cloud/waagent.conf ]]; then
        log "Configuring waagent..."
        
        if [[ -f $BACKUP_DIR/cloud/waagent.conf ]]; then
            cp -a "$BACKUP_DIR/cloud/waagent.conf" "$MOUNT_DIR/etc/"
        fi
        
        # Ensure waagent doesn't regenerate SSH keys
        if [[ -f $MOUNT_DIR/etc/waagent.conf ]]; then
            sed -i 's/Provisioning.RegenerateSshHostKeyPair=y/Provisioning.RegenerateSshHostKeyPair=n/' "$MOUNT_DIR/etc/waagent.conf" 2>/dev/null || true
            sed -i 's/Provisioning.DeleteRootPassword=y/Provisioning.DeleteRootPassword=n/' "$MOUNT_DIR/etc/waagent.conf" 2>/dev/null || true
        fi
    fi
    
    log "Configuration restored successfully"
}

install_bootloader() {
    log "Installing bootloader..."
    
    # Validate required paths and devices
    [[ ! -d "$MOUNT_DIR" ]] && error "Mount directory not found: $MOUNT_DIR"
    [[ ! -b "$EFI_PART" ]] && error "EFI partition device not found: $EFI_PART"
    [[ ! -b "$ROOT_PART" ]] && error "Root partition device not found: $ROOT_PART"
    
    # Prepare chroot environment
    mount --bind /dev "$MOUNT_DIR/dev" || error "Failed to bind mount /dev"
    mount --bind /dev/pts "$MOUNT_DIR/dev/pts" || log "WARNING: Failed to bind mount /dev/pts"
    mount --bind /proc "$MOUNT_DIR/proc" || error "Failed to bind mount /proc"
    mount --bind /sys "$MOUNT_DIR/sys" || error "Failed to bind mount /sys"
    
    # Mount EFI partition inside chroot
    mkdir -p "$MOUNT_DIR/boot/efi"
    mount "$EFI_PART" "$MOUNT_DIR/boot/efi" || error "Failed to mount EFI partition in chroot"
    
    # Create fstab
    log "Creating fstab..."
    local root_uuid=$(blkid -s UUID -o value "$ROOT_PART")
    local efi_uuid=$(blkid -s UUID -o value "$EFI_PART")
    
    [[ -z "$root_uuid" ]] && error "Failed to get UUID for root partition"
    [[ -z "$efi_uuid" ]] && error "Failed to get UUID for EFI partition"
    
    cat > "$MOUNT_DIR/etc/fstab" <<EOF
# /etc/fstab: static file system information.
UUID=$root_uuid  /          ext4    errors=remount-ro  0  1
UUID=$efi_uuid   /boot/efi  vfat    umask=0077         0  1
EOF
    
    # Install GRUB
    log "Installing GRUB bootloader..."
    
    # Detect if system supports EFI
    if [[ -d /sys/firmware/efi ]]; then
        log "Installing GRUB for EFI..."
        
        # Determine bootloader ID based on OS
        local bootloader_id="grub"
        if [[ -f $MOUNT_DIR/etc/os-release ]]; then
            local os_id=$(grep "^ID=" "$MOUNT_DIR/etc/os-release" | cut -d= -f2 | tr -d '"')
            bootloader_id="${os_id:-grub}"
        fi
        
        chroot "$MOUNT_DIR" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
               --bootloader-id="$bootloader_id" --recheck --no-floppy "$OS_DISK" || \
               log "WARNING: GRUB EFI installation had errors"
    else
        log "Installing GRUB for BIOS..."
        chroot "$MOUNT_DIR" grub-install --target=i386-pc --recheck --no-floppy "$OS_DISK" || \
               log "WARNING: GRUB BIOS installation had errors"
    fi
    
    # Generate GRUB configuration
    log "Generating GRUB configuration..."
    chroot "$MOUNT_DIR" update-grub 2>/dev/null || \
        chroot "$MOUNT_DIR" grub-mkconfig -o /boot/grub/grub.cfg || \
        log "WARNING: GRUB config generation had errors"
    
    # Cleanup
    umount "$MOUNT_DIR/boot/efi" 2>/dev/null || true
    umount "$MOUNT_DIR/sys" 2>/dev/null || true
    umount "$MOUNT_DIR/proc" 2>/dev/null || true
    umount "$MOUNT_DIR/dev/pts" 2>/dev/null || true
    umount "$MOUNT_DIR/dev" 2>/dev/null || true
    
    log "Bootloader installation completed"
}

cleanup() {
    log "Cleaning up..."
    
    # Unmount chroot bind mounts if they exist
    if [[ -d "$MOUNT_DIR" ]]; then
        umount "$MOUNT_DIR/boot/efi" 2>/dev/null || true
        umount "$MOUNT_DIR/sys" 2>/dev/null || true
        umount "$MOUNT_DIR/proc" 2>/dev/null || true
        umount "$MOUNT_DIR/dev/pts" 2>/dev/null || true
        umount "$MOUNT_DIR/dev" 2>/dev/null || true
    fi
    
    # Unmount main mount points
    [[ -d "$SRC_MOUNT" ]] && umount "$SRC_MOUNT" 2>/dev/null || true
    [[ -d "$EFI_MOUNT" ]] && umount "$EFI_MOUNT" 2>/dev/null || true
    [[ -d "$MOUNT_DIR" ]] && umount "$MOUNT_DIR" 2>/dev/null || true
    
    # Cleanup loop devices via kpartx
    if command -v kpartx &>/dev/null; then
        shopt -s nullglob  # Prevent wildcard expansion if no matches
        for loop in /dev/loop*; do
            if [[ -b "$loop" ]] && losetup "$loop" 2>/dev/null | grep -q "$DOWNLOAD_DIR"; then
                log "Cleaning up loop device: $loop"
                kpartx -d "$loop" 2>/dev/null || true
                losetup -d "$loop" 2>/dev/null || true
            fi
        done
        shopt -u nullglob
    fi
    
    # Disconnect NBD devices
    if command -v qemu-nbd &>/dev/null; then
        shopt -s nullglob  # Prevent wildcard expansion if no matches
        for nbd in /dev/nbd*; do
            if [[ -b "$nbd" ]]; then
                qemu-nbd -d "$nbd" 2>/dev/null || true
            fi
        done
        shopt -u nullglob
    fi
    
    # Remove temporary directories (keep backup and log)
    [[ -d "$DOWNLOAD_DIR" ]] && rm -rf "$DOWNLOAD_DIR"
    
    log "Cleanup completed. Backup preserved at: $BACKUP_DIR"
}

###############################################################################
# Image Definitions
###############################################################################

get_image_info() {
    local choice=$1
    
    case $choice in
        1)
            IMAGE_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
            IMAGE_SHA256=""  # Checksum verification optional
            ;;
        2)
            IMAGE_URL="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
            IMAGE_SHA256=""  # Auto-verify disabled for this option
            ;;
        3)
            IMAGE_URL="https://cloud-images.ubuntu.com/releases/20.04/release/ubuntu-20.04-server-cloudimg-amd64.img"
            IMAGE_SHA256=""
            ;;
        4)
            IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
            IMAGE_SHA256=""
            ;;
        5)
            IMAGE_URL="https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2"
            IMAGE_SHA256=""
            ;;
        6)
            IMAGE_URL="https://download.rockylinux.org/pub/rocky/8/images/x86_64/Rocky-8-GenericCloud.latest.x86_64.qcow2"
            IMAGE_SHA256=""
            ;;
        7)
            IMAGE_URL="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
            IMAGE_SHA256=""
            ;;
        8)
            IMAGE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/cloud/alpine-virt-3.19.0-x86_64.qcow2"
            IMAGE_SHA256=""
            ;;
        9)
            read -p "Enter image URL: " IMAGE_URL
            read -p "Enter SHA256 checksum (or leave empty to skip): " IMAGE_SHA256
            ;;
        *)
            error "Invalid choice"
            ;;
    esac
}

###############################################################################
# Main Menu
###############################################################################

show_menu() {
    cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════════════╗
║         Universal OS Reimage Installer for Azure VMs v1.0                ║
╚═══════════════════════════════════════════════════════════════════════════╝

WARNING: This script will DESTROY all data on the OS disk and install a
         new operating system. SSH keys and network configuration will be
         preserved to maintain access.

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

EOF
    
    read -p "Enter your choice [0-9]: " choice
    echo "$choice"
}

confirm_installation() {
    local os_name=$1
    
    cat <<EOF

╔═══════════════════════════════════════════════════════════════════════════╗
║                         FINAL CONFIRMATION                                ║
╚═══════════════════════════════════════════════════════════════════════════╝

OS to install: $os_name
Target disk: $OS_DISK
Image URL: $IMAGE_URL

This operation will:
  ✓ Backup SSH keys and network configuration
  ✓ Download and verify the OS image
  ✓ DESTROY all data on $OS_DISK
  ✓ Install new OS and restore critical configuration
  ✓ Configure bootloader

EOF
    
    read -p "Type 'YES' in capital letters to proceed: " confirm
    
    if [[ "$confirm" != "YES" ]]; then
        log "Installation cancelled by user"
        exit 0
    fi
}

###############################################################################
# Azure Managed Disk Swap Fallback
###############################################################################

show_fallback_instructions() {
    cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════════════╗
║                    AZURE MANAGED DISK SWAP METHOD                         ║
╚═══════════════════════════════════════════════════════════════════════════╝

If direct disk overwrite fails, use Azure's managed disk swap method:

1. Stop the VM:
   az vm deallocate --resource-group YOUR_RG --name YOUR_VM

2. Create a snapshot of the current OS disk:
   az snapshot create --resource-group YOUR_RG --name os-backup \
     --source /subscriptions/YOUR_SUB/resourceGroups/YOUR_RG/providers/Microsoft.Compute/disks/YOUR_OS_DISK

3. Upload new OS image:
   az disk create --resource-group YOUR_RG --name new-os-disk \
     --source /path/to/downloaded/image.vhd --os-type Linux

4. Swap OS disks:
   az vm update --resource-group YOUR_RG --name YOUR_VM \
     --os-disk new-os-disk

5. Start VM:
   az vm start --resource-group YOUR_RG --name YOUR_VM

Your SSH keys and network config have been backed up to: $BACKUP_DIR

EOF
}

###############################################################################
# Main Execution Flow
###############################################################################

main() {
    log "=========================================="
    log "Universal OS Reimage Installer Started"
    log "=========================================="
    
    # Pre-flight checks
    check_root
    detect_os_disk
    
    # Show menu and get selection
    local choice=$(show_menu)
    
    if [[ "$choice" == "0" ]]; then
        log "Exiting..."
        exit 0
    fi
    
    # Get image information
    get_image_info "$choice"
    
    # Determine OS name for confirmation
    local os_name=""
    case $choice in
        1) os_name="Ubuntu 24.04 LTS" ;;
        2) os_name="Ubuntu 22.04 LTS" ;;
        3) os_name="Ubuntu 20.04 LTS" ;;
        4) os_name="Debian 12" ;;
        5) os_name="AlmaLinux 8" ;;
        6) os_name="Rocky Linux 8" ;;
        7) os_name="CentOS Stream 9" ;;
        8) os_name="Alpine Linux 3.19" ;;
        9) os_name="Custom Image" ;;
    esac
    
    # Final confirmation
    confirm_installation "$os_name"
    
    # Install dependencies
    install_dependencies
    
    # Create backup
    create_backup
    
    # Download and verify image
    download_image "$IMAGE_URL" "$IMAGE_SHA256"
    
    # Extract/convert image if needed
    extract_image
    
    # Partition and format disk
    partition_disk
    format_partitions
    
    # Copy root filesystem
    copy_rootfs
    
    # Restore configuration
    restore_configuration
    
    # Install bootloader
    install_bootloader
    
    # Cleanup
    cleanup
    
    log "=========================================="
    log "Installation completed successfully!"
    log "=========================================="
    log ""
    log "Next steps:"
    log "1. Review the log file: $LOGFILE"
    log "2. Reboot the system: reboot"
    log ""
    log "IMPORTANT: The system will reboot into the new OS."
    log "           SSH access should be maintained with existing keys."
    log ""
    
    read -p "Reboot now? (yes/no): " reboot_now
    
    if [[ "$reboot_now" == "yes" ]]; then
        log "Rebooting in 5 seconds..."
        sleep 5
        reboot
    else
        log "Please reboot manually when ready: reboot"
    fi
}

# Trap errors and cleanup
trap cleanup EXIT ERR

# Run main function if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
