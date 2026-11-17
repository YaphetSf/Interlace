import json
import subprocess
from types import SimpleNamespace

import pytest

import media


def sample(transfer=None, side_data=None, profile="Main 10", pixel="yuv420p10le"):
    return {
        "format": {"duration": "1318.400000"},
        "streams": [
            {"codec_type": "video", "codec_name": "mjpeg", "disposition": {"attached_pic": 1}},
            {
                "codec_type": "video",
                "codec_name": "hevc",
                "profile": profile,
                "pix_fmt": pixel,
                "width": 1920,
                "height": 1038,
                "color_transfer": transfer,
                "bits_per_raw_sample": "0",
                "side_data_list": side_data or [],
            },
            {
                "codec_type": "audio",
                "codec_name": "eac3",
                "channels": 6,
                "profile": "Dolby Digital Plus + Dolby Atmos",
                "tags": {"language": "eng"},
                "disposition": {"default": 1},
            },
            {
                "codec_type": "audio",
                "codec_name": "aac",
                "channels": 2,
                "tags": {"title": "Commentary"},
                "disposition": {"default": 0},
            },
            {
                "codec_type": "subtitle",
                "codec_name": "hdmv_pgs_subtitle",
                "tags": {"language": "chi", "title": "Chinese"},
                "disposition": {"forced": 1},
            },
            {"codec_type": "subtitle", "codec_name": "subrip", "tags": {"language": "eng"}},
        ],
    }


@pytest.mark.parametrize(
    ("transfer", "side_data", "expected"),
    [
        (None, [], None),
        ("smpte2084", [], "hdr10"),
        ("smpte2084", [{"side_data_type": "DOVI configuration record"}], "dolbyVision"),
        ("smpte2084", [{"side_data_type": "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"}], "hdr10plus"),
        ("arib-std-b67", [], "hlg"),
        (
            "smpte2084",
            [{"side_data_type": "SMPTE 2094-40"}, {"side_data_type": "DOVI configuration record"}],
            "dolbyVision",
        ),
    ],
)
def test_media_streams_and_hdr(transfer, side_data, expected):
    result = media.parse(sample(transfer, side_data))
    assert result == {
        "duration": 1318.4,
        "video": {"codec": "hevc", "width": 1920, "height": 1038, "bitDepth": 10, "hdr": expected},
        "audio": [
            {"codec": "eac3", "channels": 6, "language": "eng", "title": None, "atmos": True, "default": True},
            {"codec": "aac", "channels": 2, "language": None, "title": "Commentary", "atmos": False, "default": False},
        ],
        "subtitles": [
            {"codec": "hdmv_pgs_subtitle", "language": "chi", "title": "Chinese", "forced": True},
            {"codec": "subrip", "language": "eng", "title": None, "forced": False},
        ],
    }


def test_hdr10plus_frame_metadata():
    data = sample("smpte2084")
    data["frames"] = [
        {"media_type": "video", "side_data_list": [{"side_data_type": "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"}]}
    ]
    assert media.parse(data)["video"]["hdr"] == "hdr10plus"


@pytest.mark.parametrize(
    ("codec", "profile", "expected"),
    [
        ("truehd", "Dolby TrueHD + Dolby Atmos", True),
        ("truehd", "TrueHD", False),
        ("eac3", "E-AC-3 JOC", True),
        ("eac3", "Dolby Digital Plus", False),
        ("aac", "Atmos", False),
    ],
)
def test_atmos_profiles(codec, profile, expected):
    data = sample()
    data["streams"][2].update(codec_name=codec, profile=profile)
    assert media.parse(data)["audio"][0]["atmos"] is expected


@pytest.mark.parametrize(
    ("pixel", "raw_bits", "expected"),
    [
        ("yuv420p", "8", 8),
        ("yuv420p", "0", 8),
        ("yuv422p12le", "0", 12),
        ("p010le", None, 10),
        ("gbrp10le", None, 10),
        ("rgb48le", None, 16),
        ("gray16be", None, 16),
    ],
)
def test_bit_depth(pixel, raw_bits, expected):
    data = sample(pixel=pixel)
    data["streams"][1]["bits_per_raw_sample"] = raw_bits
    assert media.parse(data)["video"]["bitDepth"] == expected


@pytest.mark.parametrize("duration", ["N/A", "NaN", "Infinity", None])
def test_unknown_duration_falls_back_to_video(duration):
    data = sample()
    data["format"]["duration"] = duration
    data["streams"][1]["duration"] = "10.5"
    assert media.parse(data)["duration"] == 10.5
    del data["streams"][1]["duration"]
    assert media.parse(data) is None
    assert media.parse({"streams": []}) is None


def test_runtime_probe_sets_library_path_and_timeout(monkeypatch, tmp_path):
    runtime = tmp_path / "runtime"
    executable = runtime / "usr/bin/ffprobe"
    lib = runtime / "usr/lib/aarch64-linux-gnu/libavdevice.so.62"
    lib.parent.mkdir(parents=True)
    lib.touch()
    monkeypatch.setenv("LD_LIBRARY_PATH", "/existing/lib")
    monkeypatch.setattr("media.shutil.which", lambda name: str(executable) if name == str(executable) else None)
    calls = []

    def run(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(stdout=json.dumps(sample("arib-std-b67")).encode())

    monkeypatch.setattr("media.subprocess.run", run)
    path = tmp_path / "movie.mkv"
    result = media.probe(path, ffprobe_path="", ffmpeg_path="", runtime_dir=runtime, timeout=20)
    assert result["video"]["hdr"] == "hlg"
    command, options = calls[0]
    assert command[0] == str(executable)
    assert command[-2:] == ["-i", str(path)]
    assert "-show_frames" in command and command[command.index("-read_intervals") + 1] == "%+#32"
    assert options["env"]["LD_LIBRARY_PATH"] == f"{lib.parent}:/existing/lib"
    assert options["timeout"] == 20 and options["check"] is True
    assert options["stdin"] == subprocess.DEVNULL


@pytest.mark.parametrize("explicit", [True, False])
def test_probe_uses_configured_binary_or_ffmpeg_sibling(monkeypatch, tmp_path, explicit):
    executable = tmp_path / "bin/ffprobe"
    ffmpeg = tmp_path / "bin/ffmpeg"
    monkeypatch.setattr("media.shutil.which", lambda name: name if name in (str(executable), str(ffmpeg)) else None)

    def run(command, **kwargs):
        assert command[0] == str(executable)
        return SimpleNamespace(stdout=json.dumps(sample()).encode())

    monkeypatch.setattr("media.subprocess.run", run)
    assert (
        media.probe(
            tmp_path / "movie.mkv",
            ffprobe_path=str(executable) if explicit else "",
            ffmpeg_path=str(ffmpeg),
            runtime_dir=tmp_path / "other",
            timeout=10,
        )
        is not None
    )


def test_missing_probe_is_unavailable(monkeypatch, tmp_path):
    monkeypatch.setattr("media.shutil.which", lambda name: None)
    assert (
        media.probe(tmp_path / "movie.mkv", ffprobe_path="", ffmpeg_path="", runtime_dir=tmp_path, timeout=10) is None
    )


@pytest.mark.parametrize("response", [None, [], "invalid"])
def test_non_object_probe_response_fails(response):
    with pytest.raises(ValueError, match="non-object"):
        media.parse(response)


@pytest.mark.parametrize(
    ("stream", "field"),
    [
        (1, "width"),
        (1, "height"),
        (1, "pix_fmt"),
        (1, "codec_name"),
        (2, "channels"),
        (2, "codec_name"),
        (4, "codec_name"),
    ],
)
def test_incomplete_probe_is_null_instead_of_changing_contract_types(stream, field):
    data = sample()
    del data["streams"][stream][field]
    assert media.parse(data) is None
