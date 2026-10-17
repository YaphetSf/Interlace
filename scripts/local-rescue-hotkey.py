#!/usr/bin/python3
"""Show or hide Kodi in GNOME with Ctrl+Alt+K, even when offline."""

import glob
import os
import selectors
import struct
import subprocess
import time


EVENT = struct.Struct("llHHi")  # struct input_event on this 64-bit Linux host
EV_KEY = 1
KEY_K = 37
CTRL = {29, 97}
ALT = {56, 100}
COOLDOWN = 3.0
SYSTEMCTL = "/usr/bin/systemctl"
USER_MANAGER = [SYSTEMCTL, "--user", "--machine=ding@.host"]
KODI_UNIT = "interlace-kodi-desktop.service"


def open_devices(selector, devices):
    paths = set(glob.glob("/dev/input/event*"))
    for path in list(devices):
        if path not in paths:
            selector.unregister(devices[path][0])
            os.close(devices.pop(path)[0])
    for path in paths - devices.keys():
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        except OSError:
            continue
        selector.register(fd, selectors.EVENT_READ, path)
        devices[path] = (fd, set())


def close_device(selector, devices, path):
    fd = devices.pop(path)[0]
    selector.unregister(fd)
    os.close(fd)


def toggle_display():
    try:
        active = subprocess.run(
            USER_MANAGER + ["is-active", "--quiet", KODI_UNIT],
            timeout=5,
        ).returncode == 0
        action = "stop" if active else "start"
        if action == "start" and subprocess.run(
            USER_MANAGER + ["is-active", "--quiet", "graphical-session.target"],
            timeout=5,
        ).returncode != 0:
            print("Ctrl+Alt+K: log in to GNOME before starting Kodi", flush=True)
            return
        print(f"Ctrl+Alt+K: {action} Kodi", flush=True)
        subprocess.run(USER_MANAGER + [action, KODI_UNIT], check=True, timeout=45)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"Display switch failed: {exc}", flush=True)


def main():
    selector = selectors.DefaultSelector()
    devices = {}
    last_toggle = 0.0
    print("Ctrl+Alt+K display switch listener started", flush=True)
    while True:
        open_devices(selector, devices)
        for key, _ in selector.select(timeout=2):
            path = key.data
            fd, held = devices[path]
            try:
                data = os.read(fd, EVENT.size * 64)
            except OSError:
                close_device(selector, devices, path)
                continue
            if not data:
                close_device(selector, devices, path)
                continue
            for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _, _, event_type, code, value = EVENT.unpack_from(data, offset)
                if event_type != EV_KEY or value == 2:
                    continue
                if value == 0:
                    held.discard(code)
                elif value == 1:
                    held.add(code)
                if code == KEY_K and value == 1 and held & CTRL and held & ALT:
                    now = time.monotonic()
                    if now - last_toggle >= COOLDOWN:
                        last_toggle = now
                        toggle_display()


if __name__ == "__main__":
    main()
