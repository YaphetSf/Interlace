import asyncio
import base64

import httpx

import config


class Aria2:
    def __init__(self):
        self.url = config.ARIA2_RPC_URL
        self.token = f"token:{config.ARIA2_TOKEN}"
        self._client = httpx.AsyncClient(timeout=10)

    async def close(self):
        await self._client.aclose()

    async def _call(self, method, params=None):
        payload = {
            "jsonrpc": "2.0",
            "id": "ic",
            "method": method,
            "params": [self.token] + (params or []),
        }
        r = await self._client.post(self.url, json=payload)
        r.raise_for_status()
        data = r.json()
        if "error" in data:
            raise RuntimeError(data["error"].get("message", "aria2 error"))
        return data.get("result")

    async def add_uri(self, uri, options=None):
        return await self._call("aria2.addUri", [[uri], options or {}])

    async def add_torrent(self, torrent_bytes, options=None):
        b64 = base64.b64encode(torrent_bytes).decode()
        return await self._call("aria2.addTorrent", [b64, [], options or {}])

    async def pause(self, gid):
        return await self._call("aria2.pause", [gid])

    async def unpause(self, gid):
        return await self._call("aria2.unpause", [gid])

    async def remove(self, gid):
        for method in ("aria2.remove", "aria2.removeDownloadResult"):
            try:
                await self._call(method, [gid])
            except RuntimeError as e:
                msg = str(e).lower()
                if "not found" in msg or "removed" in msg or "active" in msg:
                    continue
                raise
        return "OK"

    async def all_downloads(self):
        active, waiting, stopped = await asyncio.gather(
            self._call("aria2.tellActive"),
            self._call("aria2.tellWaiting", [0, 100]),
            self._call("aria2.tellStopped", [0, 100]),
            return_exceptions=True,
        )
        if isinstance(active, Exception):
            active = []
        if isinstance(waiting, Exception):
            waiting = []
        if isinstance(stopped, Exception):
            stopped = []
        return [self._fmt(d) for d in (*active, *waiting, *stopped)]

    @staticmethod
    def _fmt(d):
        total = int(d.get("totalLength", 0))
        completed = int(d.get("completedLength", 0))
        bt = d.get("bittorrent") or {}
        name = (bt.get("info") or {}).get("name", "")
        if not name and d.get("files"):
            path = d["files"][0].get("path", "")
            name = path.rsplit("/", 1)[-1] if path else ""
        if not name:
            uris = (d.get("files") or [{}])[0].get("uris") or []
            name = uris[0]["uri"] if uris else d.get("gid", "?")
        return {
            "gid": d.get("gid"),
            "name": name,
            "status": d.get("status"),
            "total": total,
            "completed": completed,
            "progress": round(completed / total * 100, 1) if total else 0,
            "speed": int(d.get("downloadSpeed", 0)),
            "is_torrent": bool(bt),
            "error": d.get("errorMessage"),
        }
