import httpx

import config

PLAYER_PROPS = [
    "percentage",
    "time",
    "totaltime",
    "speed",
    "audiostreams",
    "currentaudiostream",
    "videostreams",
    "currentvideostream",
    "subtitles",
    "currentsubtitle",
    "subtitleenabled",
]

ITEM_PROPS = ["title", "art", "file", "season", "episode", "showtitle"]


def _secs(t):
    if not t:
        return 0
    return t.get("hours", 0) * 3600 + t.get("minutes", 0) * 60 + t.get("seconds", 0)


class Kodi:
    def __init__(self):
        self.url = config.KODI_RPC_URL
        self.auth = (config.KODI_USER, config.KODI_PASS)
        self._client = httpx.AsyncClient(timeout=10, auth=self.auth)

    async def close(self):
        await self._client.aclose()

    async def _call(self, method, params=None):
        payload = {"jsonrpc": "2.0", "id": "ic", "method": method, "params": params or {}}
        r = await self._client.post(self.url, json=payload)
        r.raise_for_status()
        data = r.json()
        if "error" in data:
            raise RuntimeError(data["error"].get("message", "kodi error"))
        return data.get("result")

    async def _active_player(self):
        players = await self._call("Player.GetActivePlayers") or []
        for p in players:
            if p.get("type") in ("video", "audio"):
                return p["playerid"]
        return players[0]["playerid"] if players else None

    async def play_file(self, path):
        return await self._call("Player.Open", {"item": {"file": path}})

    async def now_playing(self):
        app = await self._call("Application.GetProperties", {"properties": ["volume", "muted"]})
        pid = await self._active_player()
        if pid is None:
            return {"active": False, "volume": app.get("volume"), "muted": app.get("muted")}
        props = await self._call(
            "Player.GetProperties", {"playerid": pid, "properties": PLAYER_PROPS}
        )
        item = (await self._call("Player.GetItem", {"playerid": pid, "properties": ITEM_PROPS})).get("item", {})
        return {
            "active": True,
            "playerid": pid,
            "title": item.get("title") or item.get("label") or "",
            "file": item.get("file", ""),
            "percentage": props.get("percentage", 0),
            "time": _secs(props.get("time")),
            "totaltime": _secs(props.get("totaltime")),
            "speed": props.get("speed", 0),
            "audiostreams": props.get("audiostreams", []),
            "currentaudiostream": props.get("currentaudiostream", {}),
            "videostreams": props.get("videostreams", []),
            "currentvideostream": props.get("currentvideostream", {}),
            "subtitles": props.get("subtitles", []),
            "currentsubtitle": props.get("currentsubtitle", {}),
            "subtitleenabled": props.get("subtitleenabled", False),
            "volume": app.get("volume"),
            "muted": app.get("muted"),
        }

    async def play_pause(self):
        pid = await self._active_player()
        return None if pid is None else await self._call("Player.PlayPause", {"playerid": pid})

    async def stop(self):
        pid = await self._active_player()
        return None if pid is None else await self._call("Player.Stop", {"playerid": pid})

    async def seek(self, percentage):
        pid = await self._active_player()
        if pid is None:
            return None
        return await self._call(
            "Player.Seek", {"playerid": pid, "value": {"percentage": float(percentage)}}
        )

    async def set_audio(self, index):
        pid = await self._active_player()
        if pid is None:
            return None
        return await self._call("Player.SetAudioStream", {"playerid": pid, "stream": int(index)})

    async def set_video(self, index):
        pid = await self._active_player()
        if pid is None:
            return None
        return await self._call("Player.SetVideoStream", {"playerid": pid, "stream": int(index)})

    async def set_subtitle(self, value):
        pid = await self._active_player()
        if pid is None:
            return None
        if isinstance(value, str) and value.isdigit():
            value = int(value)
        params = {"playerid": pid, "subtitle": value}
        if isinstance(value, int):
            params["enable"] = True
        return await self._call("Player.SetSubtitle", params)

    async def set_volume(self, level):
        return await self._call("Application.SetVolume", {"volume": int(level)})

    async def set_mute(self, muted):
        return await self._call("Application.SetMute", {"mute": bool(muted)})

    async def exec_action(self, action):
        return await self._call("Input.ExecuteAction", {"action": action})
