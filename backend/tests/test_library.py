import os
import re
import sqlite3
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

import config
import library
import tmdb
from app import app
from library import ParsedName, parse_name

from .conftest import DEVICE_KEY, INTERLACE, PHONE, write_registry

OFFICE = "The.Office.US.S02.1080p.BluRay.x265-RARBG"
TWIN_PEAKS = "Twin.Peaks.SEASON.01.S01.COMPLETE.1080p.10bit.BluRay.6CH.x265.HEVC-PSA"
SWEENEY = (
    "www.UIndex.org    -    Sweeney Todd The Demon Barber of Fleet Street 2007 "
    "REPACK2 UHD BluRay 1080p DDP 5 1 DoVi HDR10 x265-SM737"
)
NAMES = [
    ("1917 (2019) [1080p] [BluRay] [5.1] [YTS.MX]", ParsedName("1917", 2019)),
    (
        "Autumn Sonata (1978) Criterion (1080p BluRay x265 HEVC 10bit AAC 1.0 Swedish Tigole)",
        ParsedName("Autumn Sonata", 1978),
    ),
    ("Scum 1979 Remastered 1080p BluRay HEVC x265 BONE.mkv", ParsedName("Scum", 1979)),
    (
        "The Worst Person In The World (2021) [1080p] [BluRay] [5.1] [YTS.MX]",
        ParsedName("The Worst Person In The World", 2021),
    ),
    (OFFICE, ParsedName("The Office US", season=2)),
    ("The.Office.US.S02E01.1080p.BluRay.x265-RARBG.mkv", ParsedName("The Office US", season=2, episode=1)),
    (TWIN_PEAKS, ParsedName("Twin Peaks", season=1)),
    (
        "Twin.Peaks.S01E01.Northwest.Passage.1080p.10bit.BluRay.6CH.x265.HEVC-PSA.mkv",
        ParsedName("Twin Peaks", season=1, episode=1),
    ),
    (SWEENEY, ParsedName("Sweeney Todd The Demon Barber of Fleet Street", 2007)),
    ("thunderbird.tmp", None),
]


@pytest.fixture(autouse=True)
def isolated_catalog(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "DATA_DIR", tmp_path / "data")
    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    monkeypatch.setattr(config, "TMDB_LANGUAGE", "en-US")
    monkeypatch.setattr("media.probe", lambda *args, **kwargs: None)
    yield
    library.close_media_probes()


@pytest.fixture
def catalog_dir(mock_download_dir, monkeypatch):
    root = mock_download_dir / "catalog"
    root.mkdir()
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    entries = [NAMES[index][0] for index in (0, 1, 2, 3, 4, 6, 8)]
    for index, name in enumerate(entries):
        entry = root / name
        if entry.suffix == ".mkv":
            entry.write_bytes(b"movie")
        else:
            entry.mkdir()
            if name == OFFICE:
                for episode in (10, 2, 1):
                    (entry / f"The.Office.US.S02E{episode:02}.1080p.BluRay.x265-RARBG.mkv").write_bytes(b"episode")
                video = entry / NAMES[5][0]
                for suffix in ("-cn.srt", ".en.ass", "_commentary.ssa", ".srt", ".fr.vtt"):
                    (entry / f"{video.stem}{suffix}").write_bytes(b"subtitle")
                (entry / "unrelated.srt").write_bytes(b"not a sidecar")
                (entry / "Extras.mkv").write_bytes(b"extra")
                (entry / "SeasonOnly.S02.mkv").write_bytes(b"extra")
                (entry / "The.Office.US.S02E03.mkv").write_bytes(b"partial")
                (entry / "The.Office.US.S02E03.mkv.aria2").touch()
            elif name == TWIN_PEAKS:
                (entry / NAMES[7][0]).write_bytes(b"episode")
            else:
                nested = entry / "disc"
                nested.mkdir()
                (nested / "feature.mkv").write_bytes(b"movie")
            (entry / "Sample.mkv").write_bytes(b"sample")
            (entry / "movie_sample_clip.mp4").write_bytes(b"sample")
            hidden = entry / ".hidden"
            hidden.mkdir()
            (hidden / "hidden.mkv").write_bytes(b"hidden")
        os.utime(entry, (1000.75 + index, 1000.75 + index))
    (root / "thunderbird.tmp").write_bytes(b"temporary")
    (root / "Incomplete.mkv").write_bytes(b"partial")
    (root / "Incomplete.mkv.aria2").touch()
    (root / "Sample.mkv").write_bytes(b"sample")
    for name in (".hidden", "NoVideos", "OnlyPartial", "OnlySample"):
        entry = root / name
        entry.mkdir()
        if name == ".hidden":
            (entry / "hidden.mkv").write_bytes(b"hidden")
        elif name == "OnlyPartial":
            (entry / "partial.mkv").write_bytes(b"partial")
            (entry / "partial.mkv.aria2").touch()
        elif name == "OnlySample":
            (entry / "sample.mkv").write_bytes(b"sample")
    return root


@pytest.mark.parametrize(("name", "expected"), NAMES)
def test_parse_real_names(name, expected):
    assert parse_name(name) == expected


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("2001.A.Space.Odyssey.1968.2160p.mkv", ParsedName("2001 A Space Odyssey", 1968)),
        ("Film_WEB-DL_1080p.mkv", ParsedName("Film")),
        ("Film [Release Group] 2020.mkv", ParsedName("Film")),
        ("Film (Director's Cut).mkv", ParsedName("Film")),
        ("Film.S03.mkv", ParsedName("Film", season=3)),
        ("Film.SEASON.03.S03E01.mkv", ParsedName("Film", season=3, episode=1)),
        (
            "The.Office.US.S03E12E13.1080p.BluRay.x265-RARBG.mp4",
            ParsedName("The Office US", season=3, episode=12, last_episode=13),
        ),
        ("Show.S01E01-E02.mkv", ParsedName("Show", season=1, episode=1, last_episode=2)),
        ("Show s01e05-06 720p.mkv", ParsedName("Show", season=1, episode=5, last_episode=6)),
        ("Show.S01E04-1080p.mkv", ParsedName("Show", season=1, episode=4)),
        ("Show.S01E04E04.mkv", ParsedName("Show", season=1, episode=4)),
        ("1080p.mkv", None),
    ],
)
def test_parse_boundaries(name, expected):
    assert parse_name(name) == expected


def test_catalog_without_token(client, catalog_dir, httpx_mock):
    response = client.get("/api/catalog")
    assert response.status_code == 200
    data = response.json()
    assert set(data) == {"titles", "continue", "watched"}
    assert data["continue"] == [] and data["watched"] == []
    titles = data["titles"]
    assert len(titles) == 7
    assert [title["added"] for title in titles] == list(range(1006, 999, -1))
    assert all(type(title["added"]) is int for title in titles)
    expected = {NAMES[index][0]: NAMES[index][1] for index in (0, 1, 2, 3, 4, 6, 8)}
    for title in titles:
        assert set(title) == {
            "id",
            "kind",
            "title",
            "year",
            "overview",
            "tmdbId",
            "poster",
            "backdrop",
            "logo",
            "runtime",
            "certification",
            "genres",
            "crew",
            "matched",
            "cast",
            "added",
            "watched",
            "files",
        }
        assert title["watched"] is None
        assert title["title"] == expected[title["id"]].title
        assert title["year"] == expected[title["id"]].year
        assert title["kind"] == ("show" if title["id"] in (OFFICE, TWIN_PEAKS) else "movie")
        assert title["poster"] is False and title["backdrop"] is False
        assert title["overview"] is None and title["tmdbId"] is None
        assert title["logo"] is False and title["runtime"] is None and title["certification"] is None
        assert title["genres"] == title["crew"] == title["cast"] == []
        assert title["matched"] is None
        for file in title["files"]:
            assert set(file) == {
                "path",
                "name",
                "size",
                "season",
                "episode",
                "lastEpisode",
                "episodeTitle",
                "episodeOverview",
                "airDate",
                "runtime",
                "still",
                "media",
                "subtitles",
                "progress",
            }
            assert file["lastEpisode"] is None
            assert Path(file["path"]).is_file()
            assert file["size"] == Path(file["path"]).stat().st_size
            assert file["progress"] is None and file["episodeTitle"] is None
            assert file["episodeOverview"] is None and file["airDate"] is None and file["runtime"] is None
            assert file["still"] is False and file["media"] is None
    office = next(title for title in titles if title["id"] == OFFICE)
    assert [file["episode"] for file in office["files"]] == [1, 2, 10, None, None]
    assert [file["season"] for file in office["files"]] == [2, 2, 2, None, None]
    assert office["files"][-2]["name"] == "Extras.mkv"
    assert {sub["label"] for sub in office["files"][0]["subtitles"]} == {"cn", "en", "commentary", "", "fr"}
    for subtitle in office["files"][0]["subtitles"]:
        assert set(subtitle) == {"path", "name", "label"}
        assert Path(subtitle["path"]).name == subtitle["name"]
    assert not httpx_mock.get_requests()
    with sqlite3.connect(config.DATA_DIR / "library.db") as db:
        assert db.execute("SELECT COUNT(*) FROM matches").fetchone()[0] == 0
    assert client.get("/api/art", params={"id": OFFICE, "kind": "poster"}).status_code == 404


def test_catalog_tmdb_and_art_are_cached(client, catalog_dir, monkeypatch, httpx_mock):
    monkeypatch.setattr(config, "TMDB_TOKEN", "test-token")
    monkeypatch.setattr(config, "TMDB_LANGUAGE", "fr-FR")
    calls = []
    movie_queries = [
        "1917",
        "Autumn Sonata",
        "Scum",
        "The Worst Person In The World",
        "Sweeney Todd The Demon Barber of Fleet Street",
    ]

    def tmdb_response(request):
        calls.append(request)
        assert request.headers["authorization"] == "Bearer test-token"
        path = request.url.path
        if request.url.host == "image.tmdb.org":
            assert path.startswith(("/t/p/w500/", "/t/p/w1280/"))
            return httpx.Response(200, content=b"image:" + path.encode(), headers={"content-type": "image/jpeg"})
        assert request.url.params["language"] == "fr-FR"
        if path == "/3/search/movie":
            query = request.url.params["query"]
            index = movie_queries.index(query)
            year = [2019, 1978, 1979, 2021, 2007][index]
            assert request.url.params["year"] == str(year)
            return httpx.Response(
                200,
                json={
                    "results": [
                        {
                            "id": 100 + index,
                            "title": query + " matched",
                            "release_date": f"{year}-01-01",
                            "overview": "Movie overview",
                            "poster_path": f"/movie{index}.jpg",
                            "backdrop_path": f"/movie{index}-back.jpg",
                        },
                        {"id": 999, "title": "Do not use the second result"},
                    ]
                },
            )
        if path == "/3/search/tv":
            query = request.url.params["query"]
            if query == "The Office US":
                return httpx.Response(200, json={"results": []})
            assert query in ("The Office", "Twin Peaks")
            tmdb_id = 2316 if query == "The Office" else 1920
            return httpx.Response(
                200,
                json={
                    "results": [
                        {
                            "id": tmdb_id,
                            "name": query,
                            "first_air_date": "2005-03-24" if tmdb_id == 2316 else "1990-04-08",
                            "overview": "Show overview",
                            "poster_path": f"/show{tmdb_id}.jpg",
                            "backdrop_path": f"/show{tmdb_id}-back.jpg",
                        }
                    ]
                },
            )
        if re.fullmatch(r"/3/(movie|tv)/\d+", path):
            assert request.url.params["include_image_language"] == "en,null"
            assert request.url.params["append_to_response"] == (
                "credits,images,release_dates" if "/movie/" in path else "credits,images,content_ratings"
            )
            return httpx.Response(200, json={})
        assert path in ("/3/tv/2316/season/2", "/3/tv/1920/season/1")
        return httpx.Response(
            200,
            json={
                "episodes": [
                    {"episode_number": 1, "name": "The Dundies" if "2316" in path else "Northwest Passage"},
                    {"episode_number": 2, "name": "Sexual Harassment"},
                    {"episode_number": 10, "name": "Christmas Party"},
                ]
            },
        )

    httpx_mock.add_callback(
        tmdb_response, url=re.compile(r"https://(?:api\.themoviedb|image\.tmdb)\.org/.*"), is_reusable=True
    )
    response = client.get("/api/catalog")
    assert response.status_code == 200
    data = response.json()
    assert len(data["titles"]) == 7
    for title in data["titles"]:
        assert title["tmdbId"] is not None and title["matched"] == "auto"
        assert title["poster"] is True and title["backdrop"] is True
        assert title["overview"] in ("Movie overview", "Show overview")
        if title["kind"] == "movie":
            assert title["title"].endswith(" matched")
    office = next(title for title in data["titles"] if title["id"] == OFFICE)
    assert (office["title"], office["year"], office["tmdbId"]) == ("The Office", 2005, 2316)
    assert [file["episodeTitle"] for file in office["files"]] == [
        "The Dundies",
        "Sexual Harassment",
        "Christmas Party",
        None,
        None,
    ]
    for kind, width, source in (("poster", "w500", "show2316.jpg"), ("backdrop", "w1280", "show2316-back.jpg")):
        art = client.get("/api/art", params={"id": OFFICE, "kind": kind})
        assert art.status_code == 200
        assert art.headers["content-type"] == "image/jpeg"
        assert art.content == f"image:/t/p/{width}/{source}".encode()
    count = len(calls)
    assert client.get("/api/catalog").json() == data
    assert len(calls) == count
    assert count == 31  # Eight searches, seven details, two seasons and fourteen images.
    assert client.get("/api/art", params={"id": OFFICE, "kind": "other"}).status_code == 422
    assert client.get("/api/art", params={"id": "../missing", "kind": "poster"}).status_code == 404

    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    plain = client.get("/api/catalog").json()
    office = next(title for title in plain["titles"] if title["id"] == OFFICE)
    assert office["title"] == "The Office US" and office["tmdbId"] is None and office["matched"] is None
    assert office["poster"] is False and office["backdrop"] is False
    assert office["files"][0]["episodeTitle"] is None
    assert len(calls) == count


@pytest.fixture
def one_movie(mock_download_dir, monkeypatch):
    root = mock_download_dir / "single"
    root.mkdir()
    movie = root / "Film.2020.mkv"
    movie.write_bytes(b"movie")
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    monkeypatch.setattr(config, "TMDB_TOKEN", "test-token")
    return movie


def test_empty_search_is_cached(client, one_movie, httpx_mock):
    httpx_mock.add_response(json={"results": []})
    first = client.get("/api/catalog").json()
    assert first["titles"][0]["tmdbId"] is None
    assert client.get("/api/catalog").json() == first
    assert len(httpx_mock.get_requests()) == 1


@pytest.mark.parametrize("failure", ["network", "http", "json"])
def test_failed_search_is_retried(client, one_movie, httpx_mock, failure):
    if failure == "network":
        httpx_mock.add_exception(httpx.ConnectError("offline"))
    elif failure == "http":
        httpx_mock.add_response(status_code=503)
    else:
        httpx_mock.add_response(content=b"not json")
    httpx_mock.add_response(json={"results": [{"id": 42, "title": "Matched", "release_date": "2021-01-01"}]})
    httpx_mock.add_response(json={})
    response = client.get("/api/catalog")
    assert response.status_code == 200
    assert response.json()["titles"][0]["title"] == "Film"
    with sqlite3.connect(config.DATA_DIR / "library.db") as db:
        assert db.execute("SELECT COUNT(*) FROM matches").fetchone()[0] == 0
    title = client.get("/api/catalog").json()["titles"][0]
    assert (title["title"], title["year"], title["tmdbId"]) == ("Matched", 2021, 42)
    assert len(httpx_mock.get_requests()) == 3


def test_failed_image_is_retried_without_search(client, one_movie, httpx_mock):
    httpx_mock.add_response(json={"results": [{"id": 42, "title": "Matched", "poster_path": "/poster.jpg"}]})
    httpx_mock.add_response(json={})
    httpx_mock.add_response(status_code=503)
    httpx_mock.add_response(content=b"poster")
    first = client.get("/api/catalog")
    assert first.status_code == 200
    assert first.json()["titles"][0]["poster"] is False
    assert client.get("/api/art", params={"id": one_movie.name, "kind": "poster"}).status_code == 404
    second = client.get("/api/catalog").json()
    assert second["titles"][0]["poster"] is True
    assert client.get("/api/catalog").json() == second
    requests = httpx_mock.get_requests()
    assert len(requests) == 4
    assert requests[2].url == requests[3].url


def test_progress_round_trip_and_continue(client, catalog_dir, monkeypatch):
    episode = catalog_dir / OFFICE / NAMES[5][0]
    next_episode = catalog_dir / OFFICE / "The.Office.US.S02E02.1080p.BluRay.x265-RARBG.mkv"
    last_episode = catalog_dir / TWIN_PEAKS / NAMES[7][0]
    clock = iter((100.75, 200.75, 300.75, 400.75, 500.75, 600.75))
    monkeypatch.setattr("library.time", SimpleNamespace(time=lambda: next(clock)))
    assert client.get("/api/progress", params={"path": str(episode)}).status_code == 404
    response = client.post("/api/progress", json={"path": str(episode), "position": 75.2, "duration": 100})
    assert response.status_code == 200
    record = response.json()
    assert type(record["updated"]) is int
    assert record == {"path": str(episode), "position": 75.2, "duration": 100.0, "finished": False, "updated": 100}
    fetched = client.get("/api/progress", params={"path": str(episode)}).json()
    assert type(fetched["updated"]) is int
    assert fetched == record
    catalog = client.get("/api/catalog").json()
    office = next(title for title in catalog["titles"] if title["id"] == OFFICE)
    assert all(type(title["added"]) is int for title in catalog["titles"])
    assert type(office["files"][0]["progress"]["updated"]) is int
    assert office["files"][0]["progress"] == {key: value for key, value in record.items() if key != "path"}
    assert catalog["continue"] == [{"titleId": OFFICE, "path": str(episode)}]
    with sqlite3.connect(config.DATA_DIR / "library.db") as db:
        columns = {row[1]: row[2] for row in db.execute("PRAGMA table_info(progress)")}
        assert columns["updated"] == "INTEGER"
        assert db.execute("SELECT updated, typeof(updated) FROM progress").fetchone() == (100, "integer")

    response = client.post("/api/progress", json={"path": str(episode), "position": 90, "duration": 100})
    assert response.json()["finished"] is True
    assert client.get("/api/catalog").json()["continue"] == [{"titleId": OFFICE, "path": str(next_episode)}]
    response = client.post("/api/progress", json={"path": str(last_episode), "position": 1, "duration": 100})
    assert response.json()["finished"] is False
    assert client.get("/api/catalog").json()["continue"] == [
        {"titleId": TWIN_PEAKS, "path": str(last_episode)},
        {"titleId": OFFICE, "path": str(next_episode)},
    ]
    response = client.post("/api/progress", json={"path": str(last_episode), "position": 100, "duration": 100})
    assert response.json()["finished"] is True
    assert client.get("/api/catalog").json()["continue"] == [{"titleId": OFFICE, "path": str(next_episode)}]
    response = client.post("/api/progress", json={"path": str(episode), "position": 0, "duration": 0})
    assert response.json()["finished"] is False
    response = client.request("DELETE", "/api/progress", json={"path": str(episode)})
    assert response.status_code == 200 and response.json() == {"ok": True}
    assert client.get("/api/progress", params={"path": str(episode)}).status_code == 404
    assert client.get("/api/catalog").json()["continue"] == []


def test_finished_movie_leaves_continue(client, mock_download_dir):
    movie = str(mock_download_dir / "tv.mp4")
    client.post("/api/progress", json={"path": movie, "position": 1, "duration": 100})
    assert client.get("/api/catalog").json()["continue"] == [{"titleId": "tv.mp4", "path": movie}]
    client.post("/api/progress", json={"path": movie, "position": 100, "duration": 100})
    assert client.get("/api/catalog").json()["continue"] == []


def test_continue_uses_latest_write_when_timestamps_tie(client, mock_download_dir, monkeypatch):
    root = mock_download_dir / "ties"
    root.mkdir()
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    monkeypatch.setattr("library.time", SimpleNamespace(time=lambda: 1000.75))
    for name in ("Alpha", "Zulu"):
        folder = root / name
        folder.mkdir()
        for episode in (1, 2, 3):
            (folder / f"{name}.S01E{episode:02}.mkv").write_bytes(b"episode")
    alpha1 = str(root / "Alpha" / "Alpha.S01E01.mkv")
    alpha2 = str(root / "Alpha" / "Alpha.S01E02.mkv")
    alpha3 = str(root / "Alpha" / "Alpha.S01E03.mkv")
    zulu1 = str(root / "Zulu" / "Zulu.S01E01.mkv")

    def play(path, position=10):
        response = client.post("/api/progress", json={"path": path, "position": position, "duration": 100})
        assert response.status_code == 200

    play(alpha2)
    play(zulu1)
    assert client.get("/api/catalog").json()["continue"] == [
        {"titleId": "Zulu", "path": zulu1},
        {"titleId": "Alpha", "path": alpha2},
    ]
    play(alpha1)
    assert client.get("/api/catalog").json()["continue"] == [
        {"titleId": "Alpha", "path": alpha1},
        {"titleId": "Zulu", "path": zulu1},
    ]
    play(alpha2)
    expected = [{"titleId": "Alpha", "path": alpha2}, {"titleId": "Zulu", "path": zulu1}]
    assert client.get("/api/catalog").json()["continue"] == expected
    assert client.get("/api/catalog").json()["continue"] == expected
    play(alpha2, position=90)
    assert client.get("/api/catalog").json()["continue"] == [
        {"titleId": "Alpha", "path": alpha3},
        {"titleId": "Zulu", "path": zulu1},
    ]


@pytest.fixture
def watch_dir(mock_download_dir, monkeypatch):
    """A show with an extra, a loose movie with a sidecar, a torrent still downloading, and an unseen film."""
    root = mock_download_dir / "watch"
    root.mkdir()
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    now = [1000.25]
    monkeypatch.setattr("library.time", SimpleNamespace(time=lambda: now[0]))
    show = root / "Show.S01"
    show.mkdir()
    for name in ("Show.S01E01.mkv", "Show.S01E02.mkv", "Extras.mkv"):
        (show / name).write_bytes(b"episode")
    (root / "Movie.2020.mkv").write_bytes(b"movie")
    (root / "Movie.2020.en.srt").write_bytes(b"subtitle")
    downloading = root / "Busy.S01"
    downloading.mkdir()
    (downloading / "Busy.S01E01.mkv").write_bytes(b"episode")
    (root / "Busy.S01.aria2").touch()
    (root / "Unseen.2021.mkv").write_bytes(b"movie")
    for index, entry in enumerate(("Show.S01", "Movie.2020.mkv", "Busy.S01", "Unseen.2021.mkv")):
        os.utime(root / entry, (500 + index, 500 + index))
    return SimpleNamespace(root=root, now=now, show=show)


def finish(client, path, duration=100):
    response = client.post("/api/progress", json={"path": str(path), "position": duration, "duration": duration})
    assert response.status_code == 200 and response.json()["finished"] is True


def ids(titles):
    return [title["id"] for title in titles]


def test_watched_titles_leave_the_library(client, watch_dir):
    episode1, episode2 = watch_dir.show / "Show.S01E01.mkv", watch_dir.show / "Show.S01E02.mkv"
    finish(client, episode1)
    client.post("/api/progress", json={"path": str(episode2), "position": 10, "duration": 100})
    catalog = client.get("/api/catalog").json()
    assert ids(catalog["titles"]) == ["Unseen.2021.mkv", "Busy.S01", "Movie.2020.mkv", "Show.S01"]
    assert catalog["watched"] == []
    assert catalog["continue"] == [{"titleId": "Show.S01", "path": str(episode2)}]

    # The extra does not hold the show back.
    watch_dir.now[0] = 2000.75
    finish(client, episode2)
    watch_dir.now[0] = 1500.5
    finish(client, watch_dir.root / "Movie.2020.mkv")
    catalog = client.get("/api/catalog").json()
    assert ids(catalog["titles"]) == ["Unseen.2021.mkv", "Busy.S01"]
    assert ids(catalog["watched"]) == ["Show.S01", "Movie.2020.mkv"]
    assert [title["watched"] for title in catalog["watched"]] == [2000, 1500]
    assert all(type(title["watched"]) is int for title in catalog["watched"])
    assert len(catalog["watched"][0]["files"]) == 3
    assert catalog["continue"] == []


def test_mark_watched_and_unwatched(client, watch_dir):
    episode1 = watch_dir.show / "Show.S01E01.mkv"
    client.post("/api/progress", json={"path": str(episode1), "position": 10, "duration": 1320})
    response = client.post("/api/catalog/watched", json={"id": "Show.S01"})
    assert response.status_code == 200 and response.json() == {"ok": True}
    catalog = client.get("/api/catalog").json()
    show = next(title for title in catalog["watched"] if title["id"] == "Show.S01")
    progress = {Path(file["path"]).name: file["progress"] for file in show["files"]}
    assert progress["Show.S01E01.mkv"]["position"] == progress["Show.S01E01.mkv"]["duration"] == 1320
    assert all(record["finished"] for record in progress.values())
    assert "Show.S01" not in ids(catalog["titles"])

    response = client.request("DELETE", "/api/catalog/watched", json={"id": "Show.S01"})
    assert response.status_code == 200 and response.json() == {"ok": True}
    catalog = client.get("/api/catalog").json()
    show = next(title for title in catalog["titles"] if title["id"] == "Show.S01")
    assert show["watched"] is None and all(file["progress"] is None for file in show["files"])
    assert catalog["watched"] == []

    for method in ("POST", "DELETE"):
        for title_id in ("Missing", "../watch", ""):
            assert client.request(method, "/api/catalog/watched", json={"id": title_id}).status_code == 404


def delete(client, title_id):
    return client.request("DELETE", "/api/catalog/title", json={"id": title_id})


def test_deleting_a_watched_title_keeps_it_on_the_shelf(client, watch_dir):
    assert client.post("/api/catalog/watched", json={"id": "Show.S01"}).status_code == 200
    watch_dir.now[0] = 1500.25
    finish(client, watch_dir.root / "Movie.2020.mkv")
    client.post(
        "/api/subtitle-choice", json={"path": str(watch_dir.root / "Movie.2020.mkv"), "subtitle": {"kind": "off"}}
    )
    for title_id in ("Show.S01", "Movie.2020.mkv", "Unseen.2021.mkv"):
        response = delete(client, title_id)
        assert response.status_code == 200 and response.json() == {"ok": True}
    assert not watch_dir.show.exists()
    assert not (watch_dir.root / "Movie.2020.mkv").exists() and not (watch_dir.root / "Movie.2020.en.srt").exists()
    assert not (watch_dir.root / "Unseen.2021.mkv").exists()
    assert (watch_dir.root / "Busy.S01" / "Busy.S01E01.mkv").is_file()
    with sqlite3.connect(config.DATA_DIR / "library.db") as db:
        assert db.execute("SELECT COUNT(*) FROM progress").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM subtitle_choices").fetchone()[0] == 0
        assert db.execute("SELECT * FROM watched ORDER BY title_id").fetchall() == [
            ("Movie.2020.mkv", "movie", 501, 1500),
            ("Show.S01", "show", 500, 1000),
        ]

    catalog = client.get("/api/catalog").json()
    assert ids(catalog["titles"]) == ["Busy.S01"]
    assert ids(catalog["watched"]) == ["Movie.2020.mkv", "Show.S01"]
    shelved = catalog["watched"][1]
    assert (shelved["title"], shelved["kind"], shelved["added"], shelved["watched"]) == ("Show", "show", 500, 1000)
    assert shelved["files"] == []
    for method in ("POST", "DELETE"):
        assert client.request(method, "/api/catalog/watched", json={"id": "Show.S01"}).status_code == 404
    for title_id in ("Show.S01", "Missing", "../watch", ""):
        assert delete(client, title_id).status_code == 404

    # A title downloaded again under the same name is listed from the disk.
    watch_dir.show.mkdir()
    (watch_dir.show / "Show.S01E01.mkv").write_bytes(b"episode")
    catalog = client.get("/api/catalog").json()
    assert ids(catalog["titles"]) == ["Show.S01", "Busy.S01"]
    assert ids(catalog["watched"]) == ["Movie.2020.mkv"]


def test_a_failed_delete_leaves_the_title_on_disk(client, watch_dir, monkeypatch):
    finish(client, watch_dir.root / "Movie.2020.mkv")
    unlink = Path.unlink

    def failing(path, *args, **kwargs):
        if path.name == "Movie.2020.mkv":
            raise PermissionError("read-only")
        return unlink(path, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", failing)
    assert delete(client, "Movie.2020.mkv").status_code == 500
    assert (watch_dir.root / "Movie.2020.mkv").is_file()
    catalog = client.get("/api/catalog").json()
    movie = next(title for title in catalog["watched"] if title["id"] == "Movie.2020.mkv")
    assert len(movie["files"]) == 1 and movie["files"][0]["progress"]["finished"]


def test_shelved_title_keeps_its_match_and_art(client, wrong_match, httpx_mock):
    finish(client, wrong_match.path)
    assert delete(client, wrong_match.id).status_code == 200
    assert not wrong_match.path.exists()
    catalog = client.get("/api/catalog").json()
    assert catalog["titles"] == []
    shelved = catalog["watched"][0]
    assert (shelved["id"], shelved["tmdbId"], shelved["title"], shelved["poster"]) == (
        wrong_match.id,
        42,
        "Wrong Film",
        True,
    )
    poster = client.get("/api/art", params={"id": wrong_match.id, "kind": "poster"})
    assert poster.status_code == 200 and poster.content == b"wrong poster"
    response = client.request("DELETE", "/api/catalog/match", json={"id": wrong_match.id})
    assert response.status_code == 200
    assert (response.json()["tmdbId"], response.json()["files"]) == (42, [])


@pytest.mark.parametrize("method", ["GET", "POST", "DELETE"])
@pytest.mark.parametrize(
    ("name", "status"), [("/etc/passwd", 403), ("missing.mkv", 404), ("not-a-video.txt", 404), ("Movies", 404)]
)
def test_progress_requires_existing_library_video(client, mock_download_dir, method, name, status):
    path = name if name.startswith("/") else str(mock_download_dir / name)
    if method == "GET":
        response = client.get("/api/progress", params={"path": path})
    else:
        body = {"path": path}
        if method == "POST":
            body.update(position=10, duration=100)
        response = client.request(method, "/api/progress", json=body)
    assert response.status_code == status


@pytest.mark.parametrize(("position", "duration"), [(-1, 100), (1, -100), ("NaN", 100), (1, "Infinity")])
def test_progress_requires_finite_nonnegative_seconds(client, mock_download_dir, position, duration):
    response = client.post(
        "/api/progress", json={"path": str(mock_download_dir / "tv.mp4"), "position": position, "duration": duration}
    )
    assert response.status_code == 422


@pytest.mark.parametrize("token", ["", "configured"])
def test_catalog_capabilities(client, monkeypatch, token):
    monkeypatch.setattr(config, "TMDB_TOKEN", token)
    assert client.get("/api/capabilities").json()["features"]["catalog"] == {
        "titles": True,
        "art": bool(token),
        "progress": True,
        "fileStreaming": True,
    }


def test_data_dir_is_read_at_call_time(client, mock_download_dir, monkeypatch, tmp_path):
    path = str(mock_download_dir / "tv.mp4")
    client.post("/api/progress", json={"path": path, "position": 10, "duration": 100})
    original = config.DATA_DIR
    monkeypatch.setattr(config, "DATA_DIR", tmp_path / "another-database")
    assert client.get("/api/progress", params={"path": path}).status_code == 404
    monkeypatch.setattr(config, "DATA_DIR", original)
    assert client.get("/api/progress", params={"path": path}).json()["position"] == 10


def test_progress_is_shared_between_devices(client, mock_download_dir, device_registry):
    write_registry(device_registry.path, [(DEVICE_KEY, "phone", False), ("second-key", "watch", False)])
    path = str(mock_download_dir / "tv.mp4")
    record = client.post("/api/progress", json={"path": path, "position": 12, "duration": 100}).json()
    headers = {"Authorization": "Bearer second-key"}
    assert client.get("/api/progress", params={"path": path}, headers=headers).json() == record
    updated = client.post("/api/progress", json={"path": path, "position": 25, "duration": 100}, headers=headers).json()
    assert client.get("/api/progress", params={"path": path}).json() == updated


def test_subtitle_choice_per_file_falls_back_to_the_titles_latest(client, catalog_dir, monkeypatch):
    episode = catalog_dir / OFFICE / NAMES[5][0]
    next_episode = catalog_dir / OFFICE / "The.Office.US.S02E02.1080p.BluRay.x265-RARBG.mkv"
    other_title = catalog_dir / TWIN_PEAKS / NAMES[7][0]
    clock = iter((100, 200, 300, 400))
    monkeypatch.setattr("library.time", SimpleNamespace(time=lambda: next(clock)))

    def choice(path):
        return client.get("/api/subtitle-choice", params={"path": str(path)}).json()

    def choose(path, subtitle):
        return client.post("/api/subtitle-choice", json={"path": str(path), "subtitle": subtitle})

    assert choice(episode) == {"path": str(episode), "subtitle": None}
    sidecar = {"kind": "sidecar", "label": "cn", "name": "The.Office.US.S02E01.1080p.BluRay.x265-RARBG-cn.srt"}
    assert choose(episode, sidecar).json() == {"path": str(episode), "subtitle": sidecar}
    assert choice(episode) == {"path": str(episode), "subtitle": sidecar}
    assert choice(next_episode) == {"path": str(next_episode), "subtitle": sidecar}
    assert choice(other_title)["subtitle"] is None

    assert choose(next_episode, {"kind": "off"}).status_code == 200
    assert choice(next_episode)["subtitle"] == {"kind": "off"}
    assert choice(episode)["subtitle"] == sidecar

    stream = {"kind": "stream", "index": 3, "language": "eng"}
    assert choose(other_title, stream).json()["subtitle"] == stream
    assert choose(episode, {"kind": "stream", "index": 2, "language": None}).json()["subtitle"] == {
        "kind": "stream",
        "index": 2,
    }
    assert choice(other_title)["subtitle"] == stream


@pytest.mark.parametrize(
    "subtitle",
    [{"kind": "embedded", "index": 1}, {"kind": "stream", "index": -1}, {"kind": "sidecar"}, None],
)
def test_subtitle_choice_rejects_unknown_shapes(client, mock_download_dir, subtitle):
    path = str(mock_download_dir / "tv.mp4")
    assert client.post("/api/subtitle-choice", json={"path": path, "subtitle": subtitle}).status_code == 422


@pytest.mark.parametrize("method", ["GET", "POST"])
@pytest.mark.parametrize(("name", "status"), [("/etc/passwd", 403), ("missing.mkv", 404), ("not-a-video.txt", 404)])
def test_subtitle_choice_requires_existing_library_video(client, mock_download_dir, method, name, status):
    path = name if name.startswith("/") else str(mock_download_dir / name)
    if method == "GET":
        response = client.get("/api/subtitle-choice", params={"path": path})
    else:
        response = client.post("/api/subtitle-choice", json={"path": path, "subtitle": {"kind": "off"}})
    assert response.status_code == status


def test_movie_file_order_and_multi_season_order(client, mock_download_dir, monkeypatch):
    root = mock_download_dir / "ordering"
    root.mkdir()
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    for directory, names in (
        ("Movie", ("Zeta.mkv", "Alpha.mp4", "Middle.mkv")),
        ("Show", ("Show.S02E01.mkv", "Extra.Zeta.mkv", "Show.S01E10.mkv", "Show.S01E02.mkv", "Extra.Alpha.mkv")),
    ):
        folder = root / directory
        folder.mkdir()
        for name in names:
            (folder / name).write_bytes(b"video")
    titles = {title["id"]: title for title in client.get("/api/catalog").json()["titles"]}
    assert [file["name"] for file in titles["Movie"]["files"]] == ["Alpha.mp4", "Middle.mkv", "Zeta.mkv"]
    assert [file["name"] for file in titles["Show"]["files"]] == [
        "Show.S01E02.mkv",
        "Show.S01E10.mkv",
        "Show.S02E01.mkv",
        "Extra.Alpha.mkv",
        "Extra.Zeta.mkv",
    ]


def test_catalog_does_not_follow_symlinks_outside_root(client, mock_download_dir, monkeypatch):
    root = mock_download_dir / "safe"
    root.mkdir()
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    (root / "outside.mp4").symlink_to(mock_download_dir / "tv.mp4")
    (root / "outside-folder").symlink_to(mock_download_dir / "Movies", target_is_directory=True)
    inside = root / "Movie"
    inside.mkdir()
    (inside / "movie.mkv").write_bytes(b"video")
    (inside / "movie.en.srt").symlink_to(mock_download_dir / "not-a-video.txt")
    (inside / "escaped.mkv").symlink_to(mock_download_dir / "tv.mp4")
    titles = client.get("/api/catalog").json()["titles"]
    assert len(titles) == 1
    assert titles[0]["id"] == "Movie"
    assert [file["name"] for file in titles[0]["files"]] == ["movie.mkv"]
    assert titles[0]["files"][0]["subtitles"] == []


@pytest.mark.parametrize("empty", [True, False])
def test_seasons_are_retried_then_cached(client, mock_download_dir, monkeypatch, httpx_mock, empty):
    root = mock_download_dir / "seasons"
    root.mkdir()
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    monkeypatch.setattr(config, "TMDB_TOKEN", "test-token")
    show = root / "Show"
    show.mkdir()
    for season in (1, 2):
        (show / f"Show.S{season:02}E01.mkv").write_bytes(b"episode")
    search = "https://api.themoviedb.org/3/search/tv?query=Show&language=en-US"
    season1 = "https://api.themoviedb.org/3/tv/42/season/1?language=en-US"
    season2 = "https://api.themoviedb.org/3/tv/42/season/2?language=en-US"
    httpx_mock.add_response(url=search, json={"results": [{"id": 42, "name": "Matched Show"}]})
    httpx_mock.add_response(url=re.compile(r"https://api.themoviedb.org/3/tv/42\?"), json={})
    httpx_mock.add_response(url=season1, status_code=503)
    httpx_mock.add_response(url=season2, json={"episodes": [{"episode_number": 1, "name": "Season two"}]})
    httpx_mock.add_response(url=season1, json={"episodes": [] if empty else [{"episode_number": 1, "name": "Pilot"}]})
    response = client.get("/api/catalog")
    assert response.status_code == 200
    files = response.json()["titles"][0]["files"]
    assert [file["episodeTitle"] for file in files] == [None, "Season two"]
    second = client.get("/api/catalog").json()
    files = second["titles"][0]["files"]
    assert [file["episodeTitle"] for file in files] == [None if empty else "Pilot", "Season two"]
    assert client.get("/api/catalog").json() == second
    assert len(httpx_mock.get_requests()) == 5


def test_double_episode_takes_its_place_in_the_season(client, mock_download_dir, monkeypatch, httpx_mock):
    root = mock_download_dir / "double"
    root.mkdir()
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    monkeypatch.setattr(config, "TMDB_TOKEN", "test-token")
    show = root / "Show.S03"
    show.mkdir()
    for name in ("Show.S03E11.mkv", "Show.S03E12E13.mkv", "Show.S03E14.mkv", "Show.S03E15-E16.mkv"):
        (show / name).write_bytes(b"episode")
    httpx_mock.add_response(
        url="https://api.themoviedb.org/3/search/tv?query=Show&language=en-US",
        json={"results": [{"id": 42, "name": "Show"}]},
    )
    httpx_mock.add_response(url=re.compile(r"https://api.themoviedb.org/3/tv/42\?"), json={})
    httpx_mock.add_response(
        url="https://api.themoviedb.org/3/tv/42/season/3?language=en-US",
        json={
            "episodes": [
                {"episode_number": 11, "name": "Back from Vacation", "runtime": 22},
                {"episode_number": 12, "name": "Traveling Salesmen", "runtime": 22},
                {"episode_number": 13, "name": "The Return", "runtime": 22},
                {"episode_number": 14, "name": "Ben Franklin", "runtime": 22},
                {"episode_number": 15, "name": "Phyllis' Wedding", "runtime": 22},
            ]
        },
    )
    files = client.get("/api/catalog").json()["titles"][0]["files"]
    assert [(file["season"], file["episode"], file["lastEpisode"]) for file in files] == [
        (3, 11, None),
        (3, 12, 13),
        (3, 14, None),
        (3, 15, 16),
    ]
    assert [file["episodeTitle"] for file in files] == [
        "Back from Vacation",
        "Traveling Salesmen / The Return",
        "Ben Franklin",
        "Phyllis' Wedding",
    ]
    # TMDB knows no sixteenth episode, so the runtime falls back to the first.
    assert [file["runtime"] for file in files] == [22, 44, 22, 22]

    for file in files[:3]:
        finish(client, file["path"])
    assert client.get("/api/catalog").json()["watched"] == []
    finish(client, files[3]["path"])
    assert ids(client.get("/api/catalog").json()["watched"]) == ["Show.S03"]


def test_uk_show_fallback_is_cached(client, mock_download_dir, monkeypatch, httpx_mock):
    root = mock_download_dir / "uk"
    root.mkdir()
    monkeypatch.setattr(config, "DOWNLOAD_DIR", root)
    monkeypatch.setattr(config, "TMDB_TOKEN", "test-token")
    (root / "The.Office.UK.S01E01.mkv").write_bytes(b"episode")
    httpx_mock.add_response(
        url="https://api.themoviedb.org/3/search/tv?query=The+Office+UK&language=en-US", json={"results": []}
    )
    httpx_mock.add_response(
        url="https://api.themoviedb.org/3/search/tv?query=The+Office&language=en-US", json={"results": []}
    )
    first = client.get("/api/catalog").json()
    assert first["titles"][0]["title"] == "The Office UK"
    assert first["titles"][0]["tmdbId"] is None
    assert client.get("/api/catalog").json() == first
    assert len(httpx_mock.get_requests()) == 2


def test_movie_details_and_new_art(client, one_movie, httpx_mock):
    httpx_mock.add_response(
        url=re.compile(r"https://api.themoviedb.org/3/search/movie\?"),
        json={"results": [{"id": 42, "title": "Matched Film"}]},
    )
    # Deliberately reverse the array: billing order is the explicit order field.
    cast = [
        {
            "id": index,
            "name": f"Actor {index}",
            "character": f"Role {index}",
            "order": index,
            "profile_path": f"/actor{index}.jpg" if index % 2 == 0 else None,
        }
        for index in reversed(range(15))
    ]
    httpx_mock.add_response(
        url=re.compile(r"https://api.themoviedb.org/3/movie/42\?"),
        json={
            "runtime": 121,
            "genres": [{"id": 2, "name": "Drama"}, {"id": 1, "name": "Comedy"}],
            "release_dates": {
                "results": [
                    {"iso_3166_1": "US", "release_dates": [{"certification": "R"}]},
                    {"iso_3166_1": "GB", "release_dates": [{"certification": ""}, {"certification": "15"}]},
                ]
            },
            "credits": {
                "cast": cast,
                "crew": [
                    {"id": 700, "name": "Writer", "job": "Writer", "profile_path": "/writer.jpg"},
                    {"id": 510, "name": "Tim Burton", "job": "Director", "profile_path": "/burton.jpg"},
                    *[{"id": 510 + index, "name": f"Director {index}", "job": "Director"} for index in range(1, 5)],
                ],
            },
            "images": {
                "logos": [
                    {"iso_639_1": "fr", "file_path": "/french.png"},
                    {"iso_639_1": None, "file_path": "/neutral.png"},
                    {"iso_639_1": "en", "file_path": "/english.png"},
                ]
            },
        },
    )
    httpx_mock.add_response(url="https://image.tmdb.org/t/p/w500/english.png", content=b"logo")
    httpx_mock.add_response(url="https://image.tmdb.org/t/p/w185/burton.jpg", content=b"burton")
    for index in range(0, 12, 2):
        httpx_mock.add_response(
            url=f"https://image.tmdb.org/t/p/w185/actor{index}.jpg", content=f"actor{index}".encode()
        )
    title = client.get("/api/catalog").json()["titles"][0]
    assert title["runtime"] == 121 and title["certification"] == "15"
    assert title["genres"] == ["Drama", "Comedy"]
    assert title["crew"] == [
        {"personId": 510, "name": "Tim Burton", "job": "Director", "profile": True},
        *[
            {"personId": 510 + index, "name": f"Director {index}", "job": "Director", "profile": False}
            for index in (1, 2)
        ],
    ]
    assert title["cast"] == [
        {"personId": index, "name": f"Actor {index}", "character": f"Role {index}", "profile": index % 2 == 0}
        for index in range(12)
    ]
    assert title["logo"] is True
    art = client.get("/api/art", params={"id": one_movie.name, "kind": "logo"})
    assert art.status_code == 200 and art.content == b"logo" and art.headers["content-type"] == "image/png"
    profile = client.get("/api/art", params={"id": one_movie.name, "kind": "profile", "person": 0})
    assert (
        profile.status_code == 200 and profile.content == b"actor0" and profile.headers["content-type"] == "image/jpeg"
    )
    director = client.get("/api/art", params={"id": one_movie.name, "kind": "profile", "person": 510})
    assert director.status_code == 200 and director.content == b"burton"
    # A file on disk alone never authorizes art for somebody outside the exposed cast and crew.
    for person in (14, 700, 514):
        tmdb.art_path(one_movie.name, "profile", person=person).write_bytes(b"not in the catalog entry")
    for params in (
        {"kind": "profile"},
        {"kind": "profile", "person": 14},
        {"kind": "profile", "person": 700},
        {"kind": "profile", "person": 514},
        {"kind": "profile", "person": 1},
        {"kind": "still", "season": 1, "episode": 1},
    ):
        assert client.get("/api/art", params={"id": one_movie.name, **params}).status_code == 404
    count = len(httpx_mock.get_requests())
    assert client.get("/api/catalog").json()["titles"][0] == title
    assert len(httpx_mock.get_requests()) == count == 10
    one_movie.unlink()
    for params in ({"kind": "logo"}, {"kind": "profile", "person": 0}, {"kind": "profile", "person": 510}):
        assert client.get("/api/art", params={"id": one_movie.name, **params}).status_code == 404
    assert len(httpx_mock.get_requests()) == count


def test_show_details_episode_art_and_old_cache_upgrade(client, one_movie, httpx_mock):
    episode = one_movie.with_name("Show.S01E01.mkv")
    one_movie.rename(episode)
    config.DATA_DIR.mkdir()
    # Seed the schema as shipped before rich metadata, including a season already marked cached.
    with sqlite3.connect(config.DATA_DIR / "library.db") as db:
        db.executescript("""
            CREATE TABLE matches (title_id TEXT PRIMARY KEY, tmdb_id INTEGER, title TEXT, year INTEGER,
                overview TEXT, poster_path TEXT, backdrop_path TEXT, looked_up REAL NOT NULL);
            CREATE TABLE seasons (tmdb_id INTEGER, season INTEGER, PRIMARY KEY (tmdb_id, season));
            CREATE TABLE episodes (tmdb_id INTEGER, season INTEGER, episode INTEGER, title TEXT,
                PRIMARY KEY (tmdb_id, season, episode));
            CREATE TABLE progress (path TEXT PRIMARY KEY, position REAL NOT NULL, duration REAL NOT NULL, updated INTEGER NOT NULL);
            INSERT INTO seasons VALUES (42, 1);
            INSERT INTO episodes VALUES (42, 1, 1, 'Old title');
        """)
        db.execute(
            "INSERT INTO matches VALUES (?, 42, 'Matched Show', 2005, 'Show overview', '/poster.jpg', NULL, 1000)",
            (episode.name,),
        )
        db.execute("INSERT INTO progress VALUES (?, 5, 100, 1001)", (str(episode),))
    poster = tmdb.art_path(episode.name, "poster")
    poster.parent.mkdir()
    poster.write_bytes(b"old poster")
    httpx_mock.add_response(
        url=re.compile(r"https://api.themoviedb.org/3/tv/42\?"),
        json={
            "episode_run_time": [0, 22, 30],
            "created_by": [{"id": 300 + index, "name": f"Creator {index}", "profile_path": None} for index in range(5)],
            "content_ratings": {
                "results": [{"iso_3166_1": "US", "rating": "TV-MA"}, {"iso_3166_1": "GB", "rating": "12"}]
            },
            "images": {
                "logos": [{"iso_639_1": "fr", "file_path": "/fr.png"}, {"iso_639_1": None, "file_path": "/neutral.png"}]
            },
        },
    )
    httpx_mock.add_response(url="https://image.tmdb.org/t/p/w500/neutral.png", content=b"neutral logo")
    httpx_mock.add_response(
        url="https://api.themoviedb.org/3/tv/42/season/1?language=en-US",
        json={
            "episodes": [
                {
                    "episode_number": 1,
                    "name": "Pilot",
                    "overview": "Episode overview",
                    "air_date": "2005-03-24",
                    "runtime": 23,
                    "still_path": "/pilot.jpg",
                },
                {"episode_number": 2, "name": "Not downloaded", "still_path": "/absent.jpg"},
            ]
        },
    )
    httpx_mock.add_response(url="https://image.tmdb.org/t/p/w300/pilot.jpg", content=b"pilot still")
    first = client.get("/api/catalog").json()
    title = first["titles"][0]
    assert title["runtime"] == 22 and title["certification"] == "12" and title["logo"] is True
    assert title["crew"] == [
        {"personId": 300 + index, "name": f"Creator {index}", "job": "Creator", "profile": False} for index in range(3)
    ]
    assert title["genres"] == title["cast"] == [] and title["matched"] == "auto"
    file = title["files"][0]
    assert (file["episodeTitle"], file["episodeOverview"], file["airDate"], file["runtime"], file["still"]) == (
        "Pilot",
        "Episode overview",
        "2005-03-24",
        23,
        True,
    )
    assert file["progress"]["position"] == 5
    assert first["continue"] == [{"titleId": episode.name, "path": str(episode)}]
    art = client.get("/api/art", params={"id": episode.name, "kind": "still", "season": 1, "episode": 1})
    assert art.status_code == 200 and art.content == b"pilot still" and art.headers["content-type"] == "image/jpeg"
    # Even cached season metadata and art cannot expose an episode absent from the title's files.
    tmdb.art_path(episode.name, "still", season=1, episode=2).write_bytes(b"outside files")
    for params in (
        {"kind": "still"},
        {"kind": "still", "season": 1},
        {"kind": "still", "season": 1, "episode": 2},
        {"kind": "still", "season": -1, "episode": 1},
    ):
        assert client.get("/api/art", params={"id": episode.name, **params}).status_code == 404
    assert client.get("/api/catalog").json() == first
    assert len(httpx_mock.get_requests()) == 4
    assert client.get("/api/art", params={"id": episode.name, "kind": "poster"}).content == b"old poster"
    episode.with_name(episode.name + ".aria2").touch()
    assert (
        client.get("/api/art", params={"id": episode.name, "kind": "still", "season": 1, "episode": 1}).status_code
        == 404
    )


@pytest.mark.parametrize("failure", ["http", "json", "network"])
def test_details_are_retried_without_repeating_search(client, one_movie, httpx_mock, failure):
    httpx_mock.add_response(json={"results": [{"id": 42, "title": "Matched"}]})
    if failure == "http":
        httpx_mock.add_response(status_code=503)
    elif failure == "json":
        httpx_mock.add_response(content=b"not json")
    else:
        httpx_mock.add_exception(httpx.ConnectError("offline"))
    httpx_mock.add_response(json={"runtime": 90})
    first = client.get("/api/catalog").json()["titles"][0]
    assert first["title"] == "Matched" and first["runtime"] is None
    second = client.get("/api/catalog").json()
    assert second["titles"][0]["runtime"] == 90
    assert client.get("/api/catalog").json() == second
    requests = httpx_mock.get_requests()
    assert len(requests) == 3 and requests[1].url == requests[2].url


@pytest.mark.parametrize("change", ["size", "mtime"])
def test_media_cache_and_file_invalidation(client, one_movie, monkeypatch, change):
    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    calls = []
    metadata = {
        "duration": 10.0,
        "video": {"codec": "h264", "width": 16, "height": 16, "bitDepth": 8, "hdr": None},
        "audio": [],
        "subtitles": [],
    }

    def probe(path, **kwargs):
        calls.append(path)
        return metadata

    monkeypatch.setattr("media.probe", probe)
    first = client.get("/api/catalog").json()
    assert first["titles"][0]["files"][0]["media"] is None
    library.close_media_probes()
    second = client.get("/api/catalog").json()
    assert second["titles"][0]["files"][0]["media"] == metadata
    assert calls == [one_movie]
    stat = one_movie.stat()
    if change == "size":
        one_movie.write_bytes(b"larger video")
        os.utime(one_movie, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    else:
        os.utime(one_movie, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1))
    third = client.get("/api/catalog").json()
    assert third["titles"][0]["files"][0]["media"] is None
    library.close_media_probes()
    assert client.get("/api/catalog").json()["titles"][0]["files"][0]["media"] == metadata
    assert calls == [one_movie, one_movie]


@pytest.mark.parametrize("failure", ["exit", "timeout", "json", "missing"])
def test_media_failures_are_cached(client, one_movie, monkeypatch, failure):
    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    calls = []

    def probe(path, **kwargs):
        calls.append(path)
        if failure == "exit":
            raise subprocess.CalledProcessError(1, "ffprobe")
        if failure == "timeout":
            raise subprocess.TimeoutExpired("ffprobe", 20)
        if failure == "json":
            raise ValueError("Invalid JSON")
        return None

    monkeypatch.setattr("media.probe", probe)
    first = client.get("/api/catalog").json()
    library.close_media_probes()
    assert first["titles"][0]["files"][0]["media"] is None
    assert client.get("/api/catalog").json() == first
    assert calls == [one_movie]


def test_media_probes_are_bounded_deduplicated_and_do_not_delay_catalog(client, one_movie, monkeypatch):
    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    for index in range(5):
        one_movie.with_name(f"Film{index}.mp4").write_bytes(b"movie")
    release, started = threading.Event(), threading.Event()
    calls, lock = [], threading.Lock()

    def probe(path, **kwargs):
        with lock:
            calls.append(path)
            if len(calls) == config.MEDIA_PROBE_CONCURRENCY:
                started.set()
        assert release.wait(5)
        return None

    monkeypatch.setattr("media.probe", probe)
    try:
        with ThreadPoolExecutor(max_workers=1) as requests:
            first = requests.submit(client.get, "/api/catalog").result(timeout=2).json()
            assert started.wait(1)
            assert requests.submit(client.get, "/api/catalog").result(timeout=2).json() == first
            assert len(calls) == config.MEDIA_PROBE_CONCURRENCY
            assert len(library._pending_probes) == 6
    finally:
        release.set()
        library.close_media_probes()
    assert len(calls) == len(set(calls))


def test_file_replaced_during_probe_is_not_cached(client, one_movie, monkeypatch):
    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    release, started = threading.Event(), threading.Event()

    def probe(path, **kwargs):
        started.set()
        assert release.wait(5)
        return {"duration": 10.0, "video": None, "audio": [], "subtitles": []}

    monkeypatch.setattr("media.probe", probe)
    try:
        assert client.get("/api/catalog").json()["titles"][0]["files"][0]["media"] is None
        assert started.wait(1)
        one_movie.write_bytes(b"replacement video")
    finally:
        release.set()
        library.close_media_probes()
    with library.database() as db:
        assert db.execute("SELECT * FROM media").fetchall() == []
    assert client.get("/api/catalog").json()["titles"][0]["files"][0]["media"] is None
    library.close_media_probes()
    assert client.get("/api/catalog").json()["titles"][0]["files"][0]["media"]["duration"] == 10.0


def test_completed_probe_is_not_requeued_from_a_stale_scan(client, one_movie, monkeypatch):
    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    calls = []

    def probe(path, **kwargs):
        calls.append(path)
        return None

    monkeypatch.setattr("media.probe", probe)
    client.get("/api/catalog")
    library.close_media_probes()
    stat = one_movie.stat()
    library._queue_probe(one_movie, stat.st_size, stat.st_mtime_ns)
    assert library._probe_executor is None
    assert calls == [one_movie]


def test_background_probe_keeps_its_database_destination(client, one_movie, monkeypatch, tmp_path):
    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    destination = config.DATA_DIR
    release, started = threading.Event(), threading.Event()

    def probe(path, **kwargs):
        started.set()
        assert release.wait(5)
        return None

    monkeypatch.setattr("media.probe", probe)
    try:
        client.get("/api/catalog")
        assert started.wait(1)
        monkeypatch.setattr(config, "DATA_DIR", tmp_path / "another-data-dir")
    finally:
        release.set()
        library.close_media_probes()
    with library.database(destination) as db:
        assert db.execute("SELECT path FROM media").fetchone()["path"] == str(one_movie)
    assert not config.DATA_DIR.exists()


@pytest.mark.parametrize("kind", ["logo", "profile", "still"])
def test_new_art_failures_are_retried_from_cached_metadata(client, one_movie, httpx_mock, kind):
    path = one_movie
    params = {"id": path.name, "kind": kind}
    if kind == "still":
        path = one_movie.with_name("Show.S01E01.mkv")
        one_movie.rename(path)
        params.update(id=path.name, season=1, episode=1)
    httpx_mock.add_response(json={"results": [{"id": 42, "title": "Matched", "name": "Matched"}]})
    if kind == "logo":
        httpx_mock.add_response(json={"images": {"logos": [{"iso_639_1": "en", "file_path": "/logo.png"}]}})
        image_url = "https://image.tmdb.org/t/p/w500/logo.png"
    elif kind == "profile":
        httpx_mock.add_response(json={"credits": {"cast": [{"id": 1, "name": "Actor", "profile_path": "/actor.jpg"}]}})
        params["person"] = 1
        image_url = "https://image.tmdb.org/t/p/w185/actor.jpg"
    else:
        httpx_mock.add_response(json={})
        httpx_mock.add_response(json={"episodes": [{"episode_number": 1, "still_path": "/episode.jpg"}]})
        image_url = "https://image.tmdb.org/t/p/w300/episode.jpg"
    httpx_mock.add_response(url=image_url, status_code=503)
    httpx_mock.add_response(url=image_url, content=b"recovered image")

    def available():
        title = client.get("/api/catalog").json()["titles"][0]
        if kind == "still":
            return title["files"][0]["still"]
        if kind == "profile":
            return title["cast"][0]["profile"]
        return title["logo"]

    assert available() is False
    assert client.get("/api/art", params=params).status_code == 404
    assert available() is True
    assert available() is True
    response = client.get("/api/art", params=params)
    assert response.status_code == 200 and response.content == b"recovered image"
    assert len(httpx_mock.get_requests()) == (5 if kind == "still" else 4)


def test_previous_schema_is_upgraded_in_place(client, one_movie, httpx_mock):
    config.DATA_DIR.mkdir()
    # The schema as shipped before crew person ids and manual matches, with crew cached by name only.
    old_metadata = (
        '{"logo_path": null, "runtime": 100, "certification": null, "genres": ["Drama"],'
        ' "crew": [{"name": "Tim Burton", "job": "Director"}],'
        ' "cast": [{"personId": 1, "name": "Actor", "character": "Role", "profile_path": "/actor.jpg"}]}'
    )
    with sqlite3.connect(config.DATA_DIR / "library.db") as db:
        db.executescript("""
            CREATE TABLE matches (title_id TEXT PRIMARY KEY, tmdb_id INTEGER, title TEXT, year INTEGER,
                overview TEXT, poster_path TEXT, backdrop_path TEXT, looked_up REAL NOT NULL, metadata TEXT);
            CREATE TABLE seasons (tmdb_id INTEGER, season INTEGER, enriched INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (tmdb_id, season));
            CREATE TABLE episodes (tmdb_id INTEGER, season INTEGER, episode INTEGER, title TEXT,
                overview TEXT, air_date TEXT, runtime INTEGER, still_path TEXT, PRIMARY KEY (tmdb_id, season, episode));
            CREATE TABLE progress (path TEXT PRIMARY KEY, position REAL NOT NULL, duration REAL NOT NULL, updated INTEGER NOT NULL);
            CREATE TABLE media (path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, metadata TEXT);
        """)
        db.execute(
            "INSERT INTO matches VALUES (?, 42, 'Sweeney Todd', 2007, 'Overview', '/poster.jpg', NULL, 1000, ?)",
            (one_movie.name, old_metadata),
        )
        db.execute("INSERT INTO progress VALUES (?, 5, 100, 1001)", (str(one_movie),))
    for kind, identity in (("poster", {}), ("profile", {"person": 1})):
        path = tmdb.art_path(one_movie.name, kind, **identity)
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(b"cached " + kind.encode())
    httpx_mock.add_response(
        url=re.compile(r"https://api.themoviedb.org/3/movie/42\?"),
        json={
            "title": "Sweeney Todd",
            "poster_path": "/poster.jpg",
            "runtime": 116,
            "credits": {
                "cast": [{"id": 1, "name": "Actor", "character": "Role", "profile_path": "/actor.jpg"}],
                "crew": [{"id": 510, "name": "Tim Burton", "job": "Director", "profile_path": "/burton.jpg"}],
            },
        },
    )
    httpx_mock.add_response(url="https://image.tmdb.org/t/p/w185/burton.jpg", content=b"burton")
    first = client.get("/api/catalog").json()
    title = first["titles"][0]
    assert (title["tmdbId"], title["matched"], title["runtime"]) == (42, "auto", 116)
    assert title["crew"] == [{"personId": 510, "name": "Tim Burton", "job": "Director", "profile": True}]
    assert title["cast"][0]["profile"] is True and title["poster"] is True
    assert title["files"][0]["progress"]["position"] == 5
    # Only the details and the new crew photo are fetched: no search, cached images are kept.
    assert len(httpx_mock.get_requests()) == 2
    assert client.get("/api/art", params={"id": one_movie.name, "kind": "poster"}).content == b"cached poster"
    assert client.get("/api/catalog").json() == first
    assert len(httpx_mock.get_requests()) == 2
    with sqlite3.connect(config.DATA_DIR / "library.db") as db:
        assert db.execute("SELECT manual FROM matches").fetchall() == [(0,)]
        assert db.execute("SELECT COUNT(*) FROM candidates").fetchone() == (0,)


@pytest.fixture
def wrong_match(client, one_movie, httpx_mock):
    """Film.2020.mkv matched automatically to the wrong TMDB movie."""

    def add():
        httpx_mock.add_response(
            url="https://api.themoviedb.org/3/search/movie?query=Film&language=en-US&year=2020",
            json={
                "results": [
                    {"id": 42, "title": "Wrong Film", "release_date": "2020-01-01", "poster_path": "/wrong.jpg"}
                ]
            },
        )
        httpx_mock.add_response(
            url=re.compile(r"https://api.themoviedb.org/3/movie/42\?"),
            json={"title": "Wrong Film", "release_date": "2020-01-01", "poster_path": "/wrong.jpg"},
        )
        httpx_mock.add_response(url="https://image.tmdb.org/t/p/w500/wrong.jpg", content=b"wrong poster")

    add()
    title = client.get("/api/catalog").json()["titles"][0]
    assert (title["tmdbId"], title["title"], title["matched"]) == (42, "Wrong Film", "auto")
    return SimpleNamespace(id=one_movie.name, path=one_movie, auto=add)


def test_search_returns_ten_candidates_and_their_posters(client, wrong_match, httpx_mock):
    results = [
        {
            "id": 100 + index,
            "title": f"Candidate {index}",
            "release_date": f"{1990 + index}-06-01" if index else "",
            "overview": f"Overview {index}" if index != 1 else "",
            "poster_path": f"/candidate{index}.jpg" if index % 2 == 0 else None,
        }
        for index in range(12)
    ]
    # The default query is the title's current name, without the year the automatic match uses.
    httpx_mock.add_response(
        url="https://api.themoviedb.org/3/search/movie?query=Wrong+Film&language=en-US", json={"results": results}
    )
    for index in range(0, 10, 2):
        httpx_mock.add_response(
            url=f"https://image.tmdb.org/t/p/w185/candidate{index}.jpg", content=f"candidate{index}".encode()
        )
    response = client.get("/api/catalog/search", params={"id": wrong_match.id})
    assert response.status_code == 200
    candidates = response.json()
    assert candidates == [
        {
            "tmdbId": 100 + index,
            "title": f"Candidate {index}",
            "year": 1990 + index if index else None,
            "overview": f"Overview {index}" if index != 1 else None,
            "poster": index % 2 == 0,
        }
        for index in range(10)
    ]

    def poster(tmdb_id):
        return client.get("/api/catalog/poster", params={"id": wrong_match.id, "tmdbId": tmdb_id})

    first = poster(100)
    assert first.status_code == 200 and first.content == b"candidate0" and first.headers["content-type"] == "image/jpeg"
    # A cached file alone never serves a poster the latest search did not return.
    tmdb.art_path(wrong_match.id, "candidate", tmdb_id=110).write_bytes(b"outside the results")
    for tmdb_id in (101, 110, 42):
        assert poster(tmdb_id).status_code == 404
    assert client.get("/api/catalog/poster", params={"id": "Other.mkv", "tmdbId": 100}).status_code == 404

    httpx_mock.add_response(
        url="https://api.themoviedb.org/3/search/movie?query=Film+Again&language=en-US",
        json={"results": [results[2], {"id": 200, "title": "Fresh", "poster_path": "/fresh.jpg"}]},
    )
    httpx_mock.add_response(url="https://image.tmdb.org/t/p/w185/fresh.jpg", content=b"fresh")
    second = client.get("/api/catalog/search", params={"id": wrong_match.id, "query": " Film Again "}).json()
    assert [(candidate["tmdbId"], candidate["poster"]) for candidate in second] == [(102, True), (200, True)]
    assert poster(102).content == b"candidate2" and poster(200).content == b"fresh"
    assert poster(100).status_code == 404
    assert not tmdb.art_path(wrong_match.id, "candidate", tmdb_id=100).exists()
    # Search and posters never touch the title's match.
    assert client.get("/api/catalog").json()["titles"][0]["matched"] == "auto"
    assert len(httpx_mock.get_requests()) == 3 + 1 + 5 + 1 + 1


def test_search_for_a_show_uses_tv_fields(client, one_movie, httpx_mock):
    episode = one_movie.with_name("Show.S01E01.mkv")
    one_movie.rename(episode)
    httpx_mock.add_response(
        url="https://api.themoviedb.org/3/search/tv?query=Twin+Peaks&language=en-US",
        json={"results": [{"id": 1920, "name": "Twin Peaks", "first_air_date": "1990-04-08", "overview": "FBI"}]},
    )
    response = client.get("/api/catalog/search", params={"id": episode.name, "query": "Twin Peaks"})
    assert response.json() == [
        {"tmdbId": 1920, "title": "Twin Peaks", "year": 1990, "overview": "FBI", "poster": False}
    ]


def test_manual_match_outlives_rescans_and_restarts(client, wrong_match, httpx_mock):
    httpx_mock.add_response(
        url=re.compile(r"https://api.themoviedb.org/3/movie/7\?"),
        json={
            "id": 7,
            "title": "Right Film",
            "release_date": "1999-05-05",
            "overview": "Right overview",
            "poster_path": "/right.jpg",
            "credits": {"crew": [{"id": 510, "name": "Tim Burton", "job": "Director", "profile_path": "/burton.jpg"}]},
        },
    )
    httpx_mock.add_response(url="https://image.tmdb.org/t/p/w500/right.jpg", content=b"right poster")
    httpx_mock.add_response(url="https://image.tmdb.org/t/p/w185/burton.jpg", content=b"burton")
    response = client.post("/api/catalog/match", json={"id": wrong_match.id, "tmdbId": 7})
    assert response.status_code == 200
    title = response.json()
    assert (title["tmdbId"], title["title"], title["year"], title["overview"], title["matched"]) == (
        7,
        "Right Film",
        1999,
        "Right overview",
        "manual",
    )
    assert title["crew"] == [{"personId": 510, "name": "Tim Burton", "job": "Director", "profile": True}]
    assert client.get("/api/art", params={"id": wrong_match.id, "kind": "poster"}).content == b"right poster"
    count = len(httpx_mock.get_requests())
    assert client.get("/api/catalog").json()["titles"] == [title]

    hidden = wrong_match.path.with_name(".hidden.mkv")
    wrong_match.path.rename(hidden)
    assert client.get("/api/catalog").json()["titles"] == []
    hidden.rename(wrong_match.path)
    assert client.get("/api/catalog").json()["titles"] == [title]

    library._title_locks.clear()
    restarted = TestClient(app, base_url=INTERLACE, client=PHONE, headers={"Authorization": f"Bearer {DEVICE_KEY}"})
    assert restarted.get("/api/catalog").json()["titles"] == [title]
    assert len(httpx_mock.get_requests()) == count
    with sqlite3.connect(config.DATA_DIR / "library.db") as db:
        assert db.execute("SELECT tmdb_id, manual FROM matches").fetchall() == [(7, 1)]

    wrong_match.auto()
    response = client.request("DELETE", "/api/catalog/match", json={"id": wrong_match.id})
    assert response.status_code == 200
    title = response.json()
    assert (title["tmdbId"], title["title"], title["matched"], title["crew"]) == (42, "Wrong Film", "auto", [])
    assert client.get("/api/art", params={"id": wrong_match.id, "kind": "poster"}).content == b"wrong poster"
    assert client.get("/api/art", params={"id": wrong_match.id, "kind": "profile", "person": 510}).status_code == 404
    assert client.get("/api/catalog").json()["titles"] == [title]
    # Dropping a match that is already automatic changes nothing.
    count = len(httpx_mock.get_requests())
    assert client.request("DELETE", "/api/catalog/match", json={"id": wrong_match.id}).json() == title
    assert len(httpx_mock.get_requests()) == count


def test_match_to_an_unknown_tmdb_id_is_refused(client, wrong_match, httpx_mock):
    httpx_mock.add_response(url=re.compile(r"https://api.themoviedb.org/3/movie/999999\?"), status_code=404)
    response = client.post("/api/catalog/match", json={"id": wrong_match.id, "tmdbId": 999999})
    assert response.status_code == 404
    title = client.get("/api/catalog").json()["titles"][0]
    assert (title["tmdbId"], title["matched"], title["poster"]) == (42, "auto", True)
    assert len(httpx_mock.get_requests()) == 4


def test_matching_rejects_bad_input(client, one_movie, monkeypatch, httpx_mock):
    for body in (
        {"id": one_movie.name},
        {"id": one_movie.name, "tmdbId": "seven"},
        {"id": one_movie.name, "tmdbId": 0},
    ):
        assert client.post("/api/catalog/match", json=body).status_code == 422
    assert client.request("DELETE", "/api/catalog/match", json={}).status_code == 422
    assert client.get("/api/catalog/search").status_code == 422
    assert client.get("/api/catalog/poster", params={"id": one_movie.name, "tmdbId": "x"}).status_code == 422
    for name in ("Missing.mkv", "../Film.2020.mkv", ".hidden"):
        assert client.get("/api/catalog/search", params={"id": name}).status_code == 404
        assert client.post("/api/catalog/match", json={"id": name, "tmdbId": 7}).status_code == 404
        assert client.request("DELETE", "/api/catalog/match", json={"id": name}).status_code == 404
    httpx_mock.add_response(status_code=503)
    assert client.get("/api/catalog/search", params={"id": one_movie.name}).status_code == 502
    monkeypatch.setattr(config, "TMDB_TOKEN", "")
    assert client.get("/api/catalog/search", params={"id": one_movie.name}).status_code == 503
    assert client.post("/api/catalog/match", json={"id": one_movie.name, "tmdbId": 7}).status_code == 503
    assert client.request("DELETE", "/api/catalog/match", json={"id": one_movie.name}).status_code == 503
    assert client.get("/api/catalog/poster", params={"id": one_movie.name, "tmdbId": 7}).status_code == 404
