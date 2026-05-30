import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

ARIA2_RPC_URL = os.getenv("ARIA2_RPC_URL", "http://127.0.0.1:6800/jsonrpc")
ARIA2_TOKEN = os.getenv("ARIA2_TOKEN", "")
KODI_RPC_URL = os.getenv("KODI_RPC_URL", "http://127.0.0.1:8080/jsonrpc")
KODI_USER = os.getenv("KODI_USER", "kodi")
KODI_PASS = os.getenv("KODI_PASS", "")
DOWNLOAD_DIR = Path(os.getenv("DOWNLOAD_DIR", str(Path.home() / "Downloads")))
UPLOAD_TMP_DIR = Path(os.getenv("UPLOAD_TMP_DIR", str(DOWNLOAD_DIR / ".interlace-tmp")))
THUMBNAIL_CACHE_DIR = Path(os.getenv("THUMBNAIL_CACHE_DIR", str(DOWNLOAD_DIR / ".thumbnails")))
CONSOLE_HOST = os.getenv("CONSOLE_HOST", "0.0.0.0")
CONSOLE_PORT = int(os.getenv("CONSOLE_PORT", "8000"))
INTERLACE_VERSION = os.getenv("INTERLACE_VERSION", "0.1.0-dev")
