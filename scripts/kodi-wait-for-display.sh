#!/usr/bin/env bash
# ExecStartPre gate for kodi.service.
#
# A USB-C DP-Alt-Mode / HDMI dongle can take a second or two after boot to
# enumerate a *connected* DRM connector. If Kodi runs its DRM modeset before
# that happens it fails ("failed to initialize Atomic/Legacy DRM") and renders
# to an off-screen surface forever — the TV stays black while JSON-RPC still
# answers normally. This gate gives the display time to appear first.
#
# Always exits 0: it must never block boot indefinitely. If it times out, the
# udev self-heal (kodi-display-heal.sh) is the safety net.
set -u
timeout="${1:-30}"
deadline=$(( $(date +%s) + timeout ))
while (( $(date +%s) < deadline )); do
    for s in /sys/class/drm/card*-*/status; do
        if [[ "$(cat "$s" 2>/dev/null)" == "connected" ]]; then
            exit 0
        fi
    done
    sleep 1
done
exit 0
