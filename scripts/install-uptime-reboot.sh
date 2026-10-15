#!/usr/bin/env bash
# Workaround for the T2 MacBook Air being hard-reset by firmware at exactly
# 5 days (432000 s) of uptime - see SERVER.md. Installs:
#
#   1. /usr/local/bin/interlace-uptime-reboot.sh  - reboots if uptime >= 3.5 days
#   2. interlace-uptime-reboot.service            - oneshot running the script
#   3. interlace-uptime-reboot.timer              - fires it daily at 04:30
#
# Does not reboot now. Run with sudo.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing /usr/local/bin/interlace-uptime-reboot.sh"
install -m 0755 "$SRC/interlace-uptime-reboot.sh" /usr/local/bin/interlace-uptime-reboot.sh

echo "==> /etc/systemd/system/interlace-uptime-reboot.service"
cat > /etc/systemd/system/interlace-uptime-reboot.service <<'EOF'
[Unit]
Description=Reboot cleanly before the T2 firmware hard-resets at 5 days uptime

[Service]
Type=oneshot
ExecStart=/usr/local/bin/interlace-uptime-reboot.sh
EOF

echo "==> /etc/systemd/system/interlace-uptime-reboot.timer"
cat > /etc/systemd/system/interlace-uptime-reboot.timer <<'EOF'
[Unit]
Description=Daily 04:30 uptime check for interlace-uptime-reboot.service

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now interlace-uptime-reboot.timer
systemctl list-timers interlace-uptime-reboot.timer --no-pager
