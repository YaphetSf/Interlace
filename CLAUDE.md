# Interlace

Interlace 是 Incandenza 电视页使用的 API，客户端是 iPhone、Mac 和通过 iPhone 转发请求的 Apple Watch。原生客户端通过 `InterlaceClient/` Swift 包访问 API。

API 只回应带有效设备钥匙（`Authorization: Bearer`，见 Incandenza 的 `docs/devices.md`）的请求，来源网络和 Host 不看；只有 Kodi 拉的 `/api/stream/relay/{token}` 限回环地址。

Kodi 使用的 `GET` / `HEAD /api/stream/relay/{token}` 不需要密钥，但只接受回环地址连接；`STREAM_RELAY_BASE_URL` 使用 `127.0.0.1`。服务名为 `interlace`，不提供网页或静态文件入口。

检查：`cd backend && uv run python -m pytest tests`，以及 `uv run ruff check .`。

服务器（硬件、服务、系统改动、定时重启的原因、黑屏排查）全部记录在 SERVER.md。改动服务器上的系统配置后，同步更新那份文档。

@SERVER.md
