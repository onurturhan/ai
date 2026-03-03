#!/bin/bash
###############################################################################
# Auto Remote Desktop Approver
#
# This script monitors xdg-desktop-portal for RemoteDesktop/ScreenCast
# requests and automatically sends key events using ydotool.
#
# ---------------------------------------------------------------------------
# INSTALLATION
# ---------------------------------------------------------------------------
# 1️⃣  Create scripts directory:
#     mkdir -p ~/.scripts
#
# 2️⃣  Save this file as:
#     ~/.scripts/auto_remote_share.sh
#
# 3️⃣  Make it executable:
#     chmod +x ~/.scripts/auto_remote_share.sh
#
# 4️⃣  Create systemd user service:
#     mkdir -p ~/.config/systemd/user
#     nano ~/.config/systemd/user/auto_remote_share.service
#
#     Paste the following:
#
#     [Unit]
#     Description=Auto-approve GNOME Remote Desktop
#
#     [Service]
#     ExecStart=/home/rtems/.scripts/auto_remote_share.sh
#     Restart=always
#     RestartSec=2
#
#     [Install]
#     WantedBy=default.target
#
# 5️⃣  Reload and enable:
#     systemctl --user daemon-reload
#     systemctl --user enable auto_remote_share.service
#     systemctl --user start auto_remote_share.service
#
# ---------------------------------------------------------------------------
# VIEW LOGS
# ---------------------------------------------------------------------------
# Live logs:
#     journalctl --user -u auto_remote_share.service -f
#
# Last 50 lines:
#     journalctl --user -u auto_remote_share.service -n 50
#
###############################################################################

# Adjustable parameters
DETECT_SLEEP=0.5   # how often to check DBus
KEY_DELAY=1        # delay between key presses
POPUP_WAIT=1       # wait after detecting request for popup to appear
RETRY_COUNT=5      # retry attempts if focus not ready

echo "Starting auto-approve for GNOME Remote Desktop..."

# Monitor both ScreenCast and RemoteDesktop interfaces
dbus-monitor --session "interface='org.freedesktop.portal.ScreenCast'" "interface='org.freedesktop.portal.RemoteDesktop'" |
while read -r line; do
    # Detect a new Start request
    if echo "$line" | grep -q "Start"; then
        echo "$(date '+%H:%M:%S') Portal request detected, waiting for popup..."
        sleep $POPUP_WAIT

        for attempt in $(seq 1 $RETRY_COUNT); do
            echo "Attempt $attempt of $RETRY_COUNT"

            # Get current portal windows info using gdbus
            window_info=$(gdbus call --session \
                --dest org.freedesktop.portal.Desktop \
                --object-path /org/freedesktop/portal/desktop \
                --method org.freedesktop.DBus.Properties.Get \
                org.freedesktop.portal.ScreenCast "windows" 2>/dev/null)

            #if echo "$window_info" | grep -q '"Remote"'; then
                echo "$(date '+%H:%M:%S') Remote Desktop popup detected"

                # 1️⃣ Click middle of screen
                #SCREEN_W=$(xdpyinfo | grep dimensions | awk '{print $2}' | cut -d'x' -f1)
                #SCREEN_H=$(xdpyinfo | grep dimensions | awk '{print $2}' | cut -d'x' -f2)
                #MIDDLE_X=$((SCREEN_W / 2))
                #MIDDLE_Y=$((SCREEN_H / 2))
                #echo "Clicking middle of screen at $MIDDLE_X,$MIDDLE_Y"
                #ydotool mousemove $MIDDLE_X $MIDDLE_Y click 1
                #sleep $KEY_DELAY

                # 1️⃣ Alt+Tab to focus popup
                echo "Pressing Alt+Tab"
                ydotool key 56:1 15:1 15:0 56:0  # 56=Alt, 15=Tab
                sleep $KEY_DELAY

                # 2️⃣ SPACE
                echo "Pressing SPACE"
                ydotool key 57:1 57:0
                sleep $KEY_DELAY

                # 3️⃣ TAB x4
                for i in {1..4}; do
                    echo "Pressing TAB ($i)"
                    ydotool key 15:1 15:0
                    sleep $KEY_DELAY

                    if [ "$i" -eq 1 ]; then
                        echo "Pressing SPACE after TAB 2"
                        ydotool key 57:1 57:0
                        sleep $KEY_DELAY
                    fi
                done

                # 4️⃣ ENTER
                echo "Pressing ENTER"
                ydotool key 28:1 28:0
                sleep $KEY_DELAY

                echo "Attempt $attempt completed successfully"
                break
            #else
            #    echo "Remote Desktop popup not yet detected, retrying..."
            #    sleep $DETECT_SLEEP
            #fi
        done

        echo "$(date '+%H:%M:%S') Sequence done, waiting for next portal request..."
    fi
done
