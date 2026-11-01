#!/usr/bin/python3
"""Put the TV back at its monitors.xml mode after i915's DP link-training fallback - see SERVER.md."""

import glob
import json
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

USER = "ding"
RUNTIME_DIR = "/run/user/1000"
MONITORS_XML = "/home/ding/.config/monitors.xml"
STATE_FILE = "/run/interlace-tv-mode-guard.json"
BACKOFF = (0, 240, 480, 600)  # seconds to wait after 0, 1, 2, 3+ failed attempts
DISPLAY_CONFIG = ("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                  "org.gnome.Mutter.DisplayConfig")


def mutter(method, params=None):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    return bus.call_sync(*DISPLAY_CONFIG, method, params, None, 0, -1, None).unpack()


def tv_state():
    serial, monitors, _, _ = mutter("GetCurrentState")
    for spec, modes, props in monitors:
        if props.get("is-builtin"):
            continue
        return {"serial": serial, "connector": spec[0],
                "current": next((m[0] for m in modes if m[6].get("is-current")), None),
                "modes": [m[:4] for m in modes]}
    return None


def apply_mode(connector, mode):
    serial = mutter("GetCurrentState")[0]
    layout = [(0, 0, 1.0, 0, True, [(connector, mode, {})])]
    mutter("ApplyMonitorsConfig", GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (serial, 1, layout, {})))


def as_user(*args):
    env = [f"XDG_RUNTIME_DIR={RUNTIME_DIR}", f"DBUS_SESSION_BUS_ADDRESS=unix:path={RUNTIME_DIR}/bus"]
    out = subprocess.run(["runuser", "-u", USER, "--", "env", *env, sys.executable,
                          os.path.abspath(__file__), *args],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def wanted_mode(connector):
    try:
        root = ET.parse(MONITORS_XML).getroot()
    except (OSError, ET.ParseError):
        return None
    for monitor in root.iter("monitor"):
        if monitor.findtext("monitorspec/connector") == connector:
            mode = monitor.find("mode")
            return int(mode.findtext("width")), int(mode.findtext("height")), float(mode.findtext("rate"))
    return None


def find_mode(state, want):
    width, height, rate = want
    return next((m[0] for m in state["modes"]
                 if m[1] == width and m[2] == height and abs(m[3] - rate) < 0.01), None)


def wait_for_mode(want, timeout):
    deadline = time.monotonic() + timeout
    while True:
        state = as_user("state")
        if (state and find_mode(state, want)) or time.monotonic() > deadline:
            return state
        time.sleep(1)


def write(path, value):
    with open(path, "w") as f:
        f.write(value)


def reprobe(connector):
    status = glob.glob(f"/sys/class/drm/card*-{connector}/status")[0]
    card = os.path.basename(os.path.dirname(status)).split("-")[0].removeprefix("card")
    # Writing auto runs intel_dp_reset_link_params: full rate and lanes, retraining re-enabled.
    write(f"/sys/kernel/debug/dri/{card}/{connector}/i915_dp_force_link_rate", "auto")
    # A bare detect reprobes without a hotplug uevent, so mutter would keep its pruned mode list.
    write(status, "off")
    time.sleep(3)
    write(status, "detect")


def load_record():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"failures": 0, "last": 0}


def save_record(record):
    with open(STATE_FILE, "w") as f:
        json.dump(record, f)


def guard():
    if not os.path.exists(f"{RUNTIME_DIR}/bus"):
        return
    state = as_user("state")
    record = load_record()
    want = state and wanted_mode(state["connector"])
    if not want or state["current"] == find_mode(state, want):
        if record["failures"]:
            save_record({"failures": 0, "last": 0})
        return
    if time.time() - record["last"] < BACKOFF[min(record["failures"], len(BACKOFF) - 1)]:
        return

    connector = state["connector"]
    print(f"{connector} at {state['current']}, want {want[0]}x{want[1]}@{want[2]:g}: "
          "resetting i915 link limits and reprobing", flush=True)
    reprobe(connector)
    state = wait_for_mode(want, 15)
    mode = state and find_mode(state, want)
    if mode and state["current"] != mode:
        as_user("apply", connector, mode)
    time.sleep(8)
    state = as_user("state")
    ok = bool(state) and state["current"] == find_mode(state, want)
    print(f"{'restored' if ok else 'not restored'}: {connector} at {state and state['current']}", flush=True)
    save_record({"failures": 0 if ok else record["failures"] + 1, "last": time.time()})


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "guard"
    if command == "state":
        print(json.dumps(tv_state()))
    elif command == "apply":
        apply_mode(*sys.argv[2:4])
        print("null")
    else:
        guard()
