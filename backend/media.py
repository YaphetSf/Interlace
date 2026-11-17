"""Bounded ffprobe invocations and the catalog's stream metadata format."""

import json
import math
import os
import re
import shutil
import subprocess
from pathlib import Path


def _number(value) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) and number >= 0 else None


def _bit_depth(video: dict) -> int | None:
    for field in ("bits_per_raw_sample", "bits_per_sample"):
        if value := _number(video.get(field)):
            return int(value)
    pixel = video.get("pix_fmt", "")
    if match := re.search(r"(?:p|gray)(\d+)(?:le|be)?$", pixel):
        return int(match[1])
    if match := re.fullmatch(r"p0(10|12|16)(?:le|be)", pixel):
        return int(match[1])
    if pixel.startswith(("rgb48", "bgr48")):
        return 16
    if pixel.startswith(("rgba64", "bgra64")):
        return 16
    return 8 if pixel else None


def _hdr(video: dict, frames: list[dict]) -> str | None:
    side_data = list(video.get("side_data_list", []))
    for frame in frames:
        if frame.get("media_type") == "video":
            side_data.extend(frame.get("side_data_list", []))
    types = " ".join(item.get("side_data_type", "").lower() for item in side_data)
    if "dovi configuration record" in types or "dolby vision" in types:
        return "dolbyVision"
    if "smpte2094-40" in types or "smpte 2094-40" in types or "hdr10+" in types:
        return "hdr10plus"
    return {"smpte2084": "hdr10", "arib-std-b67": "hlg"}.get(video.get("color_transfer"))


def parse(data: dict) -> dict | None:
    if not isinstance(data, dict):
        raise ValueError("ffprobe returned a non-object response")
    streams = data.get("streams", [])
    video = next(
        (
            stream
            for stream in streams
            if stream.get("codec_type") == "video" and not stream.get("disposition", {}).get("attached_pic")
        ),
        None,
    )
    if video is None:
        return None
    audio, subtitles = [], []
    for stream in streams:
        tags = stream.get("tags", {})
        item = {"codec": stream.get("codec_name"), "language": tags.get("language"), "title": tags.get("title")}
        disposition = stream.get("disposition", {})
        if stream.get("codec_type") == "audio":
            if not item["codec"] or not isinstance(stream.get("channels"), int) or stream["channels"] <= 0:
                return None
            profile = (stream.get("profile") or "").lower()
            atmos = stream.get("codec_name") in ("truehd", "eac3") and ("atmos" in profile or "joc" in profile)
            audio.append(
                {
                    **item,
                    "channels": stream.get("channels"),
                    "atmos": atmos,
                    "default": bool(disposition.get("default", 0)),
                }
            )
        elif stream.get("codec_type") == "subtitle":
            if not item["codec"]:
                return None
            subtitles.append({**item, "forced": bool(disposition.get("forced", 0))})
    duration = _number(data.get("format", {}).get("duration"))
    if duration is None:
        duration = _number(video.get("duration"))
    bit_depth = _bit_depth(video)
    if (
        duration is None
        or not video.get("codec_name")
        or not bit_depth
        or any(not isinstance(video.get(field), int) or video[field] <= 0 for field in ("width", "height"))
    ):
        return None
    return {
        "duration": duration,
        "video": {
            "codec": video.get("codec_name"),
            "width": video.get("width"),
            "height": video.get("height"),
            "bitDepth": bit_depth,
            "hdr": _hdr(video, data.get("frames", [])),
        },
        "audio": audio,
        "subtitles": subtitles,
    }


def probe(path: Path, *, ffprobe_path: str, ffmpeg_path: str, runtime_dir: Path, timeout: float) -> dict | None:
    candidates = [ffprobe_path] if ffprobe_path else []
    if ffmpeg_path and (ffmpeg := shutil.which(ffmpeg_path)):
        candidates.append(str(Path(ffmpeg).with_name("ffprobe")))
    candidates.extend((str(runtime_dir / "usr/bin/ffprobe"), "ffprobe"))
    executable = next((found for candidate in candidates if (found := shutil.which(candidate))), None)
    if executable is None:
        return None
    env = os.environ.copy()
    if Path(executable).resolve().is_relative_to(runtime_dir.resolve()):
        directories = sorted({str(library.parent) for library in runtime_dir.rglob("libavdevice.so*")})
        if directories:
            env["LD_LIBRARY_PATH"] = os.pathsep.join([*directories, *filter(None, [env.get("LD_LIBRARY_PATH")])])
    # A few initial packets expose frame HDR10+ side data as well as stream-level DV metadata.
    result = subprocess.run(
        [
            executable,
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            "-show_frames",
            "-threads",
            "1",
            "-read_intervals",
            "%+#32",
            "-i",
            str(path),
        ],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
        timeout=timeout,
        env=env,
    )
    return parse(json.loads(result.stdout))
