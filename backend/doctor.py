#!/usr/bin/env python3
import asyncio
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Add the backend directory to sys.path so we can import config and clients
backend_dir = Path(__file__).resolve().parent
sys.path.append(str(backend_dir))

# Colors
RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
CYAN = "\033[36m"

# Symbols (Plain Text)
OK_SYM = f"{GREEN}[ OK ]{RESET}"
WARN_SYM = f"{YELLOW}[ WARN ]{RESET}"
FAIL_SYM = f"{RED}[ FAIL ]{RESET}"
INFO_SYM = f"{CYAN}[ INFO ]{RESET}"

def print_section(title):
    print(f"\n{BOLD}{CYAN}=== {title} ==={RESET}")

def print_status(sym, name, msg=""):
    details = f" - {msg}" if msg else ""
    print(f" {sym} {BOLD}{name}{RESET}{details}")

def mask_credential(val):
    if not val:
        return "<not set>"
    if len(val) <= 4:
        return "***"
    return val[:2] + "*" * (len(val) - 4) + val[-2:]

async def check_systemd_service(service_name):
    # Check if enabled
    enabled_proc = subprocess.run(
        ["systemctl", "--user", "is-enabled", service_name],
        capture_output=True, text=True
    )
    is_enabled = enabled_proc.stdout.strip() == "enabled"
    
    # Check if active
    active_proc = subprocess.run(
        ["systemctl", "--user", "is-active", service_name],
        capture_output=True, text=True
    )
    is_active = active_proc.stdout.strip() == "active"
    
    if is_active:
        status_str = f"running (enabled: {str(is_enabled).lower()})"
        print_status(OK_SYM, f"Systemd: {service_name}", status_str)
        return True
    else:
        status_str = f"stopped/failed (enabled: {str(is_enabled).lower()})"
        print_status(WARN_SYM, f"Systemd: {service_name}", f"{status_str}. Try: `systemctl --user start {service_name}`")
        return False

async def main():
    print(f"\n{BOLD}{GREEN}Interlace Console Doctor Diagnostics{RESET}")
    print("==================================================")
    
    warnings_count = 0
    errors_count = 0

    # 1. ENVIRONMENT & CONFIG CHECK
    print_section("Environment & Configurations")
    env_path = backend_dir.parent / ".env"
    if env_path.exists():
        print_status(OK_SYM, ".env file found", str(env_path))
    else:
        print_status(WARN_SYM, ".env file not found", "Using default configurations")
        warnings_count += 1

    try:
        import config
        print_status(OK_SYM, "Config module loaded successfully")
    except Exception as e:
        print_status(FAIL_SYM, "Config module failed to load", str(e))
        errors_count += 1
        sys.exit(1)

    print(f"  {BOLD}Configured variables:{RESET}")
    print(f"    - ARIA2_RPC_URL: {config.ARIA2_RPC_URL}")
    print(f"    - ARIA2_TOKEN:   {mask_credential(config.ARIA2_TOKEN)}")
    print(f"    - KODI_RPC_URL:  {config.KODI_RPC_URL}")
    print(f"    - KODI_USER:     {config.KODI_USER}")
    print(f"    - KODI_PASS:     {mask_credential(config.KODI_PASS)}")
    print(f"    - DOWNLOAD_DIR:  {config.DOWNLOAD_DIR}")
    print(f"    - CONSOLE_PORT:  {config.CONSOLE_PORT}")

    # 2. VIRTUAL ENVIRONMENT CHECK
    print_section("Python & Dependencies")
    venv_dir = backend_dir / ".venv"
    if venv_dir.is_dir():
        print_status(OK_SYM, "Virtual environment found", str(venv_dir))
    else:
        print_status(FAIL_SYM, "Virtual environment missing", "Run `python3 -m venv backend/.venv` and install dependencies")
        errors_count += 1

    print_status(INFO_SYM, "Python version", sys.version.split()[0])
    
    # Check critical installed packages
    required_packages = ["fastapi", "uvicorn", "httpx", "dotenv", "psutil"]
    for pkg in required_packages:
        try:
            if pkg == "dotenv":
                import dotenv  # noqa: F401
            else:
                __import__(pkg)
            print_status(OK_SYM, f"Package '{pkg}' is installed")
        except ImportError:
            print_status(FAIL_SYM, f"Package '{pkg}' is missing", "Run `.venv/bin/pip install -r requirements.txt`")
            errors_count += 1

    # 3. SYSTEMD SERVICES CHECK
    print_section("Systemd Services Status")
    aria2_service_ok = await check_systemd_service("aria2.service")
    interlace_service_ok = await check_systemd_service("interlace.service")
    if not aria2_service_ok or not interlace_service_ok:
        warnings_count += 1

    # 4. FILESYSTEM & DOWNLOAD DIR CHECK
    print_section("Filesystem & Download Directory")
    dl_dir = Path(config.DOWNLOAD_DIR)
    if dl_dir.exists():
        if dl_dir.is_dir():
            # Check read-write permission
            try:
                temp_file = dl_dir / ".interlace_doctor_write_test"
                temp_file.touch()
                temp_file.unlink()
                print_status(OK_SYM, "Download directory is writable", str(dl_dir))
            except Exception as e:
                print_status(FAIL_SYM, "Download directory is NOT writable", f"{dl_dir} ({str(e)})")
                errors_count += 1
            
            # Disk space check
            try:
                total, used, free = shutil.disk_usage(dl_dir)
                total_gb = total / (1024**3)
                free_gb = free / (1024**3)
                percent_free = (free / total) * 100
                
                space_str = f"{free_gb:.1f} GB free of {total_gb:.1f} GB ({percent_free:.1f}% free)"
                if free_gb < 5.0:
                    print_status(WARN_SYM, "Low disk space", space_str)
                    warnings_count += 1
                else:
                    print_status(OK_SYM, "Disk space sufficient", space_str)
            except Exception as e:
                print_status(WARN_SYM, "Could not determine disk usage", str(e))
                warnings_count += 1
        else:
            print_status(FAIL_SYM, "Download path is not a directory", str(dl_dir))
            errors_count += 1
    else:
        print_status(FAIL_SYM, "Download directory does not exist", str(dl_dir))
        errors_count += 1

    # 5. CONNECTION CHECKS
    print_section("Component Connections")
    
    # 5.1 Aria2 JSON-RPC Connection Check
    from aria2_client import Aria2
    aria2 = Aria2()
    try:
        ver_info = await aria2._call("aria2.getVersion")
        version = ver_info.get("version", "unknown")
        print_status(OK_SYM, "aria2 connection successful", f"Version {version}")
    except Exception as e:
        print_status(FAIL_SYM, "aria2 connection failed", f"URL: {config.ARIA2_RPC_URL}. Error: {str(e)}")
        print(f"      {BOLD}{YELLOW}Tip:{RESET} Ensure aria2c is running and ARIA2_TOKEN in .env matches the daemon RPC token.")
        errors_count += 1

    # 5.2 Kodi JSON-RPC Connection Check
    from kodi_client import Kodi
    kodi = Kodi()
    try:
        ping_res = await kodi._call("JSONRPC.Ping")
        if ping_res == "pong":
            # Get Kodi application properties
            app_props = await kodi._call("Application.GetProperties", {"properties": ["volume", "muted"]})
            vol = app_props.get("volume", 0)
            muted = app_props.get("muted", False)
            muted_str = " (muted)" if muted else ""
            print_status(OK_SYM, "Kodi connection successful", f"Ping response: {ping_res}, Volume: {vol}%{muted_str}")
        else:
            print_status(WARN_SYM, "Kodi connection returned unexpected response", str(ping_res))
            warnings_count += 1
    except Exception as e:
        print_status(FAIL_SYM, "Kodi connection failed", f"URL: {config.KODI_RPC_URL}. Error: {str(e)}")
        print(f"      {BOLD}{YELLOW}Tip:{RESET} Make sure Kodi is running on the media box, 'Allow remote control via HTTP' is enabled,")
        print("           and Port/Username/Password in Kodi settings match your .env.")
        errors_count += 1

    # 5.3 Local Console Web Server Check
    import httpx
    local_url = f"http://127.0.0.1:{config.CONSOLE_PORT}/api/health"
    server_online = False
    try:
        async with httpx.AsyncClient(timeout=2) as c:
            r = await c.get(local_url)
            if r.status_code == 200:
                print_status(OK_SYM, "Interlace local API server is active", f"URL: {local_url}")
                server_online = True
            else:
                print_status(WARN_SYM, "Interlace local API returned status", str(r.status_code))
                warnings_count += 1
    except Exception:
        print_status(WARN_SYM, "Interlace local API is offline", f"Port {config.CONSOLE_PORT} is not responding (expected if you haven't started it).")
        # Don't increment warnings as it might be off during dev

    # 5.4 System stats endpoint check
    if server_online:
        system_url = f"http://127.0.0.1:{config.CONSOLE_PORT}/api/system"
        try:
            async with httpx.AsyncClient(timeout=3) as c:
                r = await c.get(system_url)
                if r.status_code == 200:
                    data = r.json()
                    cpu = data.get("cpu", {}).get("percent", "?")
                    mem = data.get("memory", {}).get("percent", "?")
                    temp = data.get("cpu", {}).get("temp")
                    temp_str = f", temp: {temp}°C" if temp is not None else ""
                    print_status(OK_SYM, "System stats endpoint active", f"CPU: {cpu}%, RAM: {mem}%{temp_str}")
                else:
                    print_status(WARN_SYM, "System stats endpoint returned status", str(r.status_code))
                    warnings_count += 1
        except Exception as e:
            print_status(FAIL_SYM, "System stats endpoint failed", str(e))
            errors_count += 1

    # 6. AUDIO / HDMI DIAGNOSTICS
    print_section("Audio & HDMI Diagnostics")
    import grp
    import pwd

    current_user = pwd.getpwuid(os.getuid()).pw_name

    # 6.1 User in audio group
    try:
        audio_group = grp.getgrnam("audio")
        if current_user in audio_group.gr_mem:
            print_status(OK_SYM, f"User '{current_user}' is in 'audio' group")
        else:
            print_status(FAIL_SYM, f"User '{current_user}' NOT in 'audio' group",
                         f"Run: sudo usermod -aG audio {current_user} && reboot")
            errors_count += 1
    except KeyError:
        print_status(WARN_SYM, "No 'audio' group found on this system")

    # 6.2 PipeWire & WirePlumber running
    for svc in ["pipewire.service", "pipewire-pulse.service", "wireplumber.service"]:
        proc = subprocess.run(
            ["systemctl", "--user", "is-active", svc],
            capture_output=True, text=True
        )
        if proc.stdout.strip() == "active":
            print_status(OK_SYM, f"User service: {svc}", "running")
        else:
            print_status(WARN_SYM, f"User service: {svc}",
                         f"not active. Try: systemctl --user restart {svc}")
            warnings_count += 1

    # 6.3 PipeWire-Pulse socket exists
    pulse_socket = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "pulse" / "native"
    if pulse_socket.exists():
        print_status(OK_SYM, "PipeWire-Pulse socket", str(pulse_socket))
    else:
        print_status(FAIL_SYM, "PipeWire-Pulse socket missing",
                     "Run: systemctl --user restart pipewire-pulse")
        errors_count += 1

    # 6.4 HDMI sink visible to PipeWire
    try:
        pw_nodes = subprocess.run(
            ["pw-cli", "ls", "Node"],
            capture_output=True, text=True, timeout=5,
            env={**os.environ, "XDG_RUNTIME_DIR": f"/run/user/{os.getuid()}"}
        )
        if "hdmi" in pw_nodes.stdout.lower():
            print_status(OK_SYM, "HDMI audio sink detected by PipeWire")
        else:
            print_status(WARN_SYM, "No HDMI sink in PipeWire",
                         "TV may be off or HDMI audio not connected")
            warnings_count += 1
    except FileNotFoundError:
        print_status(WARN_SYM, "pw-cli not found", "Install pipewire to enable audio diagnostics")
    except Exception as e:
        print_status(WARN_SYM, "Could not query PipeWire nodes", str(e))

    # 6.5 Kodi not bypassing PipeWire (checks if kodi.bin has ALSA hw fds open)
    try:
        pgrep = subprocess.run(["pgrep", "-x", "kodi.bin"], capture_output=True, text=True)
        if pgrep.stdout.strip():
            kodi_pid = pgrep.stdout.strip().split()[0]
            snd_fds = subprocess.run(
                ["bash", "-c", f"ls -la /proc/{kodi_pid}/fd 2>/dev/null | grep /dev/snd"],
                capture_output=True, text=True
            )
            if snd_fds.stdout.strip():
                print_status(FAIL_SYM, "Kodi is bypassing PipeWire (ALSA hw access)",
                             "Kodi is opening /dev/snd directly. Check Kodi systemd env vars.")
                print(f"      {BOLD}{YELLOW}Fix:{RESET} Add PULSE_SERVER + XDG_RUNTIME_DIR to /etc/systemd/system/kodi.service")
                print("      and set audiodevice to PIPEWIRE:Default in guisettings.xml")
                errors_count += 1
            else:
                print_status(OK_SYM, "Kodi is using PipeWire (no ALSA hw fds)")
        else:
            print_status(WARN_SYM, "Kodi is not running", "Start Kodi to verify audio path")
            warnings_count += 1
    except Exception as e:
        print_status(WARN_SYM, "Could not inspect Kodi audio path", str(e))

    # 6.6 Kodi systemd service has required env vars
    kodi_unit = Path("/etc/systemd/system/kodi.service")
    if kodi_unit.exists():
        unit_text = kodi_unit.read_text()
        for var, desc in [("PULSE_SERVER", "PULSE_SERVER"), ("XDG_RUNTIME_DIR", "XDG_RUNTIME_DIR")]:
            if var in unit_text:
                print_status(OK_SYM, f"Kodi service has {desc}")
            else:
                print_status(FAIL_SYM, f"Kodi service missing {desc}",
                             "Kodi will fall back to ALSA hardware. See README Audio/HDMI section.")
                errors_count += 1
    else:
        print_status(WARN_SYM, "Kodi systemd service not found", str(kodi_unit))

    # 7. SUMMARY
    print("\n==================================================")
    if errors_count == 0 and warnings_count == 0:
        print(f" {BOLD}{GREEN}ALL SYSTEM DIAGNOSTICS CLEAR! Interlace is healthy.{RESET}")
    elif errors_count == 0:
        print(f" {BOLD}{YELLOW}DIAGNOSTICS PASSED WITH WARNINGS ({warnings_count} warning(s)).{RESET}")
        print("   Review the warnings above to optimize your configuration.")
    else:
        print(f" {BOLD}{RED}DIAGNOSTICS FAILED ({errors_count} error(s), {warnings_count} warning(s)).{RESET}")
        print("   Please resolve the errors highlighted in red above to restore functionality.")
    print("==================================================\n")

if __name__ == "__main__":
    asyncio.run(main())
