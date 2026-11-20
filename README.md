# Interlace

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The self-hosted API behind Incandenza's TV page. Incandenza on iPhone and
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
# edit .env: set ARIA2_TOKEN, KODI_USER/KODI_PASS, DOWNLOAD_DIR

# 2. Backend
cd backend
uv sync

# 3. Run
uv run python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

Incandenza finds this URL as the `media` capability in its hub's `fleet.toml`
and sends its device key. See who gets in, below.

For production, run both aria2 and Interlace as systemd user services (see
below).

## Architecture

```
Incandenza (iPhone / Apple Watch via iPhone)
        │ HTTP + device key, over LAN or the gateway
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
  library.py          catalog scanning and SQLite progress / metadata cache
  tmdb.py             TMDB metadata and art client
  doctor.py           CLI diagnostics
  pyproject.toml      Python project metadata + ruff config
  tests/              pytest suite
InterlaceClient/     Swift API package used by Incandenza
```

## Who gets in

Interlace listens on every interface and serves requests carrying a valid
Incandenza device key, including requests from the home LAN and requests using a
hostname. Every API route, including `/api/health`, requires:

```http
Authorization: Bearer <key>
```

Missing, unknown or revoked keys return HTTP 401 with
`{"detail": "device key required"}`. The peer address, Host and `X-Incandenza`
header do not decide access.

The verifier reads `~/.config/incandenza/devices.toml` at startup and reloads it
when its mtime changes. Set `INCANDENZA_DEVICES` to use another path. The registry
stores each device's name, SHA-256 key hash and admin flag; Incandenza's hub owns
its add/revoke commands. Removing a device refuses its next request. A missing
or invalid registry refuses all device keys.

Kodi fetches `GET` / `HEAD /api/stream/relay/{token}` without a device key; those
routes accept only loopback peers and return HTTP 403 otherwise. Keep
`STREAM_RELAY_BASE_URL=http://127.0.0.1:8000`. The local doctor probe treats a
401 from `/api/health` as alive.

```bash
curl -H "Authorization: Bearer $INCANDENZA_KEY" http://<lan-ip>:8000/api/health
curl -H "Authorization: Bearer $INCANDENZA_KEY" http://<lan-ip>:8000/api/status
```

## Configuration reference

| Variable | Description |
|---|---|
| `INCANDENZA_DEVICES` | device registry path; defaults to `~/.config/incandenza/devices.toml` |
| `ARIA2_RPC_URL` | aria2 JSON-RPC endpoint |
| `ARIA2_TOKEN` | aria2 `rpc-secret` token |
| `KODI_RPC_URL` | Kodi JSON-RPC endpoint |
| `KODI_USER` | Kodi web server username |
| `KODI_PASS` | Kodi web server password |
| `DOWNLOAD_DIR` | directory aria2 saves to / library scans |
| `DATA_DIR` | catalog database (`library.db`) and art cache; defaults to `~/.local/share/interlace` |
| `TMDB_TOKEN` | TMDB API Read Access Token; empty serves parsed titles without art |
| `TMDB_LANGUAGE` | TMDB metadata language (default `en-US`) |
| `WATCHED_GRACE` | seconds a watched title stays on disk after it was last played or marked (default `21600`) |
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
| `CONSOLE_PORT` | the port `doctor` probes (the systemd unit binds `0.0.0.0:8000` itself) |
| `INTERLACE_VERSION` | reported service version |

## NPM scripts

| Script | What it does |
|---|---|
| `npm run doctor` | Run system diagnostics (env, services, disk, audio) |
| `npm run lint:backend` | ruff check |
| `npm run lint:backend:fix` | ruff check with auto-fix |
| `npm run test:backend` | Run the pytest suite |
| `npm run test:client` | Run the `InterlaceClient` Swift tests (macOS) |
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

The REST API is Incandenza's control plane. Use a LAN, tailnet or gateway base URL.
Requests carry the device key except for the loopback-only Kodi relay.

### Discovery

- `GET /api/health` — liveness check
- `GET /api/version` — service name and version
- `GET /api/capabilities` — feature flags, connection modes and header requirements
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
- `POST /api/upload/subtitle` — upload a subtitle beside `video_path`; without it, attach to what Kodi is playing (a stream's subtitle lives in `UPLOAD_TMP_DIR/subtitles` for a day)

### Catalog

Every visible top-level entry of `DOWNLOAD_DIR`, file or folder, is one title: a
show when any of its videos is named `SxxEyy`, otherwise a movie. Hidden entries
(leading `.`), entries without a finished video (a `.aria2` sibling hides a file)
and `sample` videos are left out. Metadata and art come from TMDB when
`TMDB_TOKEN` is set, otherwise from the parsed name. Clients never reach TMDB.

- `GET /api/catalog` — the unwatched titles on disk, newest first, their continue-watching row, and
  every watched title

```json
{
  "titles": [
    {
      "id": "The.Office.US.S02.1080p.BluRay.x265-RARBG",
      "kind": "show",
      "title": "The Office",
      "year": 2005,
      "overview": "A mockumentary on a group of typical office workers.",
      "tmdbId": 2316,
      "poster": true,
      "backdrop": true,
      "logo": true,
      "runtime": 22,
      "certification": "15",
      "genres": ["Comedy"],
      "crew": [{"personId": 35796, "name": "Greg Daniels", "job": "Creator", "profile": true}],
      "matched": "auto",
      "cast": [{"personId": 17419, "name": "Steve Carell", "character": "Michael Scott", "profile": true}],
      "added": 1763251200,
      "watched": null,
      "files": [
        {
          "path": "/downloads/The.Office.US.S02.1080p.BluRay.x265-RARBG/The.Office.US.S02E01.1080p.BluRay.x265-RARBG.mkv",
          "name": "The.Office.US.S02E01.1080p.BluRay.x265-RARBG.mkv",
          "size": 734003200,
          "season": 2,
          "episode": 1,
          "episodeTitle": "The Dundies",
          "episodeOverview": "Michael hosts the annual office awards at a local restaurant.",
          "airDate": "2005-09-20",
          "runtime": 22,
          "still": true,
          "media": {
            "duration": 1318.4,
            "video": {"codec": "hevc", "width": 1920, "height": 1080, "bitDepth": 10, "hdr": null},
            "audio": [{"codec": "aac", "channels": 2, "language": "eng", "title": null, "atmos": false, "default": true}],
            "subtitles": [{"codec": "subrip", "language": "eng", "title": "English", "forced": false}]
          },
          "subtitles": [
            {
              "path": "/downloads/The.Office.US.S02.1080p.BluRay.x265-RARBG/The.Office.US.S02E01.1080p.BluRay.x265-RARBG-cn.srt",
              "name": "The.Office.US.S02E01.1080p.BluRay.x265-RARBG-cn.srt",
              "label": "cn"
            }
          ],
          "progress": {"position": 754.2, "duration": 1320.0, "finished": false, "updated": 1763337600}
        }
      ]
    }
  ],
  "continue": [
    {
      "titleId": "The.Office.US.S02.1080p.BluRay.x265-RARBG",
      "path": "/downloads/The.Office.US.S02.1080p.BluRay.x265-RARBG/The.Office.US.S02E01.1080p.BluRay.x265-RARBG.mkv"
    }
  ],
  "watched": [
    {"id": "1917 (2019) [1080p] [BluRay] [5.1] [YTS.MX]", "kind": "movie", "title": "1917", "…": "…",
     "watched": 1763510400, "files": []}
  ]
}
```

| Field | Rule |
|---|---|
| `id` | the entry's name under `DOWNLOAD_DIR` |
| `kind` | `movie` or `show` |
| `title`, `year` | TMDB's when matched, else parsed from the name; `year` is null when there is none |
| `overview`, `tmdbId`, `episodeTitle` | null without a TMDB match |
| `poster`, `backdrop`, `logo` | whether `/api/art` has that image; `logo` is TMDB's English or language-neutral title logo |
| `runtime` | minutes: a movie's runtime, a show's usual episode length, an episode's own length; null when TMDB has none |
| `certification` | the United Kingdom rating (a movie's GB release date, a show's GB content rating), null when TMDB has none |
| `genres` | TMDB's genre names in TMDB's order, `[]` without a match |
| `crew` | at most three: a movie's directors (`job` `Director`), a show's creators (`job` `Creator`); `profile` as for `cast` |
| `matched` | `auto` when the server picked the TMDB entry, `manual` when a client set it with `POST /api/catalog/match`, null without a match |
| `cast` | TMDB's billing order, at most twelve; `profile` is whether `/api/art` has the person's photo |
| `episodeOverview`, `airDate`, `still` | the episode's TMDB overview, air date (`YYYY-MM-DD`) and whether `/api/art` has its still; null / false for files that are not a matched episode |
| `media` | what `ffprobe` reads from the file, cached by path, size and mtime; null until the file has been probed or when probing fails. `hdr` is `dolbyVision`, `hdr10plus`, `hdr10`, `hlg` or null, the best the file carries; `language` is the stream's ISO 639-2 tag or null; `atmos` marks a Dolby Atmos (TrueHD or E-AC-3 JOC) track |
| `added` | the entry's mtime, Unix seconds; titles sort by it, newest first |
| `watched` | once every video of a movie, or every episode of a show, is finished: the latest of those finishes, Unix seconds; null otherwise |
| `files` | a show's episodes by season and episode, then its unnumbered videos by name; a movie's videos by name; `[]` for a watched title whose files are gone |
| `season`, `episode` | from `SxxEyy`, null otherwise |
| `subtitles` | `.srt .ass .ssa .vtt` files in the video's folder whose name starts with the video's stem; `label` is what sits between the stem and the extension, leading `.`, `-`, `_` and spaces stripped, `""` when nothing is left |
| `progress` | the file's progress record, null when never played |
| `continue` | at most one per unwatched title, most recently played first: the last played file if unfinished, else the show's next file; a title whose last played file is finished with nothing after it is left out |
| `watched` (list) | watched titles, latest `watched` first: those still on disk with their files, and those whose files are gone |

- `GET /api/art?id=<title id>&kind=poster|backdrop|logo` — the title's cached image:
  poster `image/jpeg` 500 px wide, backdrop `image/jpeg` 1280 px wide, logo `image/png` 500 px wide
  with transparency; 404 when the title has none
- `GET /api/art?id=<title id>&kind=profile&person=<personId>` — a cast or crew member's photo,
  `image/jpeg` 185 px wide; only for a person in that title's `cast` or `crew`
- `GET /api/art?id=<title id>&kind=still&season=<n>&episode=<n>` — an episode still,
  `image/jpeg` 300 px wide; only for an episode in that title's `files`

Clients never reach TMDB: every image is fetched once by the server and served from its cache.

### Matching

A wrong automatic match is corrected by hand. A manual match outlives rescans and server restarts and
is keyed by the title `id`.

- `GET /api/catalog/search?id=<title id>&query=<text>` — TMDB candidates of the title's `kind`, at most
  ten in TMDB's order: `[{"tmdbId", "title", "year", "overview", "poster"}]`. `query` defaults to the
  title's current name; `year` and `overview` may be null; `poster` is whether `/api/catalog/poster` has one
- `GET /api/catalog/poster?id=<title id>&tmdbId=<n>` — a candidate's poster, `image/jpeg` 185 px wide;
  only for a `tmdbId` that the latest search for that title returned, 404 otherwise
- `POST /api/catalog/match` — `{"id", "tmdbId"}`; stores the manual match, refetches the title's details
  and artwork, and returns the updated title as in `/api/catalog`. A `tmdbId` TMDB does not know for the
  title's `kind` answers 404
- `DELETE /api/catalog/match` — `{"id"}`; drops the manual match, matches automatically again and
  returns the updated title

Watched titles match the same way.

### Watched

A watched title nobody has played or marked for `WATCHED_GRACE` seconds (default six hours) leaves the
disk: an hourly sweep deletes its entry under `DOWNLOAD_DIR` (a loose file with its sidecar subtitles),
skipping an entry aria2 is still writing, and keeps the title on the Watched shelf with its match and
artwork. A title downloaded again under the same name is listed from the disk.

- `POST /api/catalog/watched` — `{"id"}`; finishes every unfinished file of a title on disk at its known
  duration and returns `{"ok": true}`; 404 when no title on disk has that `id`
- `DELETE /api/catalog/watched` — `{"id"}`; forgets the progress of every file of a title on disk and
  returns `{"ok": true}`; 404 as above

### Progress

One record per file, shared by every device. `path` is a library video's absolute
path: outside `DOWNLOAD_DIR` answers 403, a missing file 404.

- `GET /api/progress?path=` — `{"path", "position", "duration", "finished", "updated"}`; 404 when the file has none
- `POST /api/progress` — `{"path", "position", "duration"}` in seconds; stores and returns the record.
  `finished` is `position >= 0.9 × duration`; `updated` is the server's Unix time
- `DELETE /api/progress` — `{"path"}`; forgets the record and returns `{"ok": true}`

### Subtitle choice

The subtitle picked for a file, shared by every device, with the same `path` rules as progress.
`subtitle` is one of:

| `subtitle` | Means |
|---|---|
| `{"kind": "off"}` | subtitles off |
| `{"kind": "sidecar", "label": "cn", "name": "…-cn.srt"}` | a sidecar from the catalog's `subtitles`: the file finds its own by `name` (optional), another file of the title the one with the same `label` |
| `{"kind": "stream", "index": 3, "language": "eng"}` | the embedded subtitle stream at this container stream index; `language` is optional |

- `GET /api/subtitle-choice?path=` — `{"path", "subtitle"}`: the file's own choice, else the latest made for
  another file of the same title, else `null`
- `POST /api/subtitle-choice` — `{"path", "subtitle"}`; stores and returns it

### Files

- `GET` / `HEAD /api/file?path=<absolute>` — the file's bytes for on-device playback,
  with `Range` requests (206, `Content-Range`, `Accept-Ranges: bytes`). Serves only
  videos and `.srt .ass .ssa .vtt` subtitles under `DOWNLOAD_DIR`: 403 outside it or
  for any other extension, 404 when missing. The device key goes in the
  `Authorization` header as on every other route.

`GET /api/capabilities` reports these as
`features.catalog: {"titles": true, "art": <TMDB_TOKEN set>, "progress": true, "fileStreaming": true}`.

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
