#!/usr/bin/env bash
# Permanent cure for the "Kodi renders off-screen because it started before the
# HDMI/DP dongle was connected" bug. Installs:
#
#   1. /usr/local/bin/kodi-wait-for-display.sh   - ExecStartPre boot gate
#   2. /usr/local/bin/kodi-display-heal.sh        - conditional self-heal
#   3. kodi.service.d/10-wait-for-display.conf    - wires the gate into Kodi
#   4. kodi-display-heal.service                  - oneshot run by udev
#   5. udev rule on DRM hotplug                   - triggers the self-heal
#
# Non-disruptive: does NOT restart a currently-running Kodi. Run with sudo.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KODI_USER="${KODI_USER:-ding}"

echo "==> Installing runtime scripts to /usr/local/bin"
install -m 0755 "$SRC/kodi-wait-for-display.sh" /usr/local/bin/kodi-wait-for-display.sh
install -m 0755 "$SRC/kodi-display-heal.sh"      /usr/local/bin/kodi-display-heal.sh

echo "==> Boot gate: kodi.service.d/10-wait-for-display.conf"
install -d /etc/systemd/system/kodi.service.d
cat > /etc/systemd/system/kodi.service.d/10-wait-for-display.conf <<'EOF'
# Wait (up to 30s) for a connected DRM connector before Kodi runs its modeset,
# so it never starts off-screen during the boot hotplug race.
[Service]
ExecStartPre=/usr/local/bin/kodi-wait-for-display.sh 30
EOF

echo "==> Self-heal unit: kodi-display-heal.service"
cat > /etc/systemd/system/kodi-display-heal.service <<EOF
[Unit]
Description=Restart Kodi if a display connected while it was rendering off-screen
After=kodi.service

[Service]
Type=oneshot
Environment=KODI_USER=${KODI_USER}
ExecStart=/usr/local/bin/kodi-display-heal.sh
EOF

echo "==> udev rule: /etc/udev/rules.d/99-kodi-display-hotplug.rules"
cat > /etc/udev/rules.d/99-kodi-display-hotplug.rules <<'EOF'
# On a DRM display hotplug, ask systemd to run the conditional Kodi self-heal.
SUBSYSTEM=="drm", ACTION=="change", ENV{HOTPLUG}=="1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="kodi-display-heal.service"
EOF

echo "==> Reloading systemd and udev"
systemctl daemon-reload
udevadm control --reload

echo "Done. The fix is active now and persists across reboots."
echo "It did NOT restart your running Kodi."
