import asyncio
import ipaddress
import json
import shutil
import socket
import sys
from pathlib import Path
from urllib.parse import quote, urlparse

import config

DIRECT_STREAM_EXTENSIONS = {
    ".aac",
    ".flac",
    ".m3u8",
    ".m4a",
    ".m4v",
    ".mkv",
    ".mp3",
    ".mp4",
    ".mpeg",
    ".mpd",
    ".ogg",
    ".ogv",
    ".opus",
    ".ts",
    ".webm",
}


class StreamResolutionError(RuntimeError):
    pass


def _is_public_ip(value: str) -> bool:
    ip = ipaddress.ip_address(value)
    return ip.is_global


async def validate_public_url(url: str) -> str:
    parsed = urlparse(url.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise StreamResolutionError("Only public HTTP and HTTPS URLs are supported")
    if parsed.username or parsed.password:
        raise StreamResolutionError("URLs containing credentials are not supported")

    hostname = parsed.hostname.rstrip(".").lower()
    if hostname == "localhost" or hostname.endswith(".local"):
        raise StreamResolutionError("Local and private network URLs are not allowed")

    try:
        if not _is_public_ip(hostname):
            raise StreamResolutionError("Local and private network URLs are not allowed")
    except ValueError:
        loop = asyncio.get_running_loop()
        try:
            addresses = await loop.getaddrinfo(hostname, parsed.port, type=socket.SOCK_STREAM)
        except socket.gaierror as exc:
            raise StreamResolutionError(f"Could not resolve host: {hostname}") from exc
        if not addresses or any(not _is_public_ip(item[4][0]) for item in addresses):
            raise StreamResolutionError("Local and private network URLs are not allowed")

    return parsed.geturl()


def is_direct_stream_url(url: str) -> bool:
    return Path(urlparse(url).path).suffix.lower() in DIRECT_STREAM_EXTENSIONS


def _kodi_url_with_headers(url: str, headers: dict[str, str]) -> str:
    allowed = {
        key: value
        for key, value in headers.items()
        if key.lower() in {"authorization", "cookie", "origin", "referer", "user-agent"}
    }
    if not allowed:
        return url
    encoded = "&".join(f"{quote(key)}={quote(str(value))}" for key, value in allowed.items())
    return f"{url}|{encoded}"


async def resolve_stream(url: str) -> dict[str, str]:
    source_url = await validate_public_url(url)
    if is_direct_stream_url(source_url):
        return {"url": source_url, "title": "", "source": "direct"}

    if config.YT_DLP_PATH:
        executable = shutil.which(config.YT_DLP_PATH)
        if executable is None:
            raise StreamResolutionError(
                f"yt-dlp was not found at the configured path ({config.YT_DLP_PATH})"
            )
        command = [executable]
    else:
        command = [sys.executable, "-m", "yt_dlp"]

    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            "--dump-single-json",
            "--no-playlist",
            "--no-warnings",
            "--format",
            "best[acodec!=none][vcodec!=none]/best",
            "--",
            source_url,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(
            process.communicate(), timeout=config.STREAM_RESOLVE_TIMEOUT
        )
    except TimeoutError as exc:
        process.kill()
        await process.wait()
        raise StreamResolutionError("Stream URL resolution timed out") from exc

    if process.returncode != 0:
        detail = stderr.decode(errors="replace").strip().splitlines()
        message = detail[-1] if detail else "yt-dlp could not resolve this URL"
        raise StreamResolutionError(message)

    try:
        info = json.loads(stdout)
        media_url = await validate_public_url(info["url"])
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise StreamResolutionError("yt-dlp returned an invalid media URL") from exc

    headers = info.get("http_headers") or {}
    return {
        "url": _kodi_url_with_headers(media_url, headers),
        "title": str(info.get("title") or ""),
        "source": str(info.get("extractor_key") or info.get("extractor") or "yt-dlp"),
    }
