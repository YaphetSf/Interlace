import json

import pytest

import config
from stream_resolver import (
    StreamResolutionError,
    is_direct_stream_url,
    resolve_stream,
    validate_public_url,
)


def test_direct_stream_detection():
    assert is_direct_stream_url("https://cdn.example.com/live/video.m3u8?token=abc")
    assert is_direct_stream_url("https://cdn.example.com/video.mp4")
    assert not is_direct_stream_url("https://www.youtube.com/watch?v=abc")


async def test_missing_scheme_is_normalized():
    assert await validate_public_url("93.184.216.34/video.mp4") == (
        "https://93.184.216.34/video.mp4"
    )


async def test_resolve_direct_stream(monkeypatch):
    async def public_url(url):
        return url

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)
    result = await resolve_stream("https://cdn.example.com/video.mp4")
    assert result == {
        "mode": "direct",
        "url": "https://cdn.example.com/video.mp4",
        "title": "",
        "source": "direct",
        "quality": "source",
    }


async def test_private_url_is_blocked():
    with pytest.raises(StreamResolutionError, match="private network"):
        await resolve_stream("http://127.0.0.1/video.mp4")


async def test_website_url_is_resolved_with_yt_dlp(monkeypatch):
    class Process:
        returncode = 0

        async def communicate(self):
            return (
                json.dumps(
                    {
                        "url": "https://media.example.com/video.mp4",
                        "title": "Example video",
                        "extractor_key": "Example",
                        "http_headers": {
                            "User-Agent": "Interlace test",
                            "Referer": "https://example.com/",
                            "X-Ignored": "no",
                        },
                    }
                ).encode(),
                b"",
            )

    async def public_url(url):
        return url

    async def subprocess(*args, **kwargs):
        return Process()

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)
    monkeypatch.setattr("stream_resolver.asyncio.create_subprocess_exec", subprocess)
    monkeypatch.setattr("stream_resolver.config.YT_DLP_PATH", "")

    result = await resolve_stream("https://example.com/watch/123")
    assert result["mode"] == "direct"
    assert result["title"] == "Example video"
    assert result["source"] == "Example"
    assert result["url"].startswith("https://media.example.com/video.mp4|")
    assert "User-Agent=Interlace%20test" in result["url"]
    assert "X-Ignored" not in result["url"]


async def test_configured_yt_dlp_path_must_exist(monkeypatch):
    async def public_url(url):
        return url

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)
    monkeypatch.setattr("stream_resolver.shutil.which", lambda _: None)
    monkeypatch.setattr("stream_resolver.config.YT_DLP_PATH", "/missing/yt-dlp")

    with pytest.raises(StreamResolutionError, match="configured path"):
        await resolve_stream("https://example.com/watch/123")


async def test_high_quality_returns_relay_inputs(monkeypatch):
    class Process:
        returncode = 0

        async def communicate(self):
            return (
                json.dumps(
                    {
                        "title": "HD video",
                        "extractor_key": "Example",
                        "http_headers": {"User-Agent": "Interlace test"},
                        "requested_formats": [
                            {
                                "url": "https://media.example.com/video.mp4",
                                "vcodec": "avc1.640028",
                                "acodec": "none",
                                "height": 1080,
                            },
                            {
                                "url": "https://media.example.com/audio.m4a",
                                "vcodec": "none",
                                "acodec": "mp4a.40.2",
                            },
                        ],
                    }
                ).encode(),
                b"",
            )

    async def public_url(url):
        return url

    async def subprocess(*args, **kwargs):
        return Process()

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)
    monkeypatch.setattr("stream_resolver.asyncio.create_subprocess_exec", subprocess)
    monkeypatch.setattr("stream_resolver.config.YT_DLP_PATH", "")

    result = await resolve_stream("https://example.com/watch/hd", "1080p")
    assert result["mode"] == "relay"
    assert result["video_url"] == "https://media.example.com/video.mp4"
    assert result["audio_url"] == "https://media.example.com/audio.m4a"
    assert result["quality"] == "1080p"


async def test_default_user_agent_is_added_to_relay_headers(monkeypatch):
    class Process:
        returncode = 0

        async def communicate(self):
            return (
                json.dumps(
                    {
                        "requested_formats": [
                            {
                                "url": "https://media.example.com/video.mp4",
                                "vcodec": "avc1",
                                "acodec": "none",
                                "height": 720,
                            },
                            {
                                "url": "https://media.example.com/audio.m4a",
                                "vcodec": "none",
                                "acodec": "aac",
                            },
                        ],
                    }
                ).encode(),
                b"",
            )

    async def public_url(url):
        return url

    async def subprocess(*args, **kwargs):
        return Process()

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)
    monkeypatch.setattr("stream_resolver.asyncio.create_subprocess_exec", subprocess)
    result = await resolve_stream("https://example.com/video", "720p")
    assert result["headers"]["User-Agent"] == config.STREAM_USER_AGENT


# ---------- xiaozhukankan.com custom extractor ----------

_FAKE_PAGE = """<!DOCTYPE html>
<html lang="zh-CN">
<head><title>《一战再战》 - 剧情片 - 2025年 - 小猪看看</title></head>
<body>
<div id="awp1" data-src="https://1080p.huyall.com/play/mepryPXb/index.m3u8" data-poster="//i1.xiaozhukankan.com/5/h7/ic51.jpg" data-title="一战再战 - 正片 - 线路167"></div>
</body>
</html>"""

_FAKE_PAGE_NO_PLAYER = """<!DOCTYPE html>
<html lang="zh-CN">
<head><title>Test Page</title></head>
<body><p>No video here</p></body>
</html>"""

_FAKE_PAGE_PROTO_REL = """<!DOCTYPE html>
<html lang="zh-CN">
<head><title>Test</title></head>
<body>
<div id="awp1" data-src="//cdn.example.com/video.m3u8" data-poster="..."></div>
</body>
</html>"""


def _fake_httpx_response(html: str, status: int = 200):
    """Build a minimal fake httpx response object."""
    class FakeResponse:
        status_code = status
        text = html

        def raise_for_status(self):
            if self.status_code >= 400:
                raise __import__("httpx").HTTPStatusError(
                    "mock error",
                    request=type("FakeRequest", (), {"url": "https://cn.xiaozhukankan.com/v/test.html"})(),
                    response=type("FakeResp", (), {"status_code": status})(),
                )

    return FakeResponse()


class _FakeAsyncClient:
    """Fake httpx.AsyncClient that returns a canned response."""

    def __init__(self, html=_FAKE_PAGE, status=200, **kwargs):
        self._html = html
        self._status = status

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    async def get(self, url, **kwargs):
        return _fake_httpx_response(self._html, self._status)


async def test_xiaozhukankan_extracts_m3u8_and_title(monkeypatch):
    async def public_url(url):
        return url

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)
    monkeypatch.setattr("stream_resolver.httpx.AsyncClient", _FakeAsyncClient)

    result = await resolve_stream("https://cn.xiaozhukankan.com/v/yizhanzaizhan.html")
    assert result["mode"] == "direct"
    assert result["url"] == "https://1080p.huyall.com/play/mepryPXb/index.m3u8"
    assert result["source"] == "xiaozhukankan"
    assert result["title"] == "一战再战"


async def test_xiaozhukankan_www_domain_also_works(monkeypatch):
    async def public_url(url):
        return url

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)
    monkeypatch.setattr("stream_resolver.httpx.AsyncClient", _FakeAsyncClient)

    result = await resolve_stream("https://www.xiaozhukankan.com/v/test.html")
    assert result["mode"] == "direct"
    assert result["source"] == "xiaozhukankan"


async def test_xiaozhukankan_no_awp1_raises_error(monkeypatch):
    async def public_url(url):
        return url

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)

    class NoPlayerClient(_FakeAsyncClient):
        def __init__(self, **kwargs):
            super().__init__(_FAKE_PAGE_NO_PLAYER, **kwargs)

    monkeypatch.setattr("stream_resolver.httpx.AsyncClient", NoPlayerClient)

    with pytest.raises(StreamResolutionError, match="Could not find video source"):
        await resolve_stream("https://cn.xiaozhukankan.com/v/missing.html")


async def test_xiaozhukankan_http_error_raises(monkeypatch):
    async def public_url(url):
        return url

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)

    class ErrorClient(_FakeAsyncClient):
        def __init__(self, **kwargs):
            super().__init__(html="Not Found", status=404, **kwargs)

    monkeypatch.setattr("stream_resolver.httpx.AsyncClient", ErrorClient)

    with pytest.raises(StreamResolutionError, match="Failed to fetch page"):
        await resolve_stream("https://cn.xiaozhukankan.com/v/missing.html")


async def test_xiaozhukankan_protocol_relative_url_is_normalised(monkeypatch):
    async def public_url(url):
        return url

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)

    class ProtoRelClient(_FakeAsyncClient):
        def __init__(self, **kwargs):
            super().__init__(_FAKE_PAGE_PROTO_REL, **kwargs)

    monkeypatch.setattr("stream_resolver.httpx.AsyncClient", ProtoRelClient)

    result = await resolve_stream("https://cn.xiaozhukankan.com/v/test.html")
    assert result["url"] == "https://cdn.example.com/video.m3u8"
