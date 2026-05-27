import logging
import shutil
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import config
from aria2_client import Aria2
from kodi_client import Kodi

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("interlace")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("starting interlace console, version=%s", config.INTERLACE_VERSION)
    yield
    logger.info("shutting down interlace console")
    await aria2.close()
    await kodi.close()


app = FastAPI(title="Interlace Console", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
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


class DeleteIn(BaseModel):
    path: str


class SeekIn(BaseModel):
    percentage: float


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
        "service": "interlace-console",
        "version": config.INTERLACE_VERSION,
    }


@app.get("/api/capabilities")
async def capabilities():
    return {
        "service": "interlace-console",
        "api": {
            "basePath": "/api",
            "auth": {
                "required": False,
                "pairing": False,
                "scheme": None,
            },
        },
        "clients": {
            "web": True,
            "nativeMobile": True,
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
        "service": "interlace-console",
        "version": config.INTERLACE_VERSION,
        "api": {
            "basePath": "/api",
            "requestBaseUrl": str(request.base_url).rstrip("/"),
        },
        "server": {
            "staticUi": DIST.exists(),
            "downloadDirConfigured": bool(config.DOWNLOAD_DIR),
            "downloadDirExists": config.DOWNLOAD_DIR.exists(),
        },
        "auth": {
            "required": False,
            "pairing": False,
        },
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
def upload_subtitle(video_path: str = Form(...), file: UploadFile = File(...)):
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
        if sub_ext not in {".srt", ".ass", ".vtt"}:
            raise HTTPException(status_code=400, detail="Invalid subtitle format. Only .srt, .ass, and .vtt are allowed.")
            
        # Save subtitle with identical base name alongside the video
        target_sub_path = video_p.with_suffix(sub_ext)
        with target_sub_path.open("wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
            
        return {"ok": True, "filename": target_sub_path.name}
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
        
        # Security: Prevent directory traversal (ensure target is strictly inside download dir)
        if root not in target_path.parents:
            raise HTTPException(status_code=403, detail="Access denied: File outside download directory.")
            
        if not target_path.exists() or not target_path.is_file():
            raise HTTPException(status_code=404, detail="File not found.")
            
        target_path.unlink()
        return {"ok": True}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ---------- playback ----------
@app.post("/api/play")
async def play(body: PlayIn):
    try:
        await kodi.play_file(body.path)
        return {"ok": True}
    except Exception as e:
        logger.error("kodi play_file failed: %s", e)
        raise HTTPException(502, f"kodi: {e}")


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


# ---------- static assets and frontend ----------
app.mount("/videos", StaticFiles(directory=str(config.DOWNLOAD_DIR)), name="videos")

DIST = Path(__file__).resolve().parent.parent / "frontend" / "dist"
ASSETS = DIST / "assets"
if DIST.exists():
    if ASSETS.exists():
        app.mount(
            "/assets",
            StaticFiles(directory=str(ASSETS)),
            name="assets",
        )
    app.mount("/", StaticFiles(directory=str(DIST), html=True), name="static")


@app.middleware("http")
async def cache_headers(request: Request, call_next):
    response = await call_next(request)
    path = request.url.path
    if path.startswith("/assets/"):
        response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    elif path == "/" or request.url.path.endswith(".html"):
        response.headers["Cache-Control"] = "no-cache"
    return response
