#!/usr/bin/env bash
# Keep the TV at its monitors.xml mode (3840x2160@30) - see SERVER.md. Installs:
#
#   1. /home/ding/.config/monitors.xml                - GNOME's stored layout for the TV
#   2. /usr/local/libexec/interlace-tv-mode-guard.py  - lifts the i915 link fallback and reapplies the mode
#   3. interlace-tv-mode-guard.service                - oneshot running the guard
#   4. interlace-tv-mode-guard.timer                  - 90 s after boot, then every 2 min
#
# GNOME reads monitors.xml only at login. Run with sudo.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing /home/ding/.config/monitors.xml"
install -o ding -g ding -m 0644 "$SRC/monitors.xml" /home/ding/.config/monitors.xml

echo "==> Installing /usr/local/libexec/interlace-tv-mode-guard.py"
install -D -m 0755 "$SRC/interlace-tv-mode-guard.py" /usr/local/libexec/interlace-tv-mode-guard.py

echo "==> /etc/systemd/system/interlace-tv-mode-guard.service"
cat > /etc/systemd/system/interlace-tv-mode-guard.service <<'EOF'
[Unit]
Description=Put the TV back at its monitors.xml mode after a DP link-training fallback

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/libexec/interlace-tv-mode-guard.py
SyslogIdentifier=interlace-tv-mode-guard
TimeoutStartSec=90
EOF

echo "==> /etc/systemd/system/interlace-tv-mode-guard.timer"
cat > /etc/systemd/system/interlace-tv-mode-guard.timer <<'EOF'
[Unit]
Description=Run interlace-tv-mode-guard.service every 2 minutes

[Timer]
OnBootSec=90s
OnUnitActiveSec=2min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now interlace-tv-mode-guard.timer
systemctl list-timers interlace-tv-mode-guard.timer --no-pager
