#!/bin/bash
# wifi-script.sh — Universal USB Provisioning
# Focus: Strictly ignores /boot, forces search on /media and /mnt only.

set -u

DELAY=10
MAX_RETRIES=15
RETRY_COUNT=0
TMP_LOG="/tmp/wifi_connection_log_tmp.txt"
LOG_FILE="$TMP_LOG"
FILENAME="wifi.txt"

# Added a newline to the echo to fix the formatting in your console
echo_and_log() { echo -e "\n$1"; echo "$1" >> "$LOG_FILE"; }

# 1. Hardware Check
sudo nmcli networking on >/dev/null 2>&1 || true
sudo nmcli radio wifi on  >/dev/null 2>&1 || true

WIFI_INTERFACE=$(nmcli -t -f DEVICE,TYPE device | grep ":wifi" | cut -d: -f1 | head -n1 || true)
if [ -z "${WIFI_INTERFACE:-}" ]; then
  echo -e "\n$(date): ERROR: No Wi-Fi interface found." | tee -a "$TMP_LOG"
  exit 1
fi

while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
  MOUNT_POINT=""
  MOUNTED=0

  # 2. STRICT DETECTION: Only look in /media or /mnt (ignores /boot and /)
  # This targets standard USB auto-mount and manual mount locations
  SEARCH_PATH=$(findmnt -ln -o TARGET | grep -E "^/media|^/mnt" | while read -r target; do
    if [ -f "$target/$FILENAME" ]; then
      # Double check it's not the placeholder
      SSID_CHECK=$(head -n1 "$target/$FILENAME" | tr -d '\r' | xargs)
      if [[ "$SSID_CHECK" != "network" && -n "$SSID_CHECK" ]]; then
        echo "$target"
        break
      fi
    fi
  done)

  if [ -n "$SEARCH_PATH" ]; then
    MOUNT_POINT="$SEARCH_PATH"
    MOUNTED=1
    LOG_FILE="$MOUNT_POINT/wifi_connection_log.txt"
    echo_and_log "$(date): Found VALID $FILENAME at $MOUNT_POINT"
  else
    # 3. HARDWARE FALLBACK: If not found in existing mounts, try to mount sda1
    USB_DEV=$(lsblk -rpo NAME,TYPE,FSTYPE | grep -E "vfat|exfat|fat32" | awk '{print $1}' | head -n1 || true)
    if [ -n "$USB_DEV" ]; then
      MANUAL_MOUNT="/mnt/usb"
      sudo mkdir -p "$MANUAL_MOUNT"
      # Unmount first in case it's hung, then remount
      sudo umount "$MANUAL_MOUNT" >/dev/null 2>&1 || true
      if sudo mount -o rw,user,umask=000 "$USB_DEV" "$MANUAL_MOUNT" 2>/dev/null; then
        if [ -f "$MANUAL_MOUNT/$FILENAME" ]; then
            MOUNT_POINT="$MANUAL_MOUNT"
            MOUNTED=1
            LOG_FILE="$MOUNT_POINT/wifi_connection_log.txt"
            echo_and_log "$(date): Successfully mounted USB hardware to $MOUNT_POINT"
        fi
      fi
    fi
  fi

  # 4. Provisioning
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_POINT" ]; then
    SSID=$(sed -n '1p' "$MOUNT_POINT/$FILENAME" | tr -d '\r' | xargs)
    PASSWORD=$(sed -n '2p' "$MOUNT_POINT/$FILENAME" | tr -d '\r' | xargs)

    echo_and_log "$(date): Configuring Wi-Fi for SSID: '$SSID'..."
    sudo nmcli connection delete "$SSID" >/dev/null 2>&1 || true
    
    if sudo nmcli connection add type wifi con-name "$SSID" ssid "$SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASSWORD" >/dev/null 2>&1; then
      sudo nmcli connection modify "$SSID" connection.autoconnect yes
      sudo nmcli connection modify "$SSID" connection.autoconnect-priority 999
      
      # Activation
      if sudo nmcli --wait 45 connection up "$SSID" ifname "$WIFI_INTERFACE" >> "$LOG_FILE" 2>&1; then
        echo_and_log "$(date): ✅ SUCCESS: Connected to '$SSID'."
        break
      fi
    fi
  fi

  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo -n "." # Progress dot
  sleep "$DELAY"
done


