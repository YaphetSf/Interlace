# Interlace

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The self-hosted API behind Incandenza's TV page. Incandenza on iPhone, Mac and
Apple Watch controls aria2 downloads and Kodi playback on a Linux media box;
Apple Watch requests go through the iPhone. The native apps use the
`InterlaceClient/` Swift package.

- **Downloads** — add a magnet / HTTP link or upload a `.torrent`; it downloads
  via [aria2](https://aria2.github.io/) with live progress.
- **Playback** — browse the library and play files on the TV via
  [Kodi](https://kodi.tv/)'s JSON-RPC, with full transport controls.
- **Online streams** — paste a direct media URL or a website supported by
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) and play it on Kodi without first
  downloading the complete video.

## Quick start

```bash
# 1. Configure
cp .env.example .env
# edit .env: set PERSON_KEYS_SHA256, ARIA2_TOKEN, KODI_USER/KODI_PASS, DOWNLOAD_DIR

# 2. Backend
cd backend
uv sync

# 3. Run
uv run python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

Set Incandenza's TV service base URL to `http://<box-ip>:8000` and use the
household person key. See the key setup below.

For production, run both aria2 and Interlace as systemd user services (see
below).

## Architecture

```
Incandenza (iPhone / Mac / Apple Watch via iPhone)
        │ HTTP + person key, over LAN or a private network
        ▼
  Interlace  (FastAPI, :8000)  — REST API
        ├──► aria2 JSON-RPC   (127.0.0.1:6800)   add / list / control downloads
        ├──► library scan                         list playable videos
        └──► Kodi JSON-RPC    (127.0.0.1:8080)   Player.Open + playback control
```

Kodi runs in the GNOME desktop as the on-TV renderer. Interlace talks to it only
over JSON-RPC. Incandenza uses the API — never talks directly to aria2,
Kodi, or the filesystem.

## Features

- Add downloads by magnet/URL or `.torrent` upload; pause, resume, remove
- Library listing with directory navigation, file upload and delete
- Playback: seek, play/pause, stop, volume, mute
- Online playback from direct MP4/WebM/HLS/DASH URLs and yt-dlp-supported sites
- 720p/1080p website playback via an ffmpeg copy-mux relay (no video re-encoding)

High-quality relay playback is progressive: play/pause/stop work, but duration
and seeking depend on Kodi's handling of the live Matroska stream. Use
`compatible` quality when reliable seeking is more important than resolution.
- Audio-track and video-stream selection
- Subtitle selection (including off), subtitle upload, audio/subtitle delay
- `npm run doctor` — built-in diagnostics for env, systemd services, disk,
  connectivity, and audio routing

## Tech stack

| Component | Technology |
|---|---|
| Backend | FastAPI + httpx (Python ≥ 3.12) |
| Services | aria2 and interlace as systemd user services |
| Client | Incandenza via the `InterlaceClient/` Swift package |

## Project layout

```
backend/
  app.py              FastAPI app + REST API
  aria2_client.py     aria2 JSON-RPC client
  kodi_client.py      Kodi JSON-RPC client
  config.py           env-backed configuration
  doctor.py           CLI diagnostics
  pyproject.toml      Python project metadata + ruff config
  tests/              pytest suite
InterlaceClient/     Swift API package used by Incandenza
```

## Person keys

Copy each household person's `key_sha256` value from Incandenza's
`hub/fleet.toml` `[[person]]` entries into the project `.env`, separated by commas:

```env
PERSON_KEYS_SHA256=<first key_sha256>,<second key_sha256>
```

These are SHA-256 hex digests, not the person keys themselves. Whitespace and
hex case are normalized; invalid digest entries are ignored. An unset or empty
list, or one with no valid digests, refuses every authenticated request. Restart
Interlace after changing the list.

Incandenza sends the person's existing key on each request:

```http
Authorization: Bearer <person key>
```

Interlace compares `sha256(key.strip())` against the configured digests with
`hmac.compare_digest`. A missing or incorrect key returns HTTP 401 with a JSON
`detail`. All configured people have the same access.

Only `GET /api/health` is public. Kodi fetches
`GET` / `HEAD /api/stream/relay/{token}` without a header; those routes accept
only loopback peers and return HTTP 403 otherwise. Keep
`STREAM_RELAY_BASE_URL=http://127.0.0.1:8000`.

```bash
curl http://<box-ip>:8000/api/health
curl -H "Authorization: Bearer $PERSON_KEY" http://<box-ip>:8000/api/status
```

## Configuration reference

| Variable | Description |
|---|---|
| `PERSON_KEYS_SHA256` | comma-separated household person-key SHA-256 hex digests; empty refuses authenticated requests |
| `ARIA2_RPC_URL` | aria2 JSON-RPC endpoint |
| `ARIA2_TOKEN` | aria2 `rpc-secret` token |
| `KODI_RPC_URL` | Kodi JSON-RPC endpoint |
| `KODI_USER` | Kodi web server username |
| `KODI_PASS` | Kodi web server password |
| `DOWNLOAD_DIR` | directory aria2 saves to / library scans |
| `YT_DLP_PATH` | optional yt-dlp executable override; defaults to the installed Python module |
| `STREAM_RESOLVE_TIMEOUT` | website URL resolution timeout in seconds |
| `STREAM_USER_AGENT` | browser User-Agent used when resolving website videos |
| `STREAM_COOKIES_FILE` | optional Netscape cookies file for authenticated sites |
| `FFMPEG_PATH` | optional ffmpeg override; defaults to the bundled binary |
| `FFMPEG_RUNTIME_DIR` | local no-root ffmpeg runtime directory |
| `STREAM_RELAY_BASE_URL` | loopback URL Kodi uses to reach Interlace's local stream relay (default `http://127.0.0.1:8000`) |
| `STREAM_RELAY_TTL` | seconds an unused relay URL remains valid |
| `STREAM_RELAY_INITIAL_BUFFER` | seconds of initial high-quality stream buffer |
| `STREAM_RELAY_READ_RATE` | relay input speed multiplier; values above 1 let the buffer recover after network stalls |
| `CONSOLE_HOST` | bind host (default `0.0.0.0`) |
| `CONSOLE_PORT` | bind port (default `8000`) |
| `INTERLACE_VERSION` | reported service version |

## NPM scripts

| Script | What it does |
|---|---|
| `npm run doctor` | Run system diagnostics (env, services, disk, audio) |
| `npm run lint:backend` | ruff check |
| `npm run lint:backend:fix` | ruff check with auto-fix |
| `npm run test:backend` | Run the pytest suite |
| `npm run ci` | lint + test |
| `npm run restart` | doctor → restart aria2, backend and Kodi |
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
Description=Interlace media API
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

### Kodi

Kodi runs inside the GNOME session as the user service `interlace-kodi-desktop.service`
(Wayland, fullscreen on the TV), started after GDM auto-login. It inherits the session's
PipeWire, so it needs no audio environment of its own. Machine setup: [SERVER.md](SERVER.md).

Ctrl+Alt+K on the box's own keyboard shows or hides Kodi, even offline:
`scripts/local-rescue-hotkey.py`, installed by `systemd/interlace-local-rescue.service`.
Kodi's user service is `systemd/interlace-kodi-desktop.service`.

## API

The REST API is Incandenza's control plane. Base URL can be a LAN IP, `.local`
hostname, Tailscale MagicDNS name, or private reverse proxy. Requests require a
person key except for the health check and loopback-only Kodi relay.

### Discovery

- `GET /api/health` — liveness check
- `GET /api/version` — service name and version
- `GET /api/capabilities` — feature flags, connection modes and bearer authentication requirements
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

For 720p/1080p website streams, install ffmpeg system-wide or create the local
runtime without root access:

```bash
bash scripts/install-ffmpeg-runtime.sh
```

#### Bilibili login cookies

Bilibili limits anonymous playback to lower resolutions. A logged-in standard
account can access normal 1080p when the video provides it. 1080P high bitrate
and 4K may still require a premium account.

1. Log into Bilibili in a browser and export cookies for `.bilibili.com` in
   Netscape `cookies.txt` format.
2. Save the exported file at:

   ```text
   backend/.secrets/bilibili-cookies.txt
   ```

3. Restrict access to the file:

   ```bash
   chmod 600 backend/.secrets/bilibili-cookies.txt
   ```

4. Add its absolute path to the project `.env`:

   ```env
   STREAM_COOKIES_FILE=/home/you/Interlace/backend/.secrets/bilibili-cookies.txt
   ```

5. Restart Interlace:

   ```bash
   systemctl --user restart interlace.service
   ```

The `backend/.secrets/` directory is ignored by Git. Cookies are equivalent to
login credentials: never commit, publish, or share this file.

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
3. **WirePlumber HDMI priority** — create a rule at `~/.config/wireplumber/wireplumber.conf.d/51-hdmi-default.conf` that gives HDMI sinks higher priority than built-in speakers

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

RPC checks can all pass while the TV shows nothing, so `npm run doctor`'s **Display & Kodi
Video Output** section reads the kernel's DRM connectors and Kodi's log instead. Restart Kodi
with `systemctl --user restart interlace-kodi-desktop`. Full checklist: SERVER.md.

## Known limitations

- **Subtitle/audio delay** — Kodi's JSON-RPC only exposes relative `+/-` step
  actions; absolute values can't be read or set.
- **`python-dotenv` vs `import dotenv`** — the pip package is `python-dotenv`;
  the Python import is `dotenv`.

## License

MIT — see [LICENSE](LICENSE).
