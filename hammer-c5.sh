#!/usr/bin/env bash
set -euo pipefail
# --- CONFIGURATION ---
CRYPT_NAME="cryptroot"
MNT_NEW="/mnt/newroot"
DISK="/dev/mmcblk1"
BOOT_PART="${DISK}p1"
NEW_PART="${DISK}p3"

die(){ echo "❌ ERROR: $*" >&2; exit 1; }
log(){ echo -e "\n✅ $*"; }

[[ $EUID -eq 0 ]] || die "Run as root"

# ------------------------------------------------------------------
# 1. PARTITIONING
# ------------------------------------------------------------------
log "Checking for free space..."
if [ -b "$NEW_PART" ]; then
    log "$NEW_PART exists. Re-using it."
else
    # Find end of P2
    P2_END=$(parted -m -s "$DISK" unit MiB print | grep "^2:" | cut -d: -f3)
    [ -z "$P2_END" ] && die "Could not find partition 2 end."
    
    log "Creating Partition 3 starting at $P2_END..."
    parted -a optimal -s "$DISK" -- mkpart primary ext4 "$P2_END" 100%
    partprobe "$DISK" || true
    udevadm settle
fi

# ------------------------------------------------------------------
# 2. ENCRYPT & FORMAT
# ------------------------------------------------------------------
log "Formatting $NEW_PART with LUKS2..."
if [ -e "/dev/mapper/$CRYPT_NAME" ]; then
    log "Mapper already exists. Skipping format."
else
    log "Enter passphrase for new encryption:"
    cryptsetup luksFormat --type luks2 --force-password "$NEW_PART"
    
    log "Opening volume..."
    cryptsetup open "$NEW_PART" "$CRYPT_NAME"
    mkfs.ext4 -F -L "ROOT_ENCRYPTED" "/dev/mapper/$CRYPT_NAME"
fi

# ------------------------------------------------------------------
# 3. CLONE SYSTEM
# ------------------------------------------------------------------
log "Cloning system..."
mkdir -p "$MNT_NEW"
mount "/dev/mapper/$CRYPT_NAME" "$MNT_NEW"

log "Syncing files..."
rsync -aAX / \
    --exclude={"/dev/*","/proc/*","/sys/*","/run/*","/tmp/*","/mnt/*","/media/*","/lost+found","/boot/*"} \
    "$MNT_NEW"

mkdir -p "$MNT_NEW"/{dev,proc,sys,run,tmp,mnt,media,boot}

# ------------------------------------------------------------------
# 4. CONFIGURE TARGET
# ------------------------------------------------------------------
log "Configuring UUIDs..."
LUKS_UUID="$(blkid -s UUID -o value "$NEW_PART")"
echo "$CRYPT_NAME UUID=$LUKS_UUID none luks,initramfs" > "$MNT_NEW/etc/crypttab"

cp /etc/fstab "$MNT_NEW/etc/fstab"
sed -i '/\s\/\s/d' "$MNT_NEW/etc/fstab"
echo "/dev/mapper/$CRYPT_NAME  /  ext4  errors=remount-ro  0  1" >> "$MNT_NEW/etc/fstab"

# ------------------------------------------------------------------
# 5. GENERATE BOOT SCRIPT (THE FIX)
# ------------------------------------------------------------------
# We do this OUTSIDE the chroot to avoid variable expansion issues.

# Mount boot to the new root so we can write to it
mount "$BOOT_PART" "$MNT_NEW/boot"

# Detect Kernel Version from the cloned files
# We look for the first vmlinuz file in the boot folder
K_FILE=$(ls "$MNT_NEW/boot"/vmlinuz-* | head -n 1)
K_VER=$(basename "$K_FILE" | sed 's/vmlinuz-//')
log "Detected Kernel Version: $K_VER"

log "Writing boot.cmd..."
# We use 'cat' with a quoted delimiter 'EOF' so bash does NOT touch the variables inside.
cat > "$MNT_NEW/boot/boot.cmd" <<EOF
# UNCOMPRESSED KERNEL SCRIPT (HAMMER V8)
# Generated for Kernel: $K_VER

# 1. Memory Addresses
setenv kernel_addr_r 0x01080000
setenv ramdisk_addr_r 0x30000000
setenv fdt_addr_r 0x01000000

# 2. Boot Arguments
setenv bootargs "root=/dev/mapper/$CRYPT_NAME rootwait rw console=tty1 console=ttyS0,921600 loglevel=8 earlycon=aml_uart,0xfe07a000 clk_ignore_unused fsck.mode=force fsck.repair=yes net.ifnames=0"

# 3. Load Files
echo "Loading DTB..."
load mmc 1:1 \${fdt_addr_r} dtbs/$K_VER/s7d_s905x5m_odroidc5.dtb

echo "Loading Kernel..."
load mmc 1:1 \${kernel_addr_r} vmlinuz-$K_VER

echo "Loading Initramfs..."
load mmc 1:1 \${ramdisk_addr_r} initrd.img-$K_VER

# 4. Launch
echo "Launching..."
booti \${kernel_addr_r} \${ramdisk_addr_r}:\${filesize} \${fdt_addr_r}
EOF

log "Compiling boot.scr..."
# We compile it right here, using the tools installed on the host (Step 2 installs them)
mkimage -C none -A arm -T script -d "$MNT_NEW/boot/boot.cmd" "$MNT_NEW/boot/boot.scr"

# Verify the file isn't empty
if grep -q "booti :" "$MNT_NEW/boot/boot.cmd"; then
    die "FATAL: Variable expansion failed in boot.cmd. Check the script."
fi

# ------------------------------------------------------------------
# 6. APPLY REMAINING FIXES (CHROOT)
# ------------------------------------------------------------------
for dir in /dev /dev/pts /proc /sys; do mount --bind "$dir" "$MNT_NEW$dir"; done

log "Entering Chroot for final cleanup..."
# We quote 'EOF' here to prevent any accidental expansion in the chroot block too
chroot "$MNT_NEW" /bin/bash <<'EOF'
set -e

# A. Disable flash-kernel
dpkg-divert --local --rename --add /usr/sbin/flash-kernel || true

# B. Disable boot.ini
if [ -f /boot/boot.ini ]; then mv /boot/boot.ini /boot/boot.ini.bak; fi

# C. Safe Modules (No USB Drivers)
cat > /etc/initramfs-tools/modules <<MODULES
regulator-fixed
regulator-gpio
usbhid
hid
hid-generic
evdev
MODULES

# D. Update Initramfs
update-initramfs -u

EOF

# ------------------------------------------------------------------
# 7. CLEANUP
# ------------------------------------------------------------------
umount -R "$MNT_NEW"
cryptsetup close "$CRYPT_NAME"

log "SUCCESS! Hammer V8 Complete."
log "Reboot and unlock via UART."
