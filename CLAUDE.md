# Interlace

Interlace 是 Incandenza 电视页使用的 API，客户端是 iPhone、Mac 和通过 iPhone 转发请求的 Apple Watch。原生客户端通过 `InterlaceClient/` Swift 包访问 API。

除 `GET /api/health` 外，API 请求必须携带 `Authorization: Bearer <person key>`。`.env` 的 `PERSON_KEYS_SHA256` 存放逗号分隔的 SHA-256 十六进制摘要，与 Incandenza 的 `hub/fleet.toml` 中 `[[person]]` 的 `key_sha256` 一致。未设置、留空或没有有效摘要时拒绝所有需要鉴权的请求；无效摘要项会被忽略。

Kodi 使用的 `GET` / `HEAD /api/stream/relay/{token}` 不需要密钥，但只接受回环地址连接；`STREAM_RELAY_BASE_URL` 使用 `127.0.0.1`。服务名为 `interlace`，不提供网页或静态文件入口。

检查：`cd backend && uv run python -m pytest tests`，以及 `uv run ruff check .`。

服务器（硬件、服务、系统改动、定时重启的原因、黑屏排查）全部记录在 SERVER.md。改动服务器上的系统配置后，同步更新那份文档。

@SERVER.md
