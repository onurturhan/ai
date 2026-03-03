#!/bin/bash

# Usage: bb() { ~/Workspace/ai/bb.sh; }  # add this to ~/.bashrc
# Then: bb  (toggles between eno1 and eusb)

if nmcli connection show --active | grep -q "eusb"; then
    echo "Switching eusb -> eno1..."
    nmcli connection down eusb
    nmcli connection up eno1
else
    echo "Switching eno1 -> eusb..."
    nmcli connection down eno1
    nmcli connection up eusb
fi
