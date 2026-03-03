#!/bin/bash

# Usage: cb() { ~/Workspace/ai/cb.sh "$*"; }  # add this to ~/.bashrc
# Then: cb "cfs && git pull"

# Function to restore eusb connection
restore_connection() {
    echo "Restoring eusb connection..."
    nmcli connection down eno1 2>/dev/null
    nmcli connection up eusb 2>/dev/null
}

# Trap signals (like Ctrl+C) and errors to ensure we restore the connection
trap restore_connection EXIT

echo "Disconnecting eusb and connecting eno1..."
nmcli connection down eusb
nmcli connection up eno1

# Wait a moment for network to stabilize (optional)
sleep 2

echo "Executing: $@"
# Run the command passed as arguments
bash --login -i -c 'eval "$@"' -- "$@"

# The trap will handle the final switch back to eusb
