#!/usr/bin/env bash
# Cleanly reboot once uptime passes 3.5 days, before the T2 firmware hard-resets
# the MacBook Air at exactly 5 days (432000 s) - see SERVER.md.
# Run daily at 04:30 by interlace-uptime-reboot.timer, so it always fires on the
# 4th day after any boot.
#
# Env:
#   THRESHOLD  seconds of uptime that trigger a reboot   (default: 302400)
#   DRYRUN=1   print the decision, do not reboot
set -u
THRESHOLD="${THRESHOLD:-302400}"
up="$(cut -d. -f1 /proc/uptime)"

if (( up < THRESHOLD )); then
    [[ -n "${DRYRUN:-}" ]] && echo "uptime ${up}s < ${THRESHOLD}s -> no action"
    exit 0
fi

if [[ -n "${DRYRUN:-}" ]]; then
    echo "uptime ${up}s >= ${THRESHOLD}s -> would reboot"
    exit 0
fi
logger -t interlace-uptime-reboot "uptime ${up}s >= ${THRESHOLD}s, rebooting"
systemctl reboot
