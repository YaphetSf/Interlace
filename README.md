# Interlace

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A self-hosted web console for driving a headless Kodi + aria2 media box from any
browser or mobile device. Turn a Linux machine plugged into a TV into something
you control entirely over HTTP — no remote, no on-screen menus.

- **Downloads** — paste a magnet / HTTP link or drop a `.torrent`; it downloads
  via [aria2](https://aria2.github.io/) with live progress.
- **Playback** — browse the library and play files on the TV via
  [Kodi](https://kodi.tv/)'s JSON-RPC, with full transport controls.
- **Online streams** — paste a direct media URL or a website supported by
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) and play it on Kodi without first
  downloading the complete video.
- **iOS app** — a native Swift client in `Interlace-Remote/` shares the same
  REST API.

## Quick start

```bash
# 1. Configure
cp .env.example .env
# edit .env: set ARIA2_TOKEN, KODI_USER/KODI_PASS, DOWNLOAD_DIR

# 2. Backend
cd backend
uv venv .venv
uv pip install -r requirements.txt

# 3. Frontend
cd ../frontend
npm install
npm run build

# 4. Run
cd ../backend
.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

Open `http://<box-ip>:8000`.

For production, run both aria2 and the console as systemd user services (see
below).

## Architecture

```
Browser / iOS app
        │ HTTP, over LAN or a private network
        ▼
  Interlace  (FastAPI, :8000)  — serves the built React app + REST API
        ├──► aria2 JSON-RPC   (127.0.0.1:6800)   add / list / control downloads
        ├──► library scan                         list playable videos
        └──► Kodi JSON-RPC    (127.0.0.1:8080)   Player.Open + playback control
```

Kodi runs in standalone mode as the on-TV renderer. Interlace talks to it only
over JSON-RPC. Mobile clients use the same API — never talk directly to aria2,
Kodi, or the filesystem.

## Features

- Add downloads by magnet/URL or `.torrent` upload; pause, resume, remove
- Library browser with directory navigation, search, drag-and-drop upload, delete
- Playback: seek, play/pause, stop, volume, mute
- Online playback from direct MP4/WebM/HLS/DASH URLs and yt-dlp-supported sites
- Audio-track and video-stream selection
- Subtitle selection (including off), subtitle upload, audio/subtitle delay
- Mobile-first dark UI; everything served from a single port
- `npm run doctor` — built-in diagnostics for env, systemd services, disk,
  connectivity, and audio routing

## Tech stack

| Component | Technology |
|---|---|
| Backend | FastAPI + httpx (Python ≥ 3.12) |
| Frontend | React 19 + Vite + Tailwind CSS v4 + TypeScript |
| Services | aria2 and interlace as systemd user services |
| iOS app | Swift (see `Interlace-Remote/`) |

## Project layout

```
backend/
  app.py              FastAPI app + REST API
  aria2_client.py     aria2 JSON-RPC client
  kodi_client.py      Kodi JSON-RPC client
  config.py           env-backed configuration
  doctor.py           CLI diagnostics
  pyproject.toml      Python project metadata + ruff config
  tests/              pytest suite (40 tests)
frontend/
  src/                React components + api.ts
  vite.config.ts      dev proxy to backend; build → frontend/dist
Interlace-Remote/     iOS app (Swift)
```

## Configuration reference

| Variable | Description |
|---|---|
| `ARIA2_RPC_URL` | aria2 JSON-RPC endpoint |
| `ARIA2_TOKEN` | aria2 `rpc-secret` token |
| `KODI_RPC_URL` | Kodi JSON-RPC endpoint |
| `KODI_USER` | Kodi web server username |
| `KODI_PASS` | Kodi web server password |
| `DOWNLOAD_DIR` | directory aria2 saves to / library scans |
| `YT_DLP_PATH` | optional yt-dlp executable override; defaults to the installed Python module |
| `STREAM_RESOLVE_TIMEOUT` | website URL resolution timeout in seconds |
| `CONSOLE_HOST` | bind host (default `0.0.0.0`) |
| `CONSOLE_PORT` | bind port (default `8000`) |
| `INTERLACE_VERSION` | reported service version |

## NPM scripts

| Script | What it does |
|---|---|
| `npm run doctor` | Run system diagnostics (env, services, disk, audio) |
| `npm run lint:backend` | ruff check |
| `npm run lint:backend:fix` | ruff check with auto-fix |
| `npm run test:backend` | Run 40 pytest tests |
| `npm run ci` | lint + test |
| `npm run restart` | doctor → build frontend → restart backend service |
| `npm run start` | same as restart |

## Running as systemd user services

`~/.config/systemd/user/aria2.service`:

```ini
[Unit]
Description=aria2 download daemon
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/aria2c --conf-path=%h/.aria2/aria2.conf
Restart=on-failure
RestartSec=5
StandardOutput=null
StandardError=null
NoNewPrivileges=yes
PrivateTmp=yes
MemoryMax=1G
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=default.target
```

`~/.config/systemd/user/interlace.service`:

```ini
[Unit]
Description=Interlace media console
After=network-online.target aria2.service
Wants=network-online.target

[Service]
WorkingDirectory=%h/Interlace/backend
ExecStart=%h/Interlace/backend/.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000 --timeout-graceful-shutdown 2
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
MemoryMax=512M
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now aria2.service interlace.service
loginctl enable-linger "$USER"
```

### aria2 daemon

Example `~/.aria2/aria2.conf`:

```ini
enable-rpc=true
rpc-listen-port=6800
rpc-secret=YOUR_TOKEN
dir=/home/you/Downloads
continue=true
save-session=/home/you/.aria2/aria2.session
input-file=/home/you/.aria2/aria2.session
```

Avoid `force-save=true`: it leaves `.aria2` control files on completed
downloads, which the library scanner treats as still-downloading and hides.

### Kodi systemd service

Kodi runs as a system service (`/etc/systemd/system/kodi.service`) with GBM
mode for direct DRM rendering. It must include PipeWire environment variables
so the audio path stays within PipeWire (not raw ALSA):

```ini
[Unit]
Description=Kodi Standalone Media Center (GBM Mode)
After=systemd-user-sessions.service network.target sound.target
Conflicts=getty@tty1.service

[Service]
User=%u
Group=%u
SupplementaryGroups=audio video input render tty
Environment=WINDOWING=gbm
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=PULSE_SERVER=unix:/run/user/%U/pulse/native
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
ExecStart=/usr/bin/kodi-standalone
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## API

The REST API is the single control plane. Mobile and web clients share the same
endpoints. Base URL can be a LAN IP, `.local` hostname, Tailscale MagicDNS
name, or private reverse proxy.

### Discovery

- `GET /api/health` — liveness check
- `GET /api/version` — service name and version
- `GET /api/capabilities` — feature flags and supported client modes
- `GET /api/status` — liveness plus disk state and configuration readiness

### Downloads

- `GET /api/downloads` — list all downloads (active, waiting, stopped)
- `POST /api/downloads` — add a magnet/HTTP URI
- `POST /api/downloads/torrent` — upload a `.torrent` file
- `POST /api/downloads/{gid}/pause` — pause
- `POST /api/downloads/{gid}/resume` — resume
- `DELETE /api/downloads/{gid}` — remove

### Library

- `GET /api/library?path=` — browse files and directories, returns disk usage
- `DELETE /api/library` — delete a video file
- `POST /api/upload` — upload a file into the library
- `POST /api/upload/subtitle` — upload a subtitle file alongside a video

### Playback

- `POST /api/play` — play a file by path
- `POST /api/stream` — resolve and play a public HTTP(S) media or website URL
- `GET /api/player` — current playback state (position, streams, volume)
- `POST /api/player/playpause` / `POST /api/player/stop`
- `POST /api/player/seek` — seek to percentage
- `POST /api/player/audio` / `POST /api/player/video` / `POST /api/player/subtitle` — stream selection
- `POST /api/player/volume` / `POST /api/player/mute`
- `POST /api/player/subtitle-delay` / `POST /api/player/audio-delay`

## Audio / HDMI troubleshooting

**Symptom:** video on TV, audio from built-in speakers.

The audio chain is:

```
Kodi → PipeWire (PIPEWIRE sink) → WirePlumber → correct ALSA sink
```

When any link breaks, audio falls back to internal speakers. `npm run doctor`
checks most of these automatically.

1. **User in `audio` group** — `sudo usermod -aG audio $USER && reboot`
2. **Kodi audio device** — set `PIPEWIRE:Default` in `~/.kodi/userdata/guisettings.xml`
3. **Kodi systemd env** — add `XDG_RUNTIME_DIR` and `PULSE_SERVER` to the Kodi service unit
4. **WirePlumber HDMI priority** — create a rule at `~/.config/wireplumber/wireplumber.conf.d/51-hdmi-default.conf` that gives HDMI sinks higher priority than built-in speakers

---

**Symptom:** audio comes out of the right HDMI device, but even with Kodi *and*
the TV both maxed it is far quieter than a laptop plugged straight into the same
HDMI input.

The PipeWire HDMI sink has its own master volume, applied **as a software gain
before the signal leaves the box**. HDMI is a fixed 0 dB passthrough at the ALSA
level, so this sink volume is the *only* gain stage in the chain — if it sits
below 100% (e.g. `vol: 0.40`), nothing downstream (Kodi, the TV) can recover the
lost level. WirePlumber persists per-route volume in
`~/.local/state/wireplumber/default-routes` and restores it on every boot, so a
value that was once turned down stays down across reboots.

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
wpctl get-volume @DEFAULT_AUDIO_SINK@        # check current; 1.00 = full 0 dB
wpctl set-volume  @DEFAULT_AUDIO_SINK@ 1.0   # set HDMI sink to 100%
```

⚠️ With Kodi and the TV already turned up, jumping the sink to 100% is loud —
turn the TV down before testing. The new value is saved by WirePlumber and
survives reboot; confirm it stuck with:

```bash
grep hdmi ~/.local/state/wireplumber/default-routes
# channelVolumes should read [1.000000, 1.000000]
```

## Black screen / Kodi has no video output

**Symptom:** the TV shows only the text console (a wall of error logs), not the
Kodi UI — yet `npm run doctor`'s Kodi connection check and the app's transport
controls all work. This is the giveaway: when Kodi's DRM modeset fails it keeps
answering JSON-RPC normally while rendering to an off-screen surface, so every
RPC-based check stays green.

**Cause:** a USB-C DP-Alt-Mode / HDMI dongle enumerates as a DisplayPort
connector (e.g. `DP-2`, *not* `HDMI-A-1`) and can take a second or two to report
`connected`. If `kodi.service` runs its modeset before that, it fails:

```
CWinSystemGbm::InitWindowSystem - failed to initialize Atomic DRM
CWinSystemGbm::InitWindowSystem - failed to initialize Legacy DRM
GUI format 1280x720, Display          ← empty "Display" field == no real CRTC
... failed to duplicate EGL fence fd  ← repeats forever after
```

A healthy start instead logs `GUI format 3840x2160, Display 3840x2160 @ 30 Hz`.

**Immediate fix** (display already connected): `sudo systemctl restart kodi.service`.

**Permanent fix:** `sudo ./scripts/install-display-fix.sh` installs two layers so
this can't recur:

1. **Boot gate** — a `kodi.service` `ExecStartPre` waits up to 30 s for a
   `connected` DRM connector before Kodi runs its modeset.
2. **Self-heal** — a udev DRM-hotplug rule triggers a oneshot that restarts Kodi
   *only* when a display is connected **and** Kodi is stuck off-screen. Because
   it's conditional, ordinary TV input-switch / power-cycle blips never restart
   Kodi or interrupt playback.

`npm run doctor`'s **Display & Kodi Video Output** section detects this state
directly from the kernel's DRM connectors and Kodi's log (not RPC), and prints
the exact restart command when it finds Kodi rendering off-screen.

## Known limitations

- **No auth** — intended for a trusted LAN. Don't expose port 8000 to the
  internet.
- **Subtitle/audio delay** — Kodi's JSON-RPC only exposes relative `+/-` step
  actions; absolute values can't be read or set. The UI shows estimated offsets
  per step.
- **`python-dotenv` vs `import dotenv`** — the pip package is `python-dotenv`;
  the Python import is `dotenv`.

## License

MIT — see [LICENSE](LICENSE).
