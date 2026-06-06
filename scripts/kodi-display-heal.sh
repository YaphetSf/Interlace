#!/usr/bin/env bash
# Self-heal for the "Kodi started before the display was connected" bug.
#
# Triggered by a udev DRM hotplug event (see 99-kodi-display-hotplug.rules).
# If a display is now connected but Kodi is stuck rendering off-screen (its DRM
# modeset failed at startup), restart Kodi so it does a clean modeset.
#
# Conditional by design: when Kodi is healthy this does nothing, so ordinary TV
# input-switch / power-cycle blips never restart Kodi or interrupt playback.
#
# Env:
#   KODI_USER  user whose ~/.kodi is inspected   (default: ding)
#   KODI_LOG   override log path                 (default: ~KODI_USER/.kodi/temp/kodi.log)
#   DRYRUN=1   print the decision, do not restart (for testing)
set -u
KODI_USER="${KODI_USER:-ding}"
LOG="${KODI_LOG:-/home/${KODI_USER}/.kodi/temp/kodi.log}"
STAMP=/run/kodi-display-heal.stamp

say() { logger -t kodi-display-heal "$*" 2>/dev/null; [[ -n "${DRYRUN:-}" ]] && echo "$*"; }

# 1. A display must actually be connected right now (filters disconnect events).
connected=0
for s in /sys/class/drm/card*-*/status; do
    [[ "$(cat "$s" 2>/dev/null)" == "connected" ]] && { connected=1; break; }
done
if (( ! connected )); then
    [[ -n "${DRYRUN:-}" ]] && echo "no display connected -> no action"
    exit 0
fi

# 2. Kodi must be in the off-screen failure state. kodi.log is rotated on every
#    launch, so the current file *is* the running session's startup output.
if [[ ! -r "$LOG" ]]; then
    [[ -n "${DRYRUN:-}" ]] && echo "log unreadable ($LOG) -> no action"
    exit 0
fi
off_screen=0
if grep -q "failed to initialize Atomic DRM" "$LOG" \
   && grep -q "failed to initialize Legacy DRM" "$LOG"; then
    off_screen=1
fi
# "GUI format 1280x720, Display "  -> empty Display field == no real CRTC bound.
# (healthy line ends with "... @ 30.000000 Hz" and won't match)
if grep "GUI format" "$LOG" | grep -Eq ", Display[[:space:]]*$"; then
    off_screen=1
fi
if (( ! off_screen )); then
    [[ -n "${DRYRUN:-}" ]] && echo "display connected and Kodi has real output -> no action"
    exit 0
fi

# 3. Debounce: at most one restart per 30s (avoids hotplug storms / restart
#    loops while the freshly restarted session is still writing its log).
now=$(date +%s)
if [[ -f "$STAMP" ]]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( now - last < 30 )); then
        [[ -n "${DRYRUN:-}" ]] && echo "debounced (restarted ${last} <30s ago) -> no action"
        exit 0
    fi
fi

if [[ -n "${DRYRUN:-}" ]]; then
    echo "WOULD restart kodi.service (display connected, Kodi off-screen)"
    exit 0
fi
echo "$now" > "$STAMP"
say "display connected but Kodi is off-screen; restarting kodi.service"
systemctl restart kodi.service
