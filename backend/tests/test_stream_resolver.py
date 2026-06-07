import json

import pytest

from stream_resolver import StreamResolutionError, is_direct_stream_url, resolve_stream


def test_direct_stream_detection():
    assert is_direct_stream_url("https://cdn.example.com/live/video.m3u8?token=abc")
    assert is_direct_stream_url("https://cdn.example.com/video.mp4")
    assert not is_direct_stream_url("https://www.youtube.com/watch?v=abc")


async def test_resolve_direct_stream(monkeypatch):
    async def public_url(url):
        return url

    monkeypatch.setattr("stream_resolver.validate_public_url", public_url)
    result = await resolve_stream("https://cdn.example.com/video.mp4")
    assert result == {
        "url": "https://cdn.example.com/video.mp4",
        "title": "",
        "source": "direct",
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
