"""TMDB requests and on-disk artwork; persistence belongs to the library."""

import hashlib
import os
import re
import tempfile
from pathlib import Path

import httpx

import config

API_URL = "https://api.themoviedb.org/3"
IMAGE_URL = "https://image.tmdb.org/t/p"
WIDTHS = {
    "poster": "w500",
    "backdrop": "w1280",
    "logo": "w500",
    "profile": "w185",
    "still": "w300",
    "candidate": "w185",
}


def client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        headers={"Authorization": f"Bearer {config.TMDB_TOKEN}"},
        timeout=10,
    )


async def search(client: httpx.AsyncClient, kind: str, query: str, year: int | None = None) -> list[dict]:
    endpoint = "tv" if kind == "show" else "movie"
    params = {"query": query, "language": config.TMDB_LANGUAGE}
    if kind == "movie" and year is not None:
        params["year"] = str(year)
    response = await client.get(f"{API_URL}/search/{endpoint}", params=params)
    response.raise_for_status()
    return response.json()["results"]


async def best_match(client: httpx.AsyncClient, kind: str, title: str, year: int | None) -> dict | None:
    results = await search(client, kind, title, year)
    if not results and kind == "show" and re.search(r" (?:US|UK)$", title, re.IGNORECASE):
        results = await search(client, kind, title.rsplit(" ", 1)[0], year)
    return results[0] if results else None


async def season(client: httpx.AsyncClient, tmdb_id: int, number: int) -> list[dict]:
    response = await client.get(
        f"{API_URL}/tv/{tmdb_id}/season/{number}",
        params={"language": config.TMDB_LANGUAGE},
    )
    response.raise_for_status()
    return response.json()["episodes"]


async def details(client: httpx.AsyncClient, kind: str, tmdb_id: int) -> dict:
    endpoint = "tv" if kind == "show" else "movie"
    response = await client.get(
        f"{API_URL}/{endpoint}/{tmdb_id}",
        params={
            "language": config.TMDB_LANGUAGE,
            "append_to_response": "credits,images," + ("content_ratings" if kind == "show" else "release_dates"),
            "include_image_language": "en,null",
        },
    )
    response.raise_for_status()
    return response.json()


def parse_details(kind: str, data: dict) -> dict:
    credits = data.get("credits") or {}
    if kind == "show":
        crew = [_person(person, job="Creator") for person in data.get("created_by", [])][:3]
        runtime = next((value for value in data.get("episode_run_time", []) if value), None)
        ratings = (data.get("content_ratings") or {}).get("results", [])
        certification = next(
            (row["rating"] for row in ratings if row["iso_3166_1"] == "GB" and row.get("rating")), None
        )
    else:
        directors = [person for person in credits.get("crew", []) if person.get("job") == "Director"]
        crew = [_person(person, job="Director") for person in directors][:3]
        runtime = data.get("runtime") or None
        ratings = (data.get("release_dates") or {}).get("results", [])
        certification = next(
            (
                release["certification"]
                for row in ratings
                if row["iso_3166_1"] == "GB"
                for release in row.get("release_dates", [])
                if release.get("certification")
            ),
            None,
        )
    logos = (data.get("images") or {}).get("logos", [])
    logo = next(
        (
            logo["file_path"]
            for language in ("en", None)
            for logo in logos
            if logo.get("iso_639_1") == language and logo.get("file_path")
        ),
        None,
    )
    cast = sorted(credits.get("cast", []), key=lambda person: person.get("order", 0))[:12]
    return {
        "logo_path": logo,
        "runtime": runtime,
        "certification": certification,
        "genres": [genre["name"] for genre in data.get("genres", [])],
        "crew": crew,
        "cast": [_person(person, character=person.get("character") or "") for person in cast],
    }


def _person(person: dict, **role) -> dict:
    return {"personId": person["id"], "name": person["name"], **role, "profile_path": person.get("profile_path")}


def _digest(title_id: str) -> str:
    return hashlib.sha256(title_id.encode()).hexdigest()


def art_path(
    title_id: str,
    kind: str,
    *,
    person: int | None = None,
    season: int | None = None,
    episode: int | None = None,
    tmdb_id: int | None = None,
) -> Path:
    suffix = {"profile": f"-{person}", "still": f"-{season}-{episode}", "candidate": f"-{tmdb_id}"}.get(kind, "")
    extension = "png" if kind == "logo" else "jpg"
    return config.DATA_DIR / "art" / f"{_digest(title_id)}-{kind}{suffix}.{extension}"


def forget_art(title_id: str) -> None:
    """Drop a title's images so its next enrichment fetches the new match's; search candidates stay."""
    candidates = f"{_digest(title_id)}-candidate-"
    for path in (config.DATA_DIR / "art").glob(f"{_digest(title_id)}-*"):
        if not path.name.startswith(candidates):
            path.unlink(missing_ok=True)


def prune_candidates(title_id: str, keep: set[int]) -> None:
    for path in (config.DATA_DIR / "art").glob(f"{_digest(title_id)}-candidate-*.jpg"):
        if path.stem.rsplit("-", 1)[1] not in {str(tmdb_id) for tmdb_id in keep}:
            path.unlink(missing_ok=True)


async def cache_image(client: httpx.AsyncClient, title_id: str, kind: str, source: str, **identity) -> None:
    target = art_path(title_id, kind, **identity)
    if target.is_file():
        return
    response = await client.get(f"{IMAGE_URL}/{WIDTHS[kind]}{source}")
    response.raise_for_status()
    target.parent.mkdir(parents=True, exist_ok=True)
    # Replace atomically so a simultaneous art request cannot see a partial image.
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(response.content)
            temporary.close()
            os.replace(temporary_path, target)
        finally:
            temporary_path.unlink(missing_ok=True)
