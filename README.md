# Interlace Console

A self-hosted web console for driving a headless media box from your phone or
laptop. It turns a retired laptop (here, a 2020 Intel MacBook Air running Ubuntu
+ Kodi, plugged into a TV) into something you control entirely from a browser —
so you never have to drive Kodi's on-screen menus with a remote.

Two things in one UI:

- **Downloads** — paste a magnet / HTTP link or drop a `.torrent`; it downloads
  via [aria2](https://aria2.github.io/) with live progress.
- **Playback** — browse the downloaded videos and play any of them on the TV via
  [Kodi](https://kodi.tv/)'s JSON-RPC, with full transport controls.

## Features

- Add downloads by magnet/URL or `.torrent` upload; pause / resume / remove
- Library scan of the download directory, one-tap "play on TV"
- Playback control: scrub/seek, play-pause, stop, volume + mute
- Audio-track and video-stream selection
- Subtitle selection (including off) and subtitle/audio delay nudging
- Mobile-first dark UI; everything served from a single port

> **Note on subtitle/audio delay:** Kodi's JSON-RPC only exposes delay as
> relative `+/-` step actions — the absolute value can't be read or set. The UI
> therefore shows an *estimated* offset (≈0.1s/step, reset on track change).
> Every other control is exact.

## Architecture

```
Phone / laptop browser
Native mobile app
        │ HTTP(S), over LAN or a private network
        ▼
  Interlace Console  (FastAPI, :8000)  ── serves the built React app + REST API
        ├──► aria2 JSON-RPC   (127.0.0.1:6800)   add / list / control downloads
        ├──► download dir scan                    list playable videos
        └──► Kodi JSON-RPC    (127.0.0.1:8080)    Player.Open + playback control
```

Kodi keeps running in standalone mode as the on-TV renderer; the console only
talks to it over JSON-RPC.

The React web UI and any native mobile app are clients of the same Interlace
API. Mobile clients should not talk directly to aria2, Kodi, or the filesystem;
the FastAPI service is the single control plane for downloads, library state,
and playback.

Clients should treat Interlace as a base-URL-addressed API. The base URL can be
a LAN IP, `.local` hostname, tailnet address, MagicDNS name, or private reverse
proxy URL. The backend does not require a specific public hostname; if a client
can route HTTP(S) requests to the FastAPI service, it should call the same
relative `/api/*` endpoints.

### Connection modes

Interlace is designed to work in a few network shapes without changing the app
model:

- **Local LAN:** clients connect directly to `http://<box-ip>:8000`. Future
  mobile clients can discover the box with Bonjour/mDNS, with manual IP entry as
  a fallback.
- **Private network:** Tailscale, WireGuard, Headscale, or similar users can
  enter any reachable Interlace base URL, such as a MagicDNS name or `100.x.y.z`
  address.
- **Private reverse proxy:** advanced users can put Interlace behind a private
  HTTPS reverse proxy or VPS route, as long as the proxy is not exposed as an
  unauthenticated public internet service.

For public releases and native mobile clients, Interlace should grow a pairing
flow and bearer-token authentication. A good target is QR-code pairing from the
web UI: the QR code carries a base URL plus a short-lived pairing code, and the
mobile app exchanges that for a device token stored in the platform keychain.

### API discovery

Mobile and remote clients can start with these lightweight endpoints:

- `GET /api/health` — minimal liveness check.
- `GET /api/version` — service name and version.
- `GET /api/capabilities` — supported client modes, connection modes, and
  feature flags.
- `GET /api/status` — liveness plus request-derived API base information and
  local server readiness.

## Tech stack

- **Backend:** FastAPI + httpx (Python 3.14), one process serving API and static UI
- **Frontend:** React + Vite + Tailwind CSS v4
- **Services:** aria2 and the console both run as systemd *user* services

## Project layout

```
backend/
  app.py            FastAPI app + REST endpoints
  aria2_client.py   aria2 JSON-RPC client
  kodi_client.py    Kodi JSON-RPC client
  config.py         env-backed config
  requirements.txt
frontend/
  src/              React components (App, Library, Downloads, Player) + api.js
  vite.config.js    dev proxy to the backend; build → frontend/dist
```

## Setup

### Prerequisites

- aria2, Kodi (with the web server / JSON-RPC enabled), Node.js, and
  [uv](https://docs.astral.sh/uv/) (or any Python venv tool)
- In Kodi: **Settings → Services → Control** → enable "Allow remote control via
  HTTP", set a username/password.

### 1. Configure

```bash
cp .env.example .env
# edit .env: set ARIA2_TOKEN, KODI_USER/KODI_PASS, DOWNLOAD_DIR
```

### 2. Backend

```bash
cd backend
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt
```

### 3. Frontend

```bash
cd frontend
npm install
npm run build        # outputs frontend/dist, served by the backend
```

### 4. Run

```bash
cd backend
.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

Open `http://<box-ip>:8000`.

For development with hot reload, run `npm run dev` in `frontend/` (it proxies
`/api` to the backend on :8000).

### aria2 daemon

Run aria2 with RPC enabled, pointing at your download directory. Example
`~/.aria2/aria2.conf`:

```ini
enable-rpc=true
rpc-listen-port=6800
rpc-secret=YOUR_TOKEN
dir=/home/you/Downloads
continue=true
save-session=/home/you/.aria2/aria2.session
input-file=/home/you/.aria2/aria2.session
```

> Avoid `force-save=true`: it leaves `.aria2` control files on completed
> downloads, which the library scanner treats as still-downloading and hides.

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
ExecStart=%h/Interlace/backend/.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
Restart=on-failure
[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now aria2.service interlace.service
loginctl enable-linger "$USER"   # keep services running without an active login
```

## Configuration reference

| Variable        | Description                          |
| --------------- | ------------------------------------ |
| `ARIA2_RPC_URL` | aria2 JSON-RPC endpoint              |
| `ARIA2_TOKEN`   | aria2 `rpc-secret` token             |
| `KODI_RPC_URL`  | Kodi JSON-RPC endpoint               |
| `KODI_USER`     | Kodi web server username             |
| `KODI_PASS`     | Kodi web server password             |
| `DOWNLOAD_DIR`  | directory aria2 saves to / scanned   |
| `CONSOLE_HOST`  | bind host (default `0.0.0.0`)        |
| `CONSOLE_PORT`  | bind port (default `8000`)           |
| `INTERLACE_VERSION` | reported service version (default `0.1.0-dev`) |

## Diagnostic Utility

Interlace includes a built-in "doctor" diagnostic script to verify your system setup, environment variables, systemd services, directory write permissions, and connectivity to aria2 and Kodi.

To run diagnostics:

```bash
npm run doctor
```

---

Intended for a trusted LAN. There's no auth on the console itself — don't expose
port 8000 directly to the internet.

## Audio / HDMI troubleshooting

**Symptom:** video plays on the TV over HDMI, but audio comes from the laptop's
built-in speakers.

This is a Linux audio routing problem — Kodi ends up talking to the wrong sound
card. On a MacBook Air running Ubuntu with PipeWire, the chain is:

```
Kodi → PipeWire (PIPEWIRE sink) → WirePlumber → correct ALSA sink
```

When any link in that chain breaks, audio falls back to the internal speakers.

Run `npm run doctor` — it checks most of what's listed below automatically.

### 1. User must be in the `audio` group

Without this, WirePlumber can't access `/dev/snd/*` and sees no hardware sinks
(only the `auto_null` dummy), so everything plays locally.

```bash
sudo usermod -aG audio $USER
# then reboot (or fully log out / log in)
```

### 2. Kodi must use the PIPEWIRE sink, not ALSA

Kodi's device validation silently falls back from `PIPEWIRE` to
`ALSA:sysdefault:CARD=Audio` (Apple T2 hardware) if it can't reach the
PipeWire-Pulse socket. Edit `~/.kodi/userdata/guisettings.xml`:

```xml
<setting id="audiooutput.audiodevice">PIPEWIRE:Default</setting>
```

Verify with `grep audiodevice ~/.kodi/userdata/guisettings.xml` — the value
must stay `PIPEWIRE:Default` after Kodi starts. If the Kodi log shows
`audio output device setting has been updated from 'PIPEWIRE:Default' to 'ALSA:…'`,
the next step is missing.

### 3. Kodi's systemd service must pass PipeWire environment

Kodi runs as a **system** service (`/etc/systemd/system/kodi.service`), so it
doesn't inherit the per-user `XDG_RUNTIME_DIR`. Without that, Kodi can't find
the PipeWire socket and falls back to raw ALSA hardware.

Add to `/etc/systemd/system/kodi.service` under `[Service]`:

```ini
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=PULSE_SERVER=unix:/run/user/%U/pulse/native
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart kodi
```

Verify Kodi is off the hardware:

```bash
ls -la /proc/$(pgrep -x kodi.bin)/fd | grep snd   # should be EMPTY
```

### 4. WirePlumber HDMI auto-priority

When the TV is turned on after playback has started, WirePlumber should switch
the default sink to HDMI so PipeWire can move the active stream.

Create `~/.config/wireplumber/wireplumber.conf.d/51-hdmi-default.conf` with a
rule that gives HDMI sinks higher priority than built-in speakers. (Format
varies by WirePlumber version; 0.5.x may need JSON-style rules.)

Restart and verify:

```bash
systemctl --user restart wireplumber pipewire pipewire-pulse
pw-metadata | grep default.audio.sink   # should show hdmi-stereo when TV is on
```

### Other known pitfalls

- **aria2 `force-save=true`** — leaves `.aria2` control files on completed
  downloads, which the library scanner treats as still-downloading and hides.
  Use `save-session` + `input-file` instead.
- **Dotenv import name** — the pip package is `python-dotenv`, but the Python
  import is `import dotenv`. The `requirements.txt` must list `python-dotenv`.
- **`loginctl enable-linger`** — without this, user systemd services die when
  the SSH session ends. Required on headless boxes.
- **Kodi subtitle/audio delay** — JSON-RPC only exposes relative `+/-` step
  actions; absolute values can't be read or set. The UI shows estimated offsets.
- **Frontend build before restart** — `npm run restart` (and `npm run start`)
  now runs the doctor diagnostics first, then rebuilds the frontend and
  restarts the backend. Always use these instead of manually restarting the
  service.
