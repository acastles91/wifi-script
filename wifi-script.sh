##!/bin/bash
# wifi-script.sh — Universal version for RPi (any user) and BTT CB1 (biqu)

set -u

DELAY=5
MAX_RETRIES=5
RETRY_COUNT=0
TMP_LOG="/tmp/wifi_connection_log_tmp.txt"
LOG_FILE="$TMP_LOG"
FILENAME="wifi.txt"

echo_and_log() { echo "$1"; echo "$1" >> "$LOG_FILE"; }

# 1. Hardware Check
sudo nmcli networking on >/dev/null 2>&1 || true
sudo nmcli radio wifi on  >/dev/null 2>&1 || true

WIFI_INTERFACE=$(nmcli -t -f DEVICE,TYPE device | grep ":wifi" | cut -d: -f1 | head -n1 || true)
if [ -z "${WIFI_INTERFACE:-}" ]; then
  echo "$(date): ERROR: No Wi-Fi interface found." | tee -a "$TMP_LOG"
  exit 1
fi

while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
  MOUNT_POINT=""
  MOUNTED=0

  # 2. UNIVERSAL DETECTION: Scan ALL mount points for wifi.txt
  # This finds the file regardless of /media/antonio, /media/biqu, or /mnt/usb
  SEARCH_PATH=$(findmnt -ln -o TARGET | while read -r target; do
    if [ -f "$target/$FILENAME" ]; then
      echo "$target"
      break
    fi
  done)

  if [ -n "$SEARCH_PATH" ]; then
    MOUNT_POINT="$SEARCH_PATH"
    MOUNTED=1
    LOG_FILE="$MOUNT_POINT/wifi_connection_log.txt"
    echo_and_log "$(date): Found $FILENAME at $MOUNT_POINT"
  else
    # Fallback: If not mounted at all, try manual mount
    USB_DEV=$(lsblk -rpo NAME,TYPE,FSTYPE | grep -E "part|disk" | grep -E "vfat|exfat|fat32" | awk '{print $1}' | head -n1 || true)
    if [ -n "$USB_DEV" ]; then
      MANUAL_MOUNT="/mnt/usb"
      sudo mkdir -p "$MANUAL_MOUNT"
      if sudo mount -o rw,user,umask=000 "$USB_DEV" "$MANUAL_MOUNT" 2>/dev/null; then
        MOUNT_POINT="$MANUAL_MOUNT"
        MOUNTED=1
        LOG_FILE="$MOUNT_POINT/wifi_connection_log.txt"
        echo_and_log "$(date): Manually mounted $USB_DEV to $MOUNT_POINT"
      fi
    fi
  fi

  # 3. Provisioning
  if [ "$MOUNTED" -eq 1 ] && [ -f "$MOUNT_POINT/$FILENAME" ]; then
    SSID=$(sed -n '1p' "$MOUNT_POINT/$FILENAME" | tr -d '\r' | xargs)
    PASSWORD=$(sed -n '2p' "$MOUNT_POINT/$FILENAME" | tr -d '\r' | xargs)

    if [[ -z "$SSID" || -z "$PASSWORD" ]]; then
      echo_and_log "$(date): SSID/Password empty."
    else
      echo_and_log "$(date): Configuring Wi-Fi: '$SSID'..."
      sudo nmcli connection delete "$SSID" >/dev/null 2>&1 || true
      
      if sudo nmcli connection add type wifi con-name "$SSID" ssid "$SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASSWORD"; then
        sudo nmcli connection modify "$SSID" 802-11-wireless.cloned-mac-address permanent
        
        # Robust BSSID Pinning
        BEST_BSSID=$(nmcli -t -f SSID,BSSID,SIGNAL device wifi list | grep "^$SSID:" | sort -t: -k3,3nr | head -n1 | cut -d: -f2-7 | sed 's/\\//g' || true)
        [[ -n "$BEST_BSSID" ]] && sudo nmcli connection modify "$SSID" 802-11-wireless.bssid "$BEST_BSSID"

        if sudo nmcli --wait 45 connection up "$SSID" ifname "$WIFI_INTERFACE" >> "$LOG_FILE" 2>&1; then
          echo_and_log "$(date): ✅ SUCCESS: Connected to '$SSID'."
          sudo nmcli connection modify "$SSID" connection.autoconnect yes
          break
        fi
      fi
    fi
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  sleep "$DELAY"
done


