import hashlib
import os
import tomllib
from dataclasses import dataclass
from pathlib import Path
from threading import Lock

from fastapi import HTTPException, Request

import config


@dataclass(frozen=True)
class Device:
    name: str
    admin: bool


class DeviceRegistry:
    def __init__(self, path: Path):
        self.path = path
        self._mtime_ns: int | None = None
        self._devices: dict[str, Device] = {}
        self._lock = Lock()
        self.reload()

    def reload(self) -> None:
        with self._lock:
            try:
                with self.path.open("rb") as source:
                    mtime_ns = os.fstat(source.fileno()).st_mtime_ns
                    if mtime_ns == self._mtime_ns:
                        return
                    entries = tomllib.load(source).get("device", [])
                if not isinstance(entries, list):
                    raise ValueError("Invalid device registry")
                devices = {}
                for entry in entries:
                    if not isinstance(entry, dict):
                        raise ValueError("Invalid device entry")
                    name, admin, digest = entry.get("name"), entry.get("admin"), entry.get("sha256")
                    if (
                        not isinstance(name, str)
                        or not name
                        or not isinstance(admin, bool)
                        or not isinstance(digest, str)
                        or len(digest) != 64
                        or any(character not in "0123456789abcdef" for character in digest)
                    ):
                        raise ValueError("Invalid device entry")
                    devices[digest] = Device(name=name, admin=admin)
            except (OSError, ValueError):
                self._devices = {}
                self._mtime_ns = None
                return
            self._devices = devices
            self._mtime_ns = mtime_ns

    def verify(self, key: str) -> Device | None:
        self.reload()
        return self._devices.get(hashlib.sha256(key.encode()).hexdigest())


registry = DeviceRegistry(config.INCANDENZA_DEVICES)


def require_device(request: Request) -> Device:
    scheme, _, key = request.headers.get("authorization", "").partition(" ")
    if scheme.lower() == "bearer" and key:
        device = registry.verify(key)
        if device is not None:
            return device
    raise HTTPException(status_code=401, detail="device key required")
