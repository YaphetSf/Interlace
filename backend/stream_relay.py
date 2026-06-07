import asyncio
import os
import secrets
import shutil
import time
from collections.abc import AsyncIterator
from pathlib import Path

import config


class StreamRelayError(RuntimeError):
    pass


_relays: dict[str, tuple[float, dict]] = {}
_relay_gates: dict[str, asyncio.Event] = {}


def register_relay(stream: dict) -> str:
    now = time.monotonic()
    expired = [token for token, (created, _) in _relays.items() if now - created > config.STREAM_RELAY_TTL]
    for token in expired:
        _relays.pop(token, None)
        _relay_gates.pop(token, None)

    token = secrets.token_urlsafe(24)
    _relays[token] = (now, stream)
    gate = asyncio.Event()
    gate.set()
    _relay_gates[token] = gate
    return token


def relay_token_from_url(url: str) -> str | None:
    marker = "/api/stream/relay/"
    if marker not in url:
        return None
    token = url.split(marker, 1)[1].split("?", 1)[0].split("|", 1)[0]
    return token if token in _relays else None


def relay_paused(token: str) -> bool:
    gate = _relay_gates.get(token)
    return gate is not None and not gate.is_set()


def toggle_relay(token: str) -> bool:
    gate = _relay_gates.get(token)
    if gate is None:
        raise StreamRelayError("Stream relay not found")
    if gate.is_set():
        gate.clear()
        return True
    gate.set()
    return False


async def relay_stream(token: str) -> AsyncIterator[bytes]:
    entry = _relays.get(token)
    if entry is None:
        raise StreamRelayError("Stream relay not found")

    created, stream = entry
    if time.monotonic() - created > config.STREAM_RELAY_TTL:
        raise StreamRelayError("Stream relay has expired")

    env = None
    if config.FFMPEG_PATH:
        executable = shutil.which(config.FFMPEG_PATH)
    else:
        executable = shutil.which("ffmpeg")
        runtime_dir = config.FFMPEG_RUNTIME_DIR
        runtime_executable = runtime_dir / "usr" / "bin" / "ffmpeg"
        if executable is None and runtime_executable.is_file():
            executable = str(runtime_executable)
            runtime_lib = runtime_dir / "usr" / "lib" / "x86_64-linux-gnu"
            env = os.environ.copy()
            env["LD_LIBRARY_PATH"] = str(runtime_lib)
            env["PATH"] = f"{Path(executable).parent}:{env.get('PATH', '')}"
    if executable is None:
        raise StreamRelayError("ffmpeg was not found; run scripts/install-ffmpeg-runtime.sh")

    command = [executable, "-hide_banner", "-loglevel", "error", "-nostdin"]
    for media_url in (stream["video_url"], stream["audio_url"]):
        command.extend(["-readrate", "1", "-i", media_url])
    command.extend(
        [
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c",
            "copy",
            "-f",
            "matroska",
            "pipe:1",
        ]
    )

    process = await asyncio.create_subprocess_exec(
        *command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )
    gate = _relay_gates[token]
    try:
        while chunk := await process.stdout.read(64 * 1024):
            await gate.wait()
            yield chunk
        stderr = (await process.stderr.read()).decode(errors="replace").strip()
        returncode = await process.wait()
        if returncode != 0:
            raise StreamRelayError(stderr or f"ffmpeg exited with status {returncode}")
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()
