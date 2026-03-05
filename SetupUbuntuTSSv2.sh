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

#export LIBVIRT_DEFAULT_URI="qemu:///system"
#vvirsh destroy UbuntuTSS 2>/dev/null || true
#virsh undefine UbuntuTSS --nvram 2>/dev/null || virsh undefine UbuntuTSS
#sudo rm -f /var/lib/libvirt/images/UbuntuTSS.qcow2
#rm -f ~/Workspace/Ai/seed.iso ~/Workspace/Ai/user-data ~/Workspace/Ai/meta-data

#export LIBVIRT_DEFAULT_URI="qemu:///system"
#virt-viewer UbuntuTSS

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

# Wait until SSH is reachable on the VM after autoinstall completes.
wait_for_ssh() {
    local IP="$1"
    log "== Waiting for SSH on $IP =="
    local TRIES=60
    local WAIT=10
    for (( i=1; i<=TRIES; i++ )); do
        if ssh -o StrictHostKeyChecking=no \
               -o ConnectTimeout=5 \
               -o BatchMode=yes \
               "$USERNAME@$IP" "echo ok" &>/dev/null; then
            log "SSH is up on $IP."
            return 0
        fi
        log "SSH not ready yet — attempt $i/$TRIES, retrying in ${WAIT}s..."
        sleep "$WAIT"
    done
    warn "SSH did not become available after $(( TRIES * WAIT ))s."
    warn "VM may still be installing. Try: ssh $USERNAME@$IP"
}

# Build seed ISO for autoinstall using genisoimage.
make_seed_iso() {
    local OUTPUT="$1" USERDATA="$2" METADATA="$3"
    if command -v cloud-localds &>/dev/null; then
        log "Creating seed ISO with cloud-localds."
        cloud-localds "$OUTPUT" "$USERDATA" "$METADATA" \
            || die "cloud-localds failed."
    elif command -v genisoimage &>/dev/null; then
        log "Creating seed ISO with genisoimage."
        genisoimage \
            -output "$OUTPUT" \
            -volid cidata \
            -joliet \
            -rock \
            "$USERDATA" "$METADATA" \
            || die "genisoimage failed."
    else
        die "Neither cloud-localds nor genisoimage found. Cannot create seed ISO."
    fi
}



# ==========================================================
# Configuration
# ==========================================================

VM_NAME="UbuntuTSS"
RAM_MB=16384
VCPUS=6
DISK_GB=100
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_STORAGE_DIR="/var/lib/libvirt/images"

# Desktop ISO is used with autoinstall for unattended setup.
# ubuntu-desktop is already included — no separate server ISO needed.
UBUNTU_ISO_NAME="ubuntu-22.04.5-desktop-amd64.iso"
UBUNTU_ISO_URL="https://releases.ubuntu.com/22.04/$UBUNTU_ISO_NAME"
UBUNTU_ISO="$SCRIPT_DIR/$UBUNTU_ISO_NAME"

USERNAME="rtems"
PASSWORD="rtems"

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
        virt-install virt-viewer bridge-utils curl genisoimage \
        || die "apt-get install of virtualization packages failed."
else
    sudo "$PM" install -y \
        qemu-kvm libvirt virt-install virt-viewer bridge-utils curl NetworkManager genisoimage \
        || die "dnf/yum install of base virtualization packages failed."
fi

sudo systemctl enable --now libvirtd || die "Failed to enable/start libvirtd."

# Use system session for all virsh/virt-install calls
export LIBVIRT_DEFAULT_URI="qemu:///system"

# ==========================================================
# Ensure current user is in libvirt and kvm groups
# ==========================================================

for GRP in libvirt kvm; do
    if ! groups "$USER" | grep -q "$GRP"; then
        log "Adding $USER to group $GRP"
        sudo usermod -aG "$GRP" "$USER" \
            || warn "Failed to add $USER to $GRP — may need manual fix."
        NEED_REBOOT=1
    fi
done

# ==========================================================
# Check KVM acceleration availability
# ==========================================================

if [[ ! -r /dev/kvm ]]; then
    warn "/dev/kvm not accessible. Checking if KVM modules are loaded..."
    if ! lsmod | grep -q kvm; then
        sudo modprobe kvm 2>/dev/null || true
        sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    fi
    if [[ ! -r /dev/kvm ]]; then
        die "/dev/kvm still not accessible after loading modules.
     Check that VT-x/AMD-V is enabled in BIOS, and that
     nested virtualization is enabled if running inside a VM."
    fi
fi

log "KVM acceleration is available."

# ==========================================================
# Ensure libvirt 'default' NAT network is defined and running
# ==========================================================

log "== Checking libvirt default network =="

if ! virsh net-info default &>/dev/null; then
    log "Default network not found — defining it."
    sudo virsh net-define /usr/share/libvirt/networks/default.xml \
        || die "Failed to define default network. Check if /usr/share/libvirt/networks/default.xml exists."
fi

NET_ACTIVE=$(virsh net-info default | awk '/^Active:/{print $2}')
NET_AUTOSTART=$(virsh net-info default | awk '/^Autostart:/{print $2}')

if [[ "$NET_ACTIVE" != "yes" ]]; then
    log "Starting default network."
    sudo virsh net-start default \
        || die "Failed to start default network."
else
    log "Default network already active."
fi

if [[ "$NET_AUTOSTART" != "yes" ]]; then
    log "Enabling default network autostart."
    sudo virsh net-autostart default \
        || warn "Failed to set default network autostart."
fi

log "Default network is active."

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

# Grant qemu user read+execute access up the directory tree to the ISO.
# This is needed when files live outside /var/lib/libvirt/images.
log "== Granting qemu user access to ISO location =="
TRAVERSE_DIR="$SCRIPT_DIR"
while [[ "$TRAVERSE_DIR" != "/" ]]; do
    sudo setfacl -m u:qemu:rx "$TRAVERSE_DIR" 2>/dev/null \
        || { warn "setfacl not available — installing acl package.";
             sudo "$PM" install -y acl 2>/dev/null || sudo apt-get install -y acl 2>/dev/null \
                 || die "Failed to install acl package.";
             sudo setfacl -m u:qemu:rx "$TRAVERSE_DIR" \
                 || die "setfacl failed on $TRAVERSE_DIR"; }
    TRAVERSE_DIR="$(dirname "$TRAVERSE_DIR")"
done
sudo setfacl -m u:qemu:r "$UBUNTU_ISO" \
    || die "Failed to grant qemu read access to ISO."
log "qemu ACL grants applied."

# ==========================================================
# Idempotency: skip disk/VM creation if VM already exists
# ==========================================================

if virsh dominfo "$VM_NAME" &>/dev/null; then
    warn "VM '$VM_NAME' already exists — skipping creation."
else

    log "== Creating VM disk =="
    sudo qemu-img create -f qcow2 \
        "$VM_STORAGE_DIR/${VM_NAME}.qcow2" "${DISK_GB}G" \
        || die "qemu-img disk creation failed."

    # ==========================================================
    # Build autoinstall seed ISO
    # Ubuntu subiquity reads user-data from a cidata-labeled ISO.
    # The autoinstall config sets up the user, SSH, packages,
    # and i386 libs — no manual interaction needed.
    # ==========================================================

    log "== Building autoinstall seed ISO =="

    # Generate SHA-512 password hash for rtems
    PASSWORD_HASH=$(python3 -c \
        "import crypt,os; print(crypt.crypt('$PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))" \
        2>/dev/null) || die "python3 required to hash password."

    cat > "$SCRIPT_DIR/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: $VM_NAME
    username: $USERNAME
    password: "$PASSWORD_HASH"
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - build-essential
    - git
    - curl
    - htop
    - net-tools
    - can-utils
  late-commands:
    - dpkg-reconfigure -f noninteractive tzdata
    - dpkg --add-architecture i386
    - apt-get install -y libc6:i386 libncurses5:i386 libstdc++6:i386
    - echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /target/etc/sudoers.d/$USERNAME
    - chmod 440 /target/etc/sudoers.d/$USERNAME
  storage:
    layout:
      name: direct
  user-data:
    chpasswd:
      expire: false
EOF

    cat > "$SCRIPT_DIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

    chmod 600 "$SCRIPT_DIR/user-data" "$SCRIPT_DIR/meta-data"
    make_seed_iso "$SCRIPT_DIR/seed.iso" "$SCRIPT_DIR/user-data" "$SCRIPT_DIR/meta-data"
    chmod 600 "$SCRIPT_DIR/seed.iso"

    # ==========================================================
    # Create VM — boot server ISO with autoinstall kernel arg.
    # --location extracts kernel/initrd so we can pass extra-args.
    # seed.iso (cidata) is attached as second cdrom for user-data.
    # --noautoconsole returns immediately; install runs in bg.
    # ==========================================================

    log "== Creating VM and starting unattended install =="

    virt-install \
        --name "$VM_NAME" \
        --ram "$RAM_MB" \
        --vcpus "$VCPUS" \
        --cpu host-passthrough \
        --machine q35 \
        --os-variant ubuntu22.04 \
        --disk path="$VM_STORAGE_DIR/${VM_NAME}.qcow2",format=qcow2,bus=virtio,size="$DISK_GB" \
        --disk path="$SCRIPT_DIR/seed.iso",device=cdrom,readonly=on \
        --location "$UBUNTU_ISO,kernel=casper/vmlinuz,initrd=casper/initrd" \
        --extra-args "autoinstall quiet" \
        --network network=default,model=virtio \
        --network bridge=br0,model=virtio \
        --graphics spice,listen=0.0.0.0 \
        --video qxl \
        --noautoconsole \
        || die "virt-install failed."

    log "Unattended install started. Waiting for VM to get an IP..."

    # Poll until the VM gets a DHCP lease on the default NAT network
    VM_IP=""
    for (( i=1; i<=30; i++ )); do
        VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null \
            | awk '/ipv4/{gsub(/\/[0-9]+/,"",$4); print $4}' | head -1)
        [[ -n "$VM_IP" ]] && break
        log "Waiting for VM IP — attempt $i/30..."
        sleep 10
    done

    if [[ -n "$VM_IP" ]]; then
        log "VM IP: $VM_IP"
        log "Installation is running. This takes 5-15 minutes."
        log "You can monitor progress with: virsh console $VM_NAME"
        log "SSH will become available after install completes."
        wait_for_ssh "$VM_IP"
    else
        warn "Could not determine VM IP yet — install may still be running."
        warn "Check with: virsh domifaddr $VM_NAME"
    fi

fi  # end idempotency block

# ==========================================================
# USB Passthrough — generic loop over USB_DEVICES array
# ==========================================================

log "== Adding USB passthrough definitions =="

for entry in "${USB_DEVICES[@]}"; do
    read -r DEV_NAME VENDOR_ID PRODUCT_ID COUNT KMOD <<< "$entry"

    # Count how many instances of this device are already attached.
    ALREADY=$(virsh dumpxml "$VM_NAME" 2>/dev/null \
        | grep -c "vendor id='$VENDOR_ID'" || true)

    if (( ALREADY >= COUNT )); then
        log "$DEV_NAME already has $ALREADY/$COUNT instance(s) attached — skipping."
        continue
    fi

    ATTACH_FROM=$(( ALREADY + 1 ))

    for (( i=ATTACH_FROM; i<=COUNT; i++ )); do
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
echo "VM credentials:  $USERNAME / $PASSWORD"
echo ""
echo "Unattended Ubuntu install is running (5-15 min)."
echo "Monitor install progress with:"
echo "  virsh console $VM_NAME   (Ctrl+] to exit)"
echo ""
echo "Once install completes, connect via SSH:"
echo "  ssh $USERNAME@\$(virsh domifaddr $VM_NAME | awk '/ipv4/{gsub(/\\/[0-9]+/,\"\",\$4); print \$4}')"
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
echo "Packages installed automatically in VM:"
echo "  build-essential git curl htop net-tools can-utils"
echo "  libc6:i386 libncurses5:i386 libstdc++6:i386"
echo ""
echo "Find VM IP with:"
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
