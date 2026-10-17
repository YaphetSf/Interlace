# Interlace

Interlace 是 Incandenza 电视页使用的 API，客户端是 iPhone、Mac 和通过 iPhone 转发请求的 Apple Watch。原生客户端通过 `InterlaceClient/` Swift 包访问 API。

除 `GET /api/health` 外，API 只回应 tailnet 和回环地址、用 IP 访问、并带 `X-Person: <id>` 的请求；没有密钥。

Kodi 使用的 `GET` / `HEAD /api/stream/relay/{token}` 不需要密钥，但只接受回环地址连接；`STREAM_RELAY_BASE_URL` 使用 `127.0.0.1`。服务名为 `interlace`，不提供网页或静态文件入口。

检查：`cd backend && uv run python -m pytest tests`，以及 `uv run ruff check .`。

服务器（硬件、服务、系统改动、定时重启的原因、黑屏排查）全部记录在 SERVER.md。改动服务器上的系统配置后，同步更新那份文档。

@SERVER.md
