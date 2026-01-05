# Odroid C5 LUKS2 "Hammer" Encryption Script

A "One-Shot" automated script to convert a running Odroid C5 (Ubuntu 24.04 LTS) into a fully encrypted LUKS2 system with UART unlock support.

This script solves the specific bootloader issues on the Odroid C5 (U-Boot compression errors, pathing issues) by generating a custom uncompressed boot sequence.

## ⚠️ Requirements
* **Hardware:** Odroid C5 (Amlogic S905X5M)
* **OS:** Hardkernel Ubuntu 24.04 LTS (Minimal or Desktop)
* **Access:** UART Console (Required for unlocking) or USB Keyboard (if driver supported)
* **PC Tools:** A computer with GParted (Linux) or similar partition manager.

## 🚀 Installation Guide

### Step 1: Initial Setup
1.  Flash the **Ubuntu 24.04 LTS** image to your MicroSD card.
2.  Insert into Odroid C5 and boot.
3.  Log in and initialize the system time and packages:
    ```bash
    sudo timedatectl set-ntp true
    # Wait 10 seconds for sync
    sudo apt update
    sudo apt upgrade -y
    ```
4.  Create a mount point for transferring the script later:
    ```bash
    sudo mkdir /mnt/flash
    sync
    sudo poweroff
    ```

### Step 2: Resize Partition (On PC)
1.  Remove the MicroSD card from the Odroid and insert it into your PC.
2.  Open **GParted** (or your preferred partition tool).
3.  Locate the main root partition (usually Partition 2).
4.  **Shrink** the partition to **16384 MB (16GB)**.
5.  Leave the remaining space on the card as **Unallocated**.
6.  Eject safely.

### Step 3: Run the Hammer Script
1.  Insert the MicroSD card back into the Odroid C5.
2.  Plug a USB flash drive containing `hammer.sh` into the Odroid.
3.  Mount the USB drive:
    ```bash
    # Adjust /dev/sda1 if your USB drive differs
    sudo mount /dev/sda1 /mnt/flash
    ```
4.  Copy the script to your home folder and run it:
    ```bash
    cp /mnt/flash/hammer.sh ~/
    chmod +x ~/hammer.sh
    sudo ./hammer.sh
    ```
5.  Follow the prompts to create your LUKS passphrase.
6.  **Reboot.**

### Step 4: Unlock
On the UART console, you will see a passphrase prompt. Enter your password to unlock and boot the system.

---

## 🔧 Technical Details

This script performs a "Side-Load" encryption process to bypass the Odroid's read-only boot limitations.

1.  **Partitioning:** Detects the end of the existing RootFS (Partition 2) and creates a new Partition 3 filling the remaining empty space.
2.  **Encryption:** Formats Partition 3 with `LUKS2` (cipher: aes-xts-plain64) and creates an `ext4` filesystem.
3.  **Cloning:** Uses `rsync` to clone the live running OS from Partition 2 to the new encrypted Partition 3, excluding dynamic directories (`/proc`, `/sys`, etc.).
4.  **Bootloader Bypass (The "Hammer" Fix):**
    * **Disables `boot.ini`:** Renames the legacy Hardkernel boot file to force U-Boot to look for a standard `boot.scr`.
    * **Disables `flash-kernel`:** Prevents apt updates from overwriting the custom boot configuration.
    * **Custom `boot.cmd`:** Generates a U-Boot script that:
        * Loads the Kernel, Initramfs, and DTB to specific memory addresses (`0x01080000`, etc.).
        * **Bypasses Decompression:** Loads the uncompressed kernel directly to execution memory to avoid U-Boot gzip errors.
        * **Sets UART Addresses:** Forces `earlycon=aml_uart,0xfe07a000` to ensure the password prompt appears on the serial console.
5.  **Initramfs Pruning:** Strips out unstable or experimental USB drivers, prioritizing a stable UART-based unlock environment.

##Forking for Other Boards
To adapt this for Odroid C4, N2+, or M1, you must modify the following variables in the `Generate Boot Script` section:
* **DTB Path:** Change `s7d_s905x5m_odroidc5.dtb` to your board's specific Device Tree.
* **UART Address:** Update `0xfe07a000` to your SoC's UART base address (e.g., S905X3 uses `0xff803000`).

##Goals
[ ] port to odroid-c4
[ ] port to c2
[ ] port to c1+ *low priority
[ ] port m2 *gotta check compatibility
[ ] reclaim original partition
[ ] stress test parition resize minimum
