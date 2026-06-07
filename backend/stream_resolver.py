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
    value = url.strip()
    if "://" not in value and "." in value.split("/", 1)[0]:
        value = f"https://{value}"
    parsed = urlparse(value)
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


async def resolve_stream(url: str, quality: str = "1080p") -> dict:
    source_url = await validate_public_url(url)
    if is_direct_stream_url(source_url):
        return {"mode": "direct", "url": source_url, "title": "", "source": "direct", "quality": "source"}

    if config.YT_DLP_PATH:
        executable = shutil.which(config.YT_DLP_PATH)
        if executable is None:
            raise StreamResolutionError(
                f"yt-dlp was not found at the configured path ({config.YT_DLP_PATH})"
            )
        command = [executable]
    else:
        command = [sys.executable, "-m", "yt_dlp"]

    format_selector = {
        "compatible": "best[acodec!=none][vcodec!=none]/best",
        "720p": "bestvideo[height<=720][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=720]",
        "1080p": "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1080]",
    }.get(quality)
    if format_selector is None:
        raise StreamResolutionError("Unsupported stream quality")

    try:
        source_origin = f"{urlparse(source_url).scheme}://{urlparse(source_url).netloc}/"
        extra_args = [
            "--user-agent",
            config.STREAM_USER_AGENT,
            "--referer",
            source_origin,
        ]
        if config.STREAM_COOKIES_FILE:
            extra_args.extend(["--cookies", config.STREAM_COOKIES_FILE])
        process = await asyncio.create_subprocess_exec(
            *command,
            "--dump-single-json",
            "--no-playlist",
            "--no-warnings",
            "--format",
            format_selector,
            *extra_args,
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
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise StreamResolutionError("yt-dlp returned an invalid media URL") from exc

    headers = dict(info.get("http_headers") or {})
    headers.setdefault("User-Agent", config.STREAM_USER_AGENT)
    requested_formats = info.get("requested_formats") or []
    if len(requested_formats) >= 2:
        video = next((item for item in requested_formats if item.get("vcodec") != "none"), None)
        audio = next((item for item in requested_formats if item.get("acodec") != "none"), None)
        if video and audio:
            video_url = await validate_public_url(video["url"])
            audio_url = await validate_public_url(audio["url"])
            height = video.get("height")
            return {
                "mode": "relay",
                "video_url": video_url,
                "audio_url": audio_url,
                "headers": headers,
                "title": str(info.get("title") or ""),
                "source": str(info.get("extractor_key") or info.get("extractor") or "yt-dlp"),
                "quality": f"{height}p" if height else quality,
            }

    try:
        media_url = await validate_public_url(info["url"])
    except (KeyError, TypeError) as exc:
        raise StreamResolutionError("yt-dlp returned an invalid media URL") from exc
    return {
        "mode": "direct",
        "url": _kodi_url_with_headers(media_url, headers),
        "title": str(info.get("title") or ""),
        "source": str(info.get("extractor_key") or info.get("extractor") or "yt-dlp"),
        "quality": f"{info.get('height')}p" if info.get("height") else quality,
    }
