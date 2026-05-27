import pytest
from pytest_httpx import HTTPXMock

from aria2_client import Aria2


@pytest.fixture
def aria2():
    return Aria2()


async def test_add_uri(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "abc123def456"},
    )
    gid = await aria2.add_uri("magnet:?xt=urn:btih:test")
    assert gid == "abc123def456"


async def test_add_torrent(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "torrent-gid"},
    )
    gid = await aria2.add_torrent(b"fake-torrent-bytes")
    assert gid == "torrent-gid"


async def test_pause(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "ok"},
    )
    result = await aria2.pause("abc123")
    assert result == "ok"


async def test_unpause(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "ok"},
    )
    result = await aria2.unpause("abc123")
    assert result == "ok"


async def test_remove_stops_then_purges(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "ok"},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": "ok"},
    )
    result = await aria2.remove("abc123")
    assert result == "OK"


async def test_remove_handles_not_found_gracefully(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "error": {"message": "GID is not found"}},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "error": {"message": "removed"}},
    )
    result = await aria2.remove("abc123")
    assert result == "OK"


async def test_remove_raises_on_unknown_error(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "error": {"message": "some unexpected error"}},
    )
    with pytest.raises(RuntimeError, match="some unexpected error"):
        await aria2.remove("abc123")


async def test_all_downloads(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": [
            {"gid": "active1", "status": "active", "totalLength": "1000", "completedLength": "500", "downloadSpeed": "100000"},
        ]},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": [
            {"gid": "waiting1", "status": "waiting", "totalLength": "0", "completedLength": "0", "downloadSpeed": "0"},
        ]},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": []},
    )
    downloads = await aria2.all_downloads()
    assert len(downloads) == 2
    assert downloads[0]["gid"] == "active1"
    assert downloads[0]["progress"] == 50.0
    assert downloads[1]["gid"] == "waiting1"


async def test_aria2_error_response(aria2: Aria2, httpx_mock: HTTPXMock):
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "error": {"message": "something went wrong"}},
    )
    with pytest.raises(RuntimeError, match="something went wrong"):
        await aria2.add_uri("http://example.com/file.iso")


async def test_all_downloads_handles_exceptions(aria2: Aria2, httpx_mock: HTTPXMock):
    """When one call fails, the other results should still be returned."""
    httpx_mock.add_response(status_code=500)
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": [
            {"gid": "w1", "status": "waiting", "totalLength": "0", "completedLength": "0", "downloadSpeed": "0"},
        ]},
    )
    httpx_mock.add_response(
        json={"jsonrpc": "2.0", "id": "ic", "result": []},
    )
    downloads = await aria2.all_downloads()
    assert len(downloads) == 1
    assert downloads[0]["gid"] == "w1"
