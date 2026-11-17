"""Library titles, cached metadata and shared playback progress."""

import asyncio
import json
import logging
import re
import sqlite3
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

import httpx
from starlette.concurrency import run_in_threadpool

import config
import media
import tmdb

logger = logging.getLogger("interlace.library")
_schema_lock = threading.Lock()
_probe_lock = threading.Lock()
_probe_executor: ThreadPoolExecutor | None = None
_pending_probes: set[tuple[Path, str]] = set()
# Enrichment and manual matching of one title never interleave.
_title_locks: dict[str, asyncio.Lock] = {}

VIDEO_EXT = {
    ".mkv",
    ".mp4",
    ".avi",
    ".mov",
    ".m4v",
    ".ts",
    ".m2ts",
    ".webm",
    ".flv",
    ".wmv",
    ".mpg",
    ".mpeg",
}
SUBTITLE_SUFFIXES = {".srt", ".ass", ".ssa", ".vtt"}
_SEASON = re.compile(r"\b(?:S(\d{1,3})(?:E(\d{1,3}))?|SEASON\s+(\d{1,3}))\b", re.IGNORECASE)
_EPISODE = re.compile(r"\bS(\d{1,3})E(\d{1,3})\b", re.IGNORECASE)
_YEAR = re.compile(r"\b(?:19|20)\d{2}\b")
_RELEASE = re.compile(
    r"\b(?:\d{3,4}[pi]|[48]K|BluRay|Blu-Ray|BDRip|BRRip|DVDRip|DVD|HDTV|WEB(?:-?DL|-?Rip)?|"
    r"REMASTERED|REPACK\d*|PROPER|UHD|[xh][ .-]?26[45]|HEVC|AVC|Criterion|COMPLETE|"
    r"\d{1,2}bit|AAC|DDP|DTS|AC3|DoVi|HDR\d*|REMUX)\b",
    re.IGNORECASE,
)
_SAMPLE = re.compile(r"(?:^|[\W_])sample(?:$|[\W_])", re.IGNORECASE)
_FIELDS = {"movie": ("title", "release_date"), "show": ("name", "first_air_date")}
_MATCH_COLUMNS = (
    "title_id",
    "tmdb_id",
    "title",
    "year",
    "overview",
    "poster_path",
    "backdrop_path",
    "looked_up",
    "metadata",
    "manual",
)
_TMDB_FAILURES = (httpx.HTTPError, ValueError, KeyError, TypeError)


class NotFound(LookupError):
    """The title, or the TMDB entry a manual match names, does not exist."""


class TMDBError(RuntimeError):
    """TMDB could not answer a matching request."""


@dataclass(frozen=True)
class ParsedName:
    title: str
    year: int | None = None
    season: int | None = None
    episode: int | None = None


def parse_name(name: str) -> ParsedName | None:
    suffix = Path(name).suffix.lower()
    if name.startswith(".") or suffix in SUBTITLE_SUFFIXES | {".tmp", ".txt", ".aria2", ".torrent", ".nfo"}:
        return None
    if suffix in VIDEO_EXT:
        name = name[: -len(suffix)]
    name = re.sub(r"^www\.\S+\s+-\s*", "", name, flags=re.IGNORECASE)
    name = re.sub(r"[._]", " ", name).strip()
    season_match = _SEASON.search(name)
    season = episode = None
    boundaries = []
    if season_match:
        season = int(season_match[1] or season_match[3])
        boundaries.append(season_match.start())
    episode_match = _EPISODE.search(name)
    if episode_match:
        season, episode = int(episode_match[1]), int(episode_match[2])
    release = _RELEASE.search(name)
    if release:
        boundaries.append(release.start())
    group = re.search(r"[\[(]", name)
    if group:
        boundaries.append(group.start())
    year = None
    for match in _YEAR.finditer(name):
        # A leading number can itself be the title, as in "1917 (2019)".
        if re.search(r"\w", name[: match.start()]):
            if match.start() <= min(boundaries, default=len(name)) or (
                group and group.start() < match.start() and not name[group.end() : match.start()].strip()
            ):
                year = int(match[0])
                boundaries.append(match.start())
            break
    title = " ".join(name[: min(boundaries, default=len(name))].split()).strip(" -([{ ")
    return ParsedName(title, year, season, episode) if title else None


@contextmanager
def database(data_dir: Path | None = None):
    data_dir = data_dir if data_dir is not None else config.DATA_DIR
    data_dir.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(data_dir / "library.db", timeout=10)
    connection.row_factory = sqlite3.Row
    try:
        with _schema_lock:
            connection.executescript("""
            CREATE TABLE IF NOT EXISTS matches (
                title_id TEXT PRIMARY KEY, tmdb_id INTEGER, title TEXT, year INTEGER,
                overview TEXT, poster_path TEXT, backdrop_path TEXT, looked_up REAL NOT NULL, metadata TEXT,
                manual INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS candidates (
                title_id TEXT, tmdb_id INTEGER, poster_path TEXT, PRIMARY KEY (title_id, tmdb_id)
            );
            CREATE TABLE IF NOT EXISTS seasons (
                tmdb_id INTEGER, season INTEGER, enriched INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (tmdb_id, season)
            );
            CREATE TABLE IF NOT EXISTS episodes (
                tmdb_id INTEGER, season INTEGER, episode INTEGER, title TEXT,
                overview TEXT, air_date TEXT, runtime INTEGER, still_path TEXT,
                PRIMARY KEY (tmdb_id, season, episode)
            );
            CREATE TABLE IF NOT EXISTS progress (
                path TEXT PRIMARY KEY, position REAL NOT NULL, duration REAL NOT NULL, updated INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS media (
                path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, metadata TEXT
            );
            """)
            # Null metadata / enriched=0 distinguish old caches from known absent TMDB fields.
            for table, additions in {
                "matches": {"metadata": "TEXT", "manual": "INTEGER NOT NULL DEFAULT 0"},
                "seasons": {"enriched": "INTEGER NOT NULL DEFAULT 0"},
                "episodes": {"overview": "TEXT", "air_date": "TEXT", "runtime": "INTEGER", "still_path": "TEXT"},
            }.items():
                columns = {row["name"] for row in connection.execute(f"PRAGMA table_info({table})")}
                for name, definition in additions.items():
                    if name not in columns:
                        connection.execute(f"ALTER TABLE {table} ADD COLUMN {name} {definition}")
                        if (table, name) == ("matches", "manual"):
                            # Crew cached before it carried person ids is refetched with the rest of the details.
                            connection.execute("UPDATE matches SET metadata = NULL")
            connection.commit()
        with connection:
            yield connection
    finally:
        connection.close()


def _progress_record(row: sqlite3.Row) -> dict:
    return {
        "path": row["path"],
        "position": row["position"],
        "duration": row["duration"],
        "finished": row["duration"] > 0 and row["position"] >= 0.9 * row["duration"],
        "updated": int(row["updated"]),
    }


def get_progress(path: Path) -> dict | None:
    with database() as db:
        row = db.execute("SELECT * FROM progress WHERE path = ?", (str(path),)).fetchone()
    return _progress_record(row) if row else None


def save_progress(path: Path, position: float, duration: float) -> dict:
    with database() as db:
        # Replacing the row gives every write a fresh rowid to break same-second ties.
        row = db.execute(
            "INSERT OR REPLACE INTO progress VALUES (?, ?, ?, ?) RETURNING *",
            (str(path), position, duration, int(time.time())),
        ).fetchone()
    return _progress_record(row)


def delete_progress(path: Path) -> None:
    with database() as db:
        db.execute("DELETE FROM progress WHERE path = ?", (str(path),))


def _probe_and_save(path: Path, size: int, mtime_ns: int, data_dir: Path, probe, settings: dict) -> None:
    try:
        try:
            metadata = probe(path, **settings)
        except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
            logger.warning("Media probe failed for %s: %s", path, error)
            metadata = None
        # A download or replacement during probing must never populate the new file's cache.
        stat = path.stat()
        if (stat.st_size, stat.st_mtime_ns) == (size, mtime_ns):
            with database(data_dir) as db:
                db.execute(
                    "INSERT OR REPLACE INTO media VALUES (?, ?, ?, ?)",
                    (str(path), size, mtime_ns, json.dumps(metadata) if metadata is not None else None),
                )
    except (OSError, sqlite3.Error) as error:
        logger.warning("Media cache failed for %s: %s", path, error)
    finally:
        with _probe_lock:
            _pending_probes.discard((data_dir, str(path)))


def _queue_probe(path: Path, size: int, mtime_ns: int) -> None:
    global _probe_executor
    data_dir = config.DATA_DIR.resolve()
    key = (data_dir, str(path))
    with _probe_lock:
        if key in _pending_probes:
            return
        # Another catalog's job may have completed since scan read its cache snapshot.
        with database(data_dir) as db:
            if db.execute(
                "SELECT 1 FROM media WHERE path = ? AND size = ? AND mtime_ns = ?", (str(path), size, mtime_ns)
            ).fetchone():
                return
        if _probe_executor is None:
            _probe_executor = ThreadPoolExecutor(
                max_workers=config.MEDIA_PROBE_CONCURRENCY, thread_name_prefix="media-probe"
            )
        _pending_probes.add(key)
        _probe_executor.submit(
            _probe_and_save,
            path,
            size,
            mtime_ns,
            data_dir,
            media.probe,
            {
                "ffprobe_path": config.FFPROBE_PATH,
                "ffmpeg_path": config.FFMPEG_PATH,
                "runtime_dir": config.FFMPEG_RUNTIME_DIR,
                "timeout": config.MEDIA_PROBE_TIMEOUT,
            },
        )


def close_media_probes() -> None:
    global _probe_executor
    with _probe_lock:
        executor, _probe_executor = _probe_executor, None
    if executor is not None:
        executor.shutdown(wait=True, cancel_futures=True)
    with _probe_lock:
        _pending_probes.clear()


def _visible_file(path: Path, root: Path) -> bool:
    return root in path.resolve().parents and not any(part.startswith(".") for part in path.relative_to(root).parts)


def _video(path: Path, root: Path) -> bool:
    return (
        _visible_file(path, root)
        and path.is_file()
        and path.suffix.lower() in VIDEO_EXT
        and not path.with_name(path.name + ".aria2").exists()
        and not _SAMPLE.search(path.stem)
    )


def _file(path: Path, root: Path, progress: dict, media_cache: dict) -> dict:
    parsed = parse_name(path.name)
    subtitles = [
        {
            "path": str(subtitle.resolve()),
            "name": subtitle.name,
            "label": subtitle.stem[len(path.stem) :].lstrip(".-_ "),
        }
        for subtitle in sorted(path.parent.iterdir())
        if subtitle.suffix.lower() in SUBTITLE_SUFFIXES
        and subtitle.name.startswith(path.stem)
        and subtitle.is_file()
        and _visible_file(subtitle, root)
    ]
    name = path.name
    path = path.resolve()
    stat = path.stat()
    record = progress.get(str(path))
    cached = media_cache.get(str(path))
    metadata = None
    if cached and (cached["size"], cached["mtime_ns"]) == (stat.st_size, stat.st_mtime_ns):
        metadata = json.loads(cached["metadata"]) if cached["metadata"] else None
    else:
        _queue_probe(path, stat.st_size, stat.st_mtime_ns)
    return {
        "path": str(path.resolve()),
        "name": name,
        "size": stat.st_size,
        "season": parsed.season if parsed and parsed.episode is not None else None,
        "episode": parsed.episode if parsed else None,
        "episodeTitle": None,
        "episodeOverview": None,
        "airDate": None,
        "runtime": None,
        "still": False,
        "media": metadata,
        "subtitles": subtitles,
        "progress": {key: value for key, value in record.items() if key != "path"} if record else None,
    }


def _videos(entry: Path, root: Path) -> list[Path]:
    if entry.name.startswith(".") or root not in entry.resolve().parents or parse_name(entry.name) is None:
        return []
    if entry.is_dir():
        return [path for path in entry.rglob("*") if _video(path, root)]
    return [entry] if _video(entry, root) else []


def _entry(title_id: str) -> tuple[Path, list[Path]] | None:
    """The entry a title id names and its videos, or None when the id names no title."""
    if not title_id or "\0" in title_id or Path(title_id).name != title_id:
        return None
    entry = config.DOWNLOAD_DIR.resolve() / title_id
    videos = _videos(entry, entry.parent)
    return (entry, videos) if videos else None


def _file_state() -> tuple[dict, dict]:
    with database() as db:
        progress = {row["path"]: _progress_record(row) for row in db.execute("SELECT * FROM progress")}
        media_cache = {row["path"]: dict(row) for row in db.execute("SELECT * FROM media")}
    return progress, media_cache


def _title(entry: Path, videos: list[Path], progress: dict, media_cache: dict) -> dict:
    parsed = parse_name(entry.name)
    files = [_file(path, entry.parent, progress, media_cache) for path in videos]
    kind = "show" if any(file["episode"] is not None for file in files) else "movie"
    files.sort(
        key=lambda file: (
            (
                file["episode"] is None,
                file["season"] if file["season"] is not None else 0,
                file["episode"] if file["episode"] is not None else 0,
                file["name"],
                file["path"],
            )
            if kind == "show"
            else (file["name"], file["path"])
        )
    )
    return {
        "id": entry.name,
        "kind": kind,
        "title": parsed.title,
        "year": parsed.year,
        "overview": None,
        "tmdbId": None,
        "poster": False,
        "backdrop": False,
        "logo": False,
        "runtime": None,
        "certification": None,
        "genres": [],
        "crew": [],
        "matched": None,
        "cast": [],
        "added": int(entry.stat().st_mtime),
        "files": files,
    }


def scan() -> list[dict]:
    root = config.DOWNLOAD_DIR.resolve()
    if not root.is_dir():
        return []
    progress, media_cache = _file_state()
    titles = [
        _title(entry, videos, progress, media_cache)
        for entry in sorted(root.iterdir())
        if (videos := _videos(entry, root))
    ]
    titles.sort(key=lambda title: (-title["added"], title["id"]))
    return titles


def scan_title(title_id: str) -> dict | None:
    found = _entry(title_id)
    return _title(*found, *_file_state()) if found else None


def _match(title_id: str) -> dict | None:
    with database() as db:
        row = db.execute("SELECT * FROM matches WHERE title_id = ?", (title_id,)).fetchone()
    return dict(row) if row else None


def _year(date: str | None) -> int | None:
    date = date or ""
    return int(date[:4]) if date[:4].isdigit() else None


def _record(title: dict, result: dict | None, *, manual: bool = False) -> dict:
    result = result or {}
    name, date = _FIELDS[title["kind"]]
    return {
        "title_id": title["id"],
        "tmdb_id": result.get("id"),
        "title": result.get(name),
        "year": _year(result.get(date)),
        "overview": result.get("overview"),
        "poster_path": result.get("poster_path"),
        "backdrop_path": result.get("backdrop_path"),
        "looked_up": time.time(),
        "metadata": None,
        "manual": int(manual),
    }


def _with_details(kind: str, match: dict, details: dict) -> dict:
    match = match | {"metadata": json.dumps(tmdb.parse_details(kind, details))}
    name, date = _FIELDS[kind]
    for source, target in {
        name: "title",
        "overview": "overview",
        "poster_path": "poster_path",
        "backdrop_path": "backdrop_path",
    }.items():
        if source in details:
            match[target] = details[source]
    if date in details:
        match["year"] = _year(details[date])
    return match


def _store(match: dict) -> dict:
    with database() as db:
        db.execute(
            f"INSERT OR REPLACE INTO matches ({', '.join(_MATCH_COLUMNS)}) "
            f"VALUES ({', '.join(':' + column for column in _MATCH_COLUMNS)})",
            match,
        )
    return match


def _season_cached(tmdb_id: int, season: int) -> bool:
    with database() as db:
        return (
            db.execute(
                "SELECT 1 FROM seasons WHERE tmdb_id = ? AND season = ? AND enriched = 1", (tmdb_id, season)
            ).fetchone()
            is not None
        )


def _save_season(tmdb_id: int, season: int, episodes: list[dict]) -> None:
    with database() as db:
        db.executemany(
            "INSERT OR REPLACE INTO episodes (tmdb_id, season, episode, title, overview, air_date, runtime, still_path) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    tmdb_id,
                    season,
                    episode["episode_number"],
                    episode.get("name"),
                    episode.get("overview") or None,
                    episode.get("air_date") or None,
                    episode.get("runtime") or None,
                    episode.get("still_path"),
                )
                for episode in episodes
            ],
        )
        db.execute("INSERT OR REPLACE INTO seasons (tmdb_id, season, enriched) VALUES (?, ?, 1)", (tmdb_id, season))


def _episodes(tmdb_id: int) -> dict:
    with database() as db:
        return {
            (row["season"], row["episode"]): dict(row)
            for row in db.execute(
                "SELECT * FROM episodes WHERE tmdb_id = ?",
                (tmdb_id,),
            )
        }


async def _enrich(title: dict, client: httpx.AsyncClient) -> None:
    match = await run_in_threadpool(_match, title["id"])
    if match is None:
        try:
            result = await tmdb.best_match(client, title["kind"], title["title"], title["year"])
            match = await run_in_threadpool(_store, _record(title, result))
        except _TMDB_FAILURES as error:
            logger.warning("TMDB search failed for %s: %s", title["id"], error)
            return
    if match["tmdb_id"] is None:
        return
    if match["metadata"] is None:
        try:
            details = await tmdb.details(client, title["kind"], match["tmdb_id"])
            match = await run_in_threadpool(_store, _with_details(title["kind"], match, details))
        except _TMDB_FAILURES as error:
            logger.warning("TMDB details failed for %s: %s", title["id"], error)
    title.update(
        title=match["title"],
        year=match["year"],
        overview=match["overview"],
        tmdbId=match["tmdb_id"],
        matched="manual" if match["manual"] else "auto",
    )
    metadata = json.loads(match["metadata"]) if match["metadata"] is not None else {}
    for key in ("runtime", "certification", "genres"):
        if key in metadata:
            title[key] = metadata[key]
    for kind in ("poster", "backdrop", "logo"):
        source = metadata.get("logo_path") if kind == "logo" else match[f"{kind}_path"]
        title[kind] = await _cache_art(client, title["id"], kind, source)
    for group in ("crew", "cast"):
        for person in metadata.get(group, []):
            profile = await _cache_art(
                client, title["id"], "profile", person["profile_path"], person=person["personId"]
            )
            title[group].append(
                {key: value for key, value in person.items() if key != "profile_path"} | {"profile": profile}
            )
    if title["kind"] == "show":
        seasons = sorted({file["season"] for file in title["files"] if file["episode"] is not None})
        for season in seasons:
            if await run_in_threadpool(_season_cached, match["tmdb_id"], season):
                continue
            try:
                episodes = await tmdb.season(client, match["tmdb_id"], season)
                await run_in_threadpool(_save_season, match["tmdb_id"], season, episodes)
            except _TMDB_FAILURES as error:
                logger.warning("TMDB season failed for %s: %s", title["id"], error)
        episodes = await run_in_threadpool(_episodes, match["tmdb_id"])
        for file in title["files"]:
            episode = episodes.get((file["season"], file["episode"]))
            if episode is not None:
                file.update(
                    episodeTitle=episode["title"],
                    episodeOverview=episode["overview"],
                    airDate=episode["air_date"],
                    runtime=episode["runtime"],
                )
                file["still"] = await _cache_art(
                    client, title["id"], "still", episode["still_path"], season=file["season"], episode=file["episode"]
                )


async def _cache_art(client: httpx.AsyncClient, title_id: str, kind: str, source: str | None, **identity) -> bool:
    if not source:
        return False
    try:
        await tmdb.cache_image(client, title_id, kind, source, **identity)
    except (httpx.HTTPError, OSError) as error:
        logger.warning("TMDB %s failed for %s: %s", kind, title_id, error)
    return tmdb.art_path(title_id, kind, **identity).is_file()


def continue_watching(titles: list[dict]) -> list[dict]:
    if not titles:
        return []
    with database() as db:
        write_order = {row["path"]: row["rowid"] for row in db.execute("SELECT path, rowid FROM progress")}
    candidates = []
    for title in titles:
        played = [(index, file) for index, file in enumerate(title["files"]) if file["progress"]]
        if not played:
            continue
        index, last = max(
            played,
            key=lambda pair: (
                pair[1]["progress"]["updated"],
                write_order.get(pair[1]["path"], 0),
            ),
        )
        target = last
        if last["progress"]["finished"]:
            if title["kind"] != "show" or index + 1 >= len(title["files"]):
                continue
            target = title["files"][index + 1]
        candidates.append(
            (
                last["progress"]["updated"],
                write_order.get(last["path"], 0),
                {"titleId": title["id"], "path": target["path"]},
            )
        )
    candidates.sort(key=lambda candidate: (-candidate[0], -candidate[1], candidate[2]["titleId"]))
    return [candidate[2] for candidate in candidates]


def _title_lock(title_id: str) -> asyncio.Lock:
    return _title_locks.setdefault(title_id, asyncio.Lock())


async def catalog() -> dict:
    titles = await run_in_threadpool(scan)
    if config.TMDB_TOKEN and titles:
        async with tmdb.client() as client:
            for title in titles:
                async with _title_lock(title["id"]):
                    await _enrich(title, client)
    return {"titles": titles, "continue": continue_watching(titles)}


def artwork(
    title_id: str, kind: str, *, person: int | None = None, season: int | None = None, episode: int | None = None
) -> Path | None:
    found = _entry(title_id) if config.TMDB_TOKEN else None
    if found is None:
        return None
    match = _match(title_id)
    if not match or match["tmdb_id"] is None:
        return None
    metadata = json.loads(match["metadata"]) if match["metadata"] is not None else {}
    identity = {}
    if kind in ("poster", "backdrop"):
        source = match[f"{kind}_path"]
    elif kind == "logo":
        source = metadata.get("logo_path")
    elif kind == "profile":
        people = metadata.get("cast", []) + metadata.get("crew", [])
        source = next((member["profile_path"] for member in people if member["personId"] == person), None)
        identity = {"person": person}
    elif kind == "still":
        if not any(
            (parsed := parse_name(path.name))
            and parsed.episode is not None
            and (parsed.season, parsed.episode) == (season, episode)
            for path in found[1]
        ):
            return None
        record = _episodes(match["tmdb_id"]).get((season, episode))
        source = record["still_path"] if record else None
        identity = {"season": season, "episode": episode}
    else:
        return None
    path = tmdb.art_path(title_id, kind, **identity)
    return path if source and path.is_file() else None


def _candidate(kind: str, result: dict) -> dict:
    name, date = _FIELDS[kind]
    return {
        "tmdbId": result["id"],
        "title": result.get(name) or "",
        "year": _year(result.get(date)),
        "overview": result.get("overview") or None,
        "poster_path": result.get("poster_path"),
    }


def _save_candidates(title_id: str, candidates: list[dict]) -> None:
    with database() as db:
        db.execute("DELETE FROM candidates WHERE title_id = ?", (title_id,))
        db.executemany(
            "INSERT OR REPLACE INTO candidates (title_id, tmdb_id, poster_path) VALUES (?, ?, ?)",
            [(title_id, candidate["tmdbId"], candidate["poster_path"]) for candidate in candidates],
        )


async def search_candidates(title_id: str, query: str | None = None) -> list[dict]:
    """TMDB candidates for a manual match; the latest search decides which posters are served."""
    title = await run_in_threadpool(scan_title, title_id)
    if title is None:
        raise NotFound("Title not found")
    if not (query and query.strip()):
        match = await run_in_threadpool(_match, title_id)
        query = match["title"] if match and match["tmdb_id"] is not None and match["title"] else title["title"]
    async with tmdb.client() as client:
        try:
            results = await tmdb.search(client, title["kind"], query.strip())
            candidates = [_candidate(title["kind"], result) for result in results[:10]]
        except _TMDB_FAILURES as error:
            raise TMDBError(f"search failed: {error}") from error
        await run_in_threadpool(_save_candidates, title_id, candidates)
        posters = await asyncio.gather(
            *(
                _cache_art(client, title_id, "candidate", candidate["poster_path"], tmdb_id=candidate["tmdbId"])
                for candidate in candidates
            )
        )
    await run_in_threadpool(tmdb.prune_candidates, title_id, {candidate["tmdbId"] for candidate in candidates})
    return [
        {key: value for key, value in candidate.items() if key != "poster_path"} | {"poster": poster}
        for candidate, poster in zip(candidates, posters, strict=True)
    ]


def candidate_poster(title_id: str, tmdb_id: int) -> Path | None:
    if not config.TMDB_TOKEN or _entry(title_id) is None:
        return None
    with database() as db:
        row = db.execute(
            "SELECT poster_path FROM candidates WHERE title_id = ? AND tmdb_id = ?", (title_id, tmdb_id)
        ).fetchone()
    path = tmdb.art_path(title_id, "candidate", tmdb_id=tmdb_id)
    return path if row and row["poster_path"] and path.is_file() else None


def _replace_match(match: dict) -> None:
    tmdb.forget_art(match["title_id"])
    _store(match)


def _drop_manual(title_id: str) -> None:
    with database() as db:
        dropped = db.execute("DELETE FROM matches WHERE title_id = ? AND manual = 1", (title_id,)).rowcount
    if dropped:
        tmdb.forget_art(title_id)


async def set_match(title_id: str, tmdb_id: int) -> dict:
    """Store a manual match, refetch its details and artwork and return the enriched title."""
    async with _title_lock(title_id):
        title = await run_in_threadpool(scan_title, title_id)
        if title is None:
            raise NotFound("Title not found")
        async with tmdb.client() as client:
            try:
                details = await tmdb.details(client, title["kind"], tmdb_id)
                record = _with_details(title["kind"], _record(title, {"id": tmdb_id}, manual=True), details)
            except httpx.HTTPStatusError as error:
                if error.response.status_code == 404:
                    raise NotFound(f"TMDB has no {title['kind']} {tmdb_id}") from error
                raise TMDBError(f"details failed: {error}") from error
            except _TMDB_FAILURES as error:
                raise TMDBError(f"details failed: {error}") from error
            await run_in_threadpool(_replace_match, record)
            await _enrich(title, client)
    return title


async def drop_match(title_id: str) -> dict:
    """Drop a manual match, match automatically again and return the enriched title."""
    async with _title_lock(title_id):
        title = await run_in_threadpool(scan_title, title_id)
        if title is None:
            raise NotFound("Title not found")
        await run_in_threadpool(_drop_manual, title_id)
        async with tmdb.client() as client:
            await _enrich(title, client)
    return title
