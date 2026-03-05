#!/bin/bash
#
# ==========================================================
#  KVM Ubuntu 22.04 Automated VM Creation Script
# ==========================================================
#
#  FEATURES:
#   - Installs KVM/libvirt on host
#   - Creates bridge br0 (if not exists)
#   - Creates VM disk (qcow2)
#   - Boots Ubuntu 22.04 Desktop ISO for interactive GUI install
#   - Adds 2 NICs:
#         1x NAT (default)
#         1x Bridged (br0)
#   - Auto USB passthrough (VID:PID based)
#         2x Kvaser 0bfd:0108
#         1x DDC    1212:2323
#   - Blacklists host drivers for passthrough USB devices
#
#  REQUIREMENTS:
#   - Ubuntu/Debian or AlmaLinux/RHEL/Fedora host
#   - VT-x / AMD-V enabled in BIOS
#   - Ubuntu 22.04 Desktop ISO placed in the same directory
#     as this script (ubuntu-22.04*desktop*amd64.iso)
#
# ==========================================================

set -euo pipefail

# ==========================================================
# Logging
# ==========================================================

LOG_FILE="$HOME/kvm-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*"; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*"; echo "See full log: $LOG_FILE"; exit 1; }

log "Script started. Log file: $LOG_FILE"

# ==========================================================
# Network connectivity wait helper
# ==========================================================

wait_for_network() {
    log "== Waiting for network connectivity =="
    local TRIES=30
    local WAIT=2
    for (( i=1; i<=TRIES; i++ )); do
        if curl -s --max-time 3 https://releases.ubuntu.com > /dev/null 2>&1; then
            log "Network is up."
            return 0
        fi
        log "Network not ready yet — attempt $i/$TRIES, retrying in ${WAIT}s..."
        sleep "$WAIT"
    done
    die "Network did not become available after $(( TRIES * WAIT ))s. Check bridge/DNS config."
}

# ==========================================================
# Configuration
# ==========================================================

VM_NAME="UbuntuTSS"
RAM_MB=16384
VCPUS=6
DISK_GB=100
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

UBUNTU_ISO_NAME="ubuntu-22.04.5-desktop-amd64.iso"
UBUNTU_ISO_URL="https://releases.ubuntu.com/22.04/$UBUNTU_ISO_NAME"
UBUNTU_ISO="$SCRIPT_DIR/$UBUNTU_ISO_NAME"

NEED_REBOOT=0

# ==========================================================
# USB passthrough devices:
#   "NAME VENDOR_ID PRODUCT_ID COUNT KERNEL_MODULE"
#
# KERNEL_MODULE: driver to blacklist on host so the guest
#   gets exclusive access to the device.
#   Use "-" if no blacklisting is needed for that device.
#
# WARNING: Devices sharing the same VID:PID cannot be
#   distinguished by libvirt when COUNT > 1. For multiple
#   identical devices use bus/device address instead:
#
#     <address bus='1' device='3'/>
#
#   Run 'lsusb' to find unique bus/device numbers per port.
# ==========================================================

USB_DEVICES=(
    "Kvaser   0x0bfd 0x0108 2 kvaser_usb"
    "DDC      0x1212 0x2323 1 ddc"
)

# ==========================================================
# Help
# ==========================================================

if [[ "${1:-}" == "--help" ]]; then
    head -45 "$0"
    exit 0
fi

# ==========================================================
# Detect host package manager
# ==========================================================

if command -v apt-get &>/dev/null; then
    PM="apt"
elif command -v dnf &>/dev/null; then
    PM="dnf"
elif command -v yum &>/dev/null; then
    PM="yum"
else
    die "Unsupported host package manager."
fi

log "Detected package manager: $PM"

# ==========================================================
# Install host virtualization packages
# ==========================================================

log "== Installing host virtualization packages =="

if [[ "$PM" == "apt" ]]; then
    sudo apt-get update \
        || die "apt-get update failed."
    sudo apt-get install -y \
        qemu-kvm libvirt-daemon-system libvirt-clients \
        virt-install bridge-utils curl \
        || die "apt-get install of virtualization packages failed."
else
    sudo "$PM" install -y \
        qemu-kvm libvirt virt-install bridge-utils curl NetworkManager \
        || die "dnf/yum install of base virtualization packages failed."
fi

sudo systemctl enable --now libvirtd || die "Failed to enable/start libvirtd."

# ==========================================================
# Blacklist host drivers for all passthrough USB devices
# ==========================================================

log "== Blacklisting host drivers for USB passthrough devices =="

for entry in "${USB_DEVICES[@]}"; do
    read -r DEV_NAME VENDOR_ID PRODUCT_ID COUNT KMOD <<< "$entry"

    [[ "$KMOD" == "-" ]] && continue

    BLACKLIST_FILE="/etc/modprobe.d/blacklist-${KMOD}.conf"

    if ! grep -q "blacklist $KMOD" "$BLACKLIST_FILE" 2>/dev/null; then
        log "Blacklisting $KMOD for $DEV_NAME ($VENDOR_ID:$PRODUCT_ID)"
        echo "blacklist $KMOD" | sudo tee "$BLACKLIST_FILE" > /dev/null \
            || die "Failed to write $BLACKLIST_FILE."
        NEED_REBOOT=1
    else
        log "$KMOD already blacklisted for $DEV_NAME."
    fi

    sudo modprobe -r "$KMOD" 2>/dev/null \
        && log "$KMOD module unloaded." \
        || log "$KMOD module not loaded (ok)."
done

# ==========================================================
# Auto-detect first physical network interface
# (skip lo, virtual, bridge, tunnel interfaces)
# ==========================================================

PHYS_IFACE=$(ip -o link show \
    | awk '$2 !~ /^(lo|vir|vnet|docker|br|bond|dummy|tun|tap)/ {print $2}' \
    | head -1 \
    | tr -d ':')

if [[ -z "$PHYS_IFACE" ]]; then
    die "Could not auto-detect physical network interface. Set PHYS_IFACE manually in the script."
fi

log "== Detected physical interface: $PHYS_IFACE =="

# ==========================================================
# Create bridge br0 if not exists
# ==========================================================

if ! ip link show br0 &>/dev/null; then
    log "== Creating bridge br0 on host =="

    echo ""
    warn "Network reconfiguration will move $PHYS_IFACE into bridge br0."
    warn "If you are connected over this interface, your SSH session WILL DROP."
    warn "Reconnect via br0 after reboot."
    echo ""
    read -r -p "Continue? [y/N] " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        log "Aborted by user."
        exit 1
    fi

    if [[ "$PM" == "apt" ]]; then
        # Ubuntu/Debian — use netplan
        sudo mkdir -p /etc/netplan
        sudo bash -c "cat > /etc/netplan/99-br0.yaml" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $PHYS_IFACE:
      dhcp4: no
  bridges:
    br0:
      interfaces: [$PHYS_IFACE]
      dhcp4: yes
EOF
        sudo netplan apply || die "netplan apply failed."

    else
        # AlmaLinux/RHEL/Fedora — use NetworkManager (nmcli)
        sudo nmcli connection add \
            type bridge \
            ifname br0 \
            con-name br0 \
            bridge.stp no \
            ipv4.method auto \
            || die "nmcli: failed to create bridge br0."

        sudo nmcli connection add \
            type ethernet \
            ifname "$PHYS_IFACE" \
            con-name "br0-slave-$PHYS_IFACE" \
            master br0 \
            || die "nmcli: failed to add $PHYS_IFACE as bridge slave."

        # Bring down the existing connection on the physical iface
        # so NetworkManager hands it over to the bridge cleanly.
        EXISTING_CON=$(nmcli -g NAME connection show --active \
            | grep -v "^br0" | head -1 || true)
        if [[ -n "$EXISTING_CON" ]]; then
            sudo nmcli connection down "$EXISTING_CON" || true
        fi

        sudo nmcli connection up br0 \
            || die "nmcli: failed to bring up br0."
    fi

    NEED_REBOOT=1
else
    log "Bridge br0 already exists — skipping."
fi

# ==========================================================
# Locate or download Ubuntu 22.04 Desktop ISO
# ==========================================================

# First check if any matching ISO already exists in script dir
EXISTING_ISO=$(find "$SCRIPT_DIR" -maxdepth 1 -iname "ubuntu-22.04*desktop*amd64.iso" | head -1)

if [[ -n "$EXISTING_ISO" ]]; then
    UBUNTU_ISO="$EXISTING_ISO"
    log "Found existing Ubuntu Desktop ISO: $UBUNTU_ISO"
else
    log "Ubuntu Desktop ISO not found locally — downloading..."
    wait_for_network
    curl -C - -o "$UBUNTU_ISO" "$UBUNTU_ISO_URL" \
        || die "Failed to download Ubuntu Desktop ISO from $UBUNTU_ISO_URL."
    log "Download complete: $UBUNTU_ISO"
fi

# ==========================================================
# Idempotency: skip disk/VM creation if VM already exists
# ==========================================================

if virsh dominfo "$VM_NAME" &>/dev/null; then
    warn "VM '$VM_NAME' already exists — skipping creation."
else

    log "== Creating VM disk =="
    qemu-img create -f qcow2 \
        "$SCRIPT_DIR/${VM_NAME}.qcow2" "${DISK_GB}G" \
        || die "qemu-img disk creation failed."

    # ==========================================================
    # Create VM — boot from Desktop ISO for interactive install.
    # Connect via SPICE to complete the Ubuntu GUI installer.
    # --noautoconsole lets the script continue to USB attachment
    # while the installer runs in the background.
    # ==========================================================

    log "== Creating VM and booting Ubuntu Desktop installer =="

    virt-install \
        --name "$VM_NAME" \
        --ram "$RAM_MB" \
        --vcpus "$VCPUS" \
        --cpu host-passthrough \
        --machine q35 \
        --disk path="$SCRIPT_DIR/${VM_NAME}.qcow2",format=qcow2,bus=virtio,size="$DISK_GB" \
        --cdrom "$UBUNTU_ISO" \
        --network network=default,model=virtio \
        --network bridge=br0,model=virtio \
        --graphics spice,listen=0.0.0.0 \
        --video qxl \
        --boot cdrom,hd \
        --noautoconsole \
        || die "virt-install failed."

    log "VM created. Connect via SPICE to complete the Ubuntu installation."
    log "Use: virt-viewer $VM_NAME  OR  remote-viewer spice://<host-ip>:5900"

fi  # end idempotency block

# ==========================================================
# USB Passthrough — generic loop over USB_DEVICES array
# ==========================================================

log "== Adding USB passthrough definitions =="

for entry in "${USB_DEVICES[@]}"; do
    read -r DEV_NAME VENDOR_ID PRODUCT_ID COUNT KMOD <<< "$entry"

    for (( i=1; i<=COUNT; i++ )); do
        XML_FILE="$SCRIPT_DIR/usb_${DEV_NAME}_${i}.xml"

        cat > "$XML_FILE" <<EOF
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='$VENDOR_ID'/>
    <product id='$PRODUCT_ID'/>
  </source>
</hostdev>
EOF

        log "Attaching USB device: $DEV_NAME ($VENDOR_ID:$PRODUCT_ID) instance $i/$COUNT"
        virsh attach-device "$VM_NAME" "$XML_FILE" --config \
            && log "$DEV_NAME instance $i attached successfully." \
            || warn "$DEV_NAME instance $i failed to attach — device may not be connected."
        rm -f "$XML_FILE"
    done
done

# ==========================================================
# Final Info
# ==========================================================

echo ""
echo "================================================="
echo "VM setup complete."
echo ""
echo "Ubuntu Desktop installer is running in the VM."
echo "Connect via SPICE to complete the installation:"
echo "  virt-viewer $VM_NAME"
echo "  -- or --"
echo "  remote-viewer spice://<host-ip>:5900"
echo ""
echo "Networks configured:"
echo "  - NAT (default)"
echo "  - Bridged (br0 via $PHYS_IFACE)"
echo ""
echo "USB auto-attach configured:"
for entry in "${USB_DEVICES[@]}"; do
    read -r DEV_NAME VENDOR_ID PRODUCT_ID COUNT KMOD <<< "$entry"
    echo "  - ${COUNT}x ${DEV_NAME} (${VENDOR_ID}:${PRODUCT_ID})"
done
echo ""
echo "Host drivers blacklisted:"
for entry in "${USB_DEVICES[@]}"; do
    read -r DEV_NAME VENDOR_ID PRODUCT_ID COUNT KMOD <<< "$entry"
    if [[ "$KMOD" != "-" ]]; then
        echo "  - $KMOD  ($DEV_NAME)"
    fi
done
echo ""
echo "After installation is complete, find VM IP with:"
echo "  virsh domifaddr $VM_NAME"
echo ""
echo "Full setup log saved to:"
echo "  $LOG_FILE"
echo ""

if [[ "$NEED_REBOOT" == "1" ]]; then
    echo "IMPORTANT:"
    echo "Host reboot is required for:"
    echo "  - Bridge activation (if newly created)"
    echo "  - Driver blacklists to fully apply"
    echo ""
    echo "Please reboot the host before connecting USB devices."
fi

echo "================================================="
