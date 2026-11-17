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


def client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        headers={"Authorization": f"Bearer {config.TMDB_TOKEN}"},
        timeout=10,
    )


async def search(client: httpx.AsyncClient, kind: str, title: str, year: int | None) -> dict | None:
    endpoint = "tv" if kind == "show" else "movie"
    params = {"query": title, "language": config.TMDB_LANGUAGE}
    if kind == "movie" and year is not None:
        params["year"] = str(year)
    response = await client.get(f"{API_URL}/search/{endpoint}", params=params)
    response.raise_for_status()
    results = response.json()["results"]
    if not results and kind == "show" and re.search(r" (?:US|UK)$", title, re.IGNORECASE):
        params["query"] = title.rsplit(" ", 1)[0]
        response = await client.get(f"{API_URL}/search/tv", params=params)
        response.raise_for_status()
        results = response.json()["results"]
    return results[0] if results else None


async def season(client: httpx.AsyncClient, tmdb_id: int, number: int) -> list[dict]:
    response = await client.get(
        f"{API_URL}/tv/{tmdb_id}/season/{number}",
        params={"language": config.TMDB_LANGUAGE},
    )
    response.raise_for_status()
    return response.json()["episodes"]


def art_path(title_id: str, kind: str) -> Path:
    digest = hashlib.sha256(title_id.encode()).hexdigest()
    return config.DATA_DIR / "art" / f"{digest}-{kind}.jpg"


async def cache_image(client: httpx.AsyncClient, title_id: str, kind: str, source: str) -> None:
    target = art_path(title_id, kind)
    if target.is_file():
        return
    width = "w500" if kind == "poster" else "w1280"
    response = await client.get(f"{IMAGE_URL}/{width}{source}")
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
