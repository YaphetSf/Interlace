import asyncio
import codecs
import hashlib
import hmac
import logging
import re
import shutil
import tempfile
import time
from contextlib import asynccontextmanager
from ipaddress import IPv6Address, ip_address
from pathlib import Path
from urllib.parse import quote

import psutil
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

import config
from aria2_client import Aria2
from kodi_client import Kodi
from stream_relay import StreamRelayError, register_relay, relay_playback_url, relay_stream
from stream_resolver import StreamResolutionError, resolve_stream

# (timestamp, bytes_recv, bytes_sent) for network speed delta
_net_snapshot: tuple[float, int, int] | None = None

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("interlace")

_SUBTITLE_ENCODINGS = ("utf-8-sig", "gb18030", "big5", "cp1252", "latin-1")


def _decode_subtitle_to_utf8(raw: bytes) -> str:
    for bom, encoding in (
        (codecs.BOM_UTF32_LE, "utf-32"),
        (codecs.BOM_UTF32_BE, "utf-32"),
        (codecs.BOM_UTF16_LE, "utf-16"),
        (codecs.BOM_UTF16_BE, "utf-16"),
    ):
        if raw.startswith(bom):
            return raw.decode(encoding)

    sample = raw[:512]
    if len(sample) >= 16:
        even = sample[::2].count(0) / len(sample[::2])
        odd = sample[1::2].count(0) / len(sample[1::2])
        if odd > 0.3 and even < 0.05:
            return raw.decode("utf-16-le")
        if even > 0.3 and odd < 0.05:
            return raw.decode("utf-16-be")

    for encoding in _SUBTITLE_ENCODINGS:
        try:
            text = raw.decode(encoding)
        except UnicodeDecodeError:
            continue
        if "\x00" in text:
            raise UnicodeError("Subtitle contains NUL characters")
        return text
    return raw.decode("utf-8", errors="replace")


def configure_upload_temp_dir():
    upload_tmp_dir = config.UPLOAD_TMP_DIR.resolve()
    upload_tmp_dir.mkdir(parents=True, exist_ok=True)
    tempfile.tempdir = str(upload_tmp_dir)
    logger.info("using upload temp dir %s", upload_tmp_dir)


@asynccontextmanager
async def lifespan(app: FastAPI):
    configure_upload_temp_dir()
    logger.info("starting interlace, version=%s", config.INTERLACE_VERSION)
    yield
    logger.info("shutting down interlace")
    await aria2.close()
    await kodi.close()


app = FastAPI(title="Interlace API", lifespan=lifespan, docs_url=None, redoc_url=None)


@app.middleware("http")
async def require_person_key(request: Request, call_next):
    if request.method == "GET" and request.url.path == "/api/health":
        return await call_next(request)

    if request.method in {"GET", "HEAD"} and re.fullmatch(r"/api/stream/relay/[^/]+", request.url.path):
        try:
            peer = ip_address(request.client.host) if request.client else None
        except ValueError:
            peer = None
        if isinstance(peer, IPv6Address) and peer.ipv4_mapped is not None:
            peer = peer.ipv4_mapped
        if peer is None or not peer.is_loopback:
            return JSONResponse({"detail": "Stream relay requires a loopback peer"}, status_code=403)
        return await call_next(request)

    scheme, _, key = request.headers.get("Authorization", "").partition(" ")
    if scheme.lower() == "bearer" and key.strip():
        digest = hashlib.sha256(key.strip().encode("utf-8")).hexdigest()
        if any(hmac.compare_digest(digest, configured) for configured in config.PERSON_KEYS_SHA256):
            return await call_next(request)
    return JSONResponse(
        {"detail": "Invalid or missing person key"},
        status_code=401,
        headers={"WWW-Authenticate": "Bearer"},
    )


aria2 = Aria2()
kodi = Kodi()

VIDEO_EXT = {
    ".mkv", ".mp4", ".avi", ".mov", ".m4v", ".ts", ".m2ts",
    ".webm", ".flv", ".wmv", ".mpg", ".mpeg",
}


class UriIn(BaseModel):
    uri: str


class PlayIn(BaseModel):
    path: str


class StreamIn(BaseModel):
    url: str
    quality: str = "1080p"


class DeleteIn(BaseModel):
    path: str


class SeekIn(BaseModel):
    percentage: float


class SkipIn(BaseModel):
    seconds: int


class IndexIn(BaseModel):
    index: int


class SubIn(BaseModel):
    value: str | int


class VolIn(BaseModel):
    level: int


class MuteIn(BaseModel):
    muted: bool


class DelayIn(BaseModel):
    direction: str  # "minus" | "plus"


@app.get("/api/health")
async def health():
    return {"ok": True}


@app.get("/api/version")
async def version():
    return {
        "service": "interlace",
        "version": config.INTERLACE_VERSION,
    }


@app.get("/api/capabilities")
async def capabilities():
    return {
        "service": "interlace",
        "api": {
            "basePath": "/api",
            "auth": {
                "required": True,
                "pairing": False,
                "scheme": "bearer",
            },
        },
        "connectionModes": [
            "lan",
            "private_network",
            "private_reverse_proxy",
        ],
        "features": {
            "downloads": {
                "addUri": True,
                "addTorrent": True,
                "uploadFile": True,
                "pauseResumeRemove": True,
            },
            "library": {
                "scanDownloadDir": True,
                "playLocalFile": True,
            },
            "playback": {
                "streamUrl": True,
                "websiteUrlResolution": True,
                "streamQualities": ["compatible", "720p", "1080p"],
                "playPauseStop": True,
                "seek": True,
                "volume": True,
                "mute": True,
                "audioStreams": True,
                "videoStreams": True,
                "subtitles": True,
                "audioDelay": True,
                "subtitleDelay": True,
            },
            "discovery": {
                "bonjour": False,
                "manualBaseUrl": True,
            },
        },
    }


@app.get("/api/status")
async def status(request: Request):
    return {
        "ok": True,
        "service": "interlace",
        "version": config.INTERLACE_VERSION,
        "api": {
            "basePath": "/api",
            "requestBaseUrl": str(request.base_url).rstrip("/"),
        },
        "server": {
            "downloadDirConfigured": bool(config.DOWNLOAD_DIR),
            "downloadDirExists": config.DOWNLOAD_DIR.exists(),
        },
        "auth": {
            "required": True,
            "pairing": False,
            "scheme": "bearer",
        },
    }


# ---------- system stats ----------
@app.get("/api/system")
async def system_stats():
    global _net_snapshot

    cpu_percent = psutil.cpu_percent(interval=None)

    # CPU temperature — try psutil first, then ARM thermal sysfs fallback
    cpu_temp = None
    try:
        temps = psutil.sensors_temperatures()
        if temps:
            for entries in temps.values():
                for entry in entries:
                    if entry.current and entry.current > 0:
                        cpu_temp = round(entry.current, 1)
                        break
                if cpu_temp is not None:
                    break
    except Exception:
        pass

    if cpu_temp is None:
        for i in range(10):
            try:
                raw = Path(f"/sys/class/thermal/thermal_zone{i}/temp").read_text().strip()
                val = int(raw)
                cpu_temp = round(val / 1000.0 if val > 1000 else float(val), 1)
                break
            except Exception:
                continue

    mem = psutil.virtual_memory()

    net = psutil.net_io_counters()
    now = time.monotonic()
    download_speed = 0
    upload_speed = 0
    if _net_snapshot is not None:
        last_time, last_recv, last_sent = _net_snapshot
        dt = now - last_time
        if dt > 0.1:
            download_speed = max(0, int((net.bytes_recv - last_recv) / dt))
            upload_speed = max(0, int((net.bytes_sent - last_sent) / dt))
    _net_snapshot = (now, net.bytes_recv, net.bytes_sent)

    uptime = int(time.time() - psutil.boot_time())

    return {
        "cpu": {
            "percent": cpu_percent,
            "temp": cpu_temp,
        },
        "memory": {
            "total": mem.total,
            "used": mem.used,
            "free": mem.available,
            "percent": round(mem.percent, 1),
        },
        "network": {
            "download_speed": download_speed,
            "upload_speed": upload_speed,
        },
        "uptime": uptime,
    }


# ---------- downloads ----------
@app.get("/api/downloads")
async def list_downloads():
    try:
        return await aria2.all_downloads()
    except Exception as e:
        logger.error("aria2 list_downloads failed: %s", e)
        raise HTTPException(502, f"aria2: {e}")


@app.post("/api/downloads")
async def add_download(body: UriIn):
    try:
        return {"gid": await aria2.add_uri(body.uri.strip())}
    except Exception as e:
        logger.error("aria2 add_uri failed: %s", e)
        raise HTTPException(502, f"aria2: {e}")


@app.post("/api/downloads/torrent")
async def add_torrent(file: UploadFile = File(...)):
    try:
        return {"gid": await aria2.add_torrent(await file.read())}
    except Exception as e:
        logger.error("aria2 add_torrent failed: %s", e)
        raise HTTPException(502, f"aria2: {e}")


@app.post("/api/upload")
def upload_file(path: str = Form(""), file: UploadFile = File(...)):
    try:
        root = config.DOWNLOAD_DIR.resolve()
        target_dir = root
        if path:
            target_dir = (root / path.strip("/")).resolve()
            # Security: Prevent directory traversal
            if root not in target_dir.parents and root != target_dir:
                raise HTTPException(status_code=403, detail="Access denied: Upload path outside download directory.")
                
        # Resolve full path inside target directory, preserving directory structure if file.filename has relative path parts
        safe_rel_path = Path(file.filename)
        # Prevent any relative directory traversal in the filename itself
        clean_parts = [part for part in safe_rel_path.parts if part not in ("..", ".", "/")]
        if not clean_parts:
            raise HTTPException(status_code=400, detail="Invalid file name.")
            
        target_path = (target_dir / Path(*clean_parts)).resolve()
        # Security check on final resolved target path
        if root not in target_path.parents:
            raise HTTPException(status_code=403, detail="Access denied: File destination outside download directory.")
            
        target_path.parent.mkdir(parents=True, exist_ok=True)
        with target_path.open("wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        return {"ok": True, "filename": str(target_path.relative_to(root))}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/upload/subtitle")
async def upload_subtitle(video_path: str = Form(...), file: UploadFile = File(...)):
    try:
        video_p = Path(video_path).resolve()
        root = config.DOWNLOAD_DIR.resolve()
        
        # Security: Prevent directory traversal
        if root not in video_p.parents:
            raise HTTPException(status_code=403, detail="Access denied: Video outside download directory.")
            
        if not video_p.exists():
            raise HTTPException(status_code=404, detail="Video file not found.")
            
        # Validate extension
        sub_ext = Path(file.filename).suffix.lower()
        if sub_ext not in {".srt", ".ass", ".ssa", ".vtt"}:
            raise HTTPException(status_code=400, detail="Invalid subtitle format. Only .srt, .ass, .ssa, and .vtt are allowed.")
            
        # Save subtitle with identical base name alongside the video
        target_sub_path = video_p.with_suffix(sub_ext)
        try:
            text = _decode_subtitle_to_utf8(await file.read())
        except UnicodeError as e:
            raise HTTPException(status_code=400, detail=f"Invalid subtitle encoding: {e}")
        with target_sub_path.open("wb") as buffer:
            await run_in_threadpool(buffer.write, text.encode("utf-8"))

        try:
            activated = await kodi.add_subtitle(str(video_p), str(target_sub_path))
        except Exception as e:
            logger.warning("subtitle saved but Kodi could not load %s: %s", target_sub_path, e)
            activated = False

        return {"ok": True, "filename": target_sub_path.name, "activated": activated}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/downloads/{gid}/pause")
async def pause_dl(gid: str):
    try:
        await aria2.pause(gid)
    except Exception as e:
        logger.error("aria2 pause gid=%s failed: %s", gid, e)
        raise HTTPException(502, f"aria2: {e}")
    return {"ok": True}


@app.post("/api/downloads/{gid}/resume")
async def resume_dl(gid: str):
    try:
        await aria2.unpause(gid)
    except Exception as e:
        logger.error("aria2 resume gid=%s failed: %s", gid, e)
        raise HTTPException(502, f"aria2: {e}")
    return {"ok": True}


@app.delete("/api/downloads/{gid}")
async def remove_dl(gid: str):
    try:
        await aria2.remove(gid)
    except Exception as e:
        logger.error("aria2 remove gid=%s failed: %s", gid, e)
        raise HTTPException(502, f"aria2: {e}")
    return {"ok": True}


# ---------- thumbnails ----------

def _thumbnail_cache_path(video_path: Path) -> Path:
    """Return a stable cache path for a video file."""
    h = hashlib.md5(str(video_path).encode()).hexdigest()
    return config.THUMBNAIL_CACHE_DIR / f"{h}.jpg"


async def _generate_thumbnail(video_path: Path) -> Path | None:
    """Extract a frame at 15s from video_path, save as jpg. Returns cache path or None."""
    cache_path = _thumbnail_cache_path(video_path)
    if cache_path.exists():
        return cache_path
    config.THUMBNAIL_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-ss", "15", "-i", str(video_path),
            "-vframes", "1", "-q:v", "5",
            str(cache_path), "-y",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        if proc.returncode == 0 and cache_path.exists():
            return cache_path
    except Exception:
        pass
    return None


@app.get("/api/thumbnail")
async def thumbnail(path: str):
    """Serve a lazily-generated thumbnail for a video file."""
    video_path = Path(path).resolve()
    root = config.DOWNLOAD_DIR.resolve()
    if root not in video_path.parents:
        raise HTTPException(status_code=403, detail="Access denied")
    if not video_path.is_file():
        raise HTTPException(status_code=404, detail="Video not found")
    result = await _generate_thumbnail(video_path)
    if result is None:
        raise HTTPException(status_code=404, detail="Thumbnail could not be generated")
    return FileResponse(result, media_type="image/jpeg")


# ---------- library ----------
@app.get("/api/library")
async def library(path: str = ""):
    root = config.DOWNLOAD_DIR.resolve()
    target_dir = root
    if path:
        target_dir = (root / path.strip("/")).resolve()
        # Security: Prevent directory traversal
        if root not in target_dir.parents and root != target_dir:
            raise HTTPException(status_code=403, detail="Access denied: Path outside download directory.")
            
    items = []
    if target_dir.exists() and target_dir.is_dir():
        for p in sorted(target_dir.iterdir()):
            if p.is_dir():
                # Check recursively if the directory contains at least one video file
                def has_videos(d: Path) -> bool:
                    try:
                        for child in d.rglob("*"):
                            if child.is_file() and child.suffix.lower() in VIDEO_EXT and not child.with_name(child.name + ".aria2").exists():
                                return True
                    except Exception:
                        pass
                    return False
                
                if has_videos(p):
                    items.append(
                        {
                            "name": p.name,
                            "type": "directory",
                            "path": str(p),
                            "rel": str(p.relative_to(root)),
                        }
                    )
            elif p.is_file():
                if p.suffix.lower() not in VIDEO_EXT:
                    continue
                if p.with_name(p.name + ".aria2").exists():
                    continue  # still downloading
                items.append(
                    {
                        "name": p.name,
                        "type": "file",
                        "path": str(p),
                        "rel": str(p.relative_to(root)),
                        "size": p.stat().st_size,
                        "thumbnail": f"/api/thumbnail?path={quote(str(p))}",
                    }
                )
    # Calculate disk usage using shutil
    total, used, free = shutil.disk_usage(root) if root.exists() else (0, 0, 0)
    percent = round((used / total) * 100, 1) if total > 0 else 0.0
    return {
        "items": items,
        "disk": {
            "total": total,
            "used": used,
            "free": free,
            "percent": percent
        }
    }


@app.delete("/api/library")
async def delete_library_item(body: DeleteIn):
    try:
        root = config.DOWNLOAD_DIR.resolve()
        target_path = Path(body.path).resolve()
        
        # Security: Prevent directory traversal (ensure target is strictly inside
        # download dir). This also forbids deleting the download root itself.
        if root not in target_path.parents:
            raise HTTPException(status_code=403, detail="Access denied: Path outside download directory.")

        if not target_path.exists():
            raise HTTPException(status_code=404, detail="Path not found.")

        if target_path.is_dir():
            # Recursively remove the whole folder and everything inside it.
            shutil.rmtree(target_path)
        else:
            target_path.unlink()
        return {"ok": True}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ---------- playback ----------
@app.post("/api/play")
async def play(body: PlayIn):
    logger.info("play requested: path=%r", body.path)
    try:
        await kodi.play_file(body.path)
        return {"ok": True}
    except Exception as e:
        logger.error("kodi play_file failed for path=%r: %s", body.path, e)
        raise HTTPException(502, f"kodi: {e}")


@app.post("/api/stream")
async def stream(body: StreamIn):
    logger.info("stream requested: url=%r", body.url)
    try:
        resolved = await resolve_stream(body.url, body.quality)
        if resolved["mode"] == "relay":
            token = register_relay(resolved)
            playback_url = relay_playback_url(token)
        else:
            playback_url = resolved["url"]
        await kodi.play_stream(playback_url)
        return {
            "ok": True,
            "title": resolved["title"],
            "source": resolved["source"],
            "quality": resolved["quality"],
        }
    except StreamResolutionError as e:
        logger.warning("stream resolution failed for url=%r: %s", body.url, e)
        raise HTTPException(400, str(e))
    except Exception as e:
        logger.error("kodi play_stream failed for url=%r: %s", body.url, e)
        raise HTTPException(502, f"kodi: {e}")


@app.get("/api/stream/relay/{token}")
async def stream_relay(token: str):
    async def content():
        try:
            async for chunk in relay_stream(token):
                yield chunk
        except StreamRelayError as e:
            logger.warning("stream relay failed: %s", e)

    return StreamingResponse(content(), media_type="video/x-matroska")


@app.head("/api/stream/relay/{token}")
async def stream_relay_head(token: str):
    return Response(media_type="video/x-matroska")


@app.get("/api/player")
async def player():
    try:
        return await kodi.now_playing()
    except Exception as e:
        logger.error("kodi now_playing failed: %s", e)
        raise HTTPException(502, f"kodi: {e}")


@app.post("/api/player/playpause")
async def pp():
    try:
        await kodi.play_pause()
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/stop")
async def stop():
    try:
        await kodi.stop()
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/seek")
async def seek(body: SeekIn):
    try:
        await kodi.seek(body.percentage)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/skip")
async def skip(body: SkipIn):
    try:
        await kodi.skip(body.seconds)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/audio")
async def audio(body: IndexIn):
    try:
        await kodi.set_audio(body.index)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/video")
async def video(body: IndexIn):
    try:
        await kodi.set_video(body.index)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/subtitle")
async def subtitle(body: SubIn):
    try:
        await kodi.set_subtitle(body.value)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/volume")
async def volume(body: VolIn):
    try:
        await kodi.set_volume(body.level)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/mute")
async def mute(body: MuteIn):
    try:
        await kodi.set_mute(body.muted)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/subtitle-delay")
async def subtitle_delay(body: DelayIn):
    try:
        action = "subtitledelayminus" if body.direction == "minus" else "subtitledelayplus"
        await kodi.exec_action(action)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}


@app.post("/api/player/audio-delay")
async def audio_delay(body: DelayIn):
    try:
        action = "audiodelayminus" if body.direction == "minus" else "audiodelayplus"
        await kodi.exec_action(action)
    except Exception as e:
        raise HTTPException(502, f"kodi: {e}")
    return {"ok": True}
