# Interlace 服务器

Interlace 既是这个项目，也是跑这个项目的那台机器（主机名 `Interlace`，`ssh interlace`）。它接在电视上：Incandenza 的 iPhone、Mac 和 Apple Watch 客户端通过 API 控制 aria2 下载，再用 Kodi 在电视上播放；Apple Watch 的请求通过 iPhone 转发。项目功能见 [README.md](README.md)，这份文档记录**机器本身**：硬件、服务，以及仓库以外在系统上加过的东西和原因。

## 硬件与系统

- **MacBook Air 2020 Intel（MacBookAir9,1，带 T2 芯片）**，最后一代 Intel 款。一直插着电源，没有智能插座或定时断电。
- **必须用 65 W 的笔记本充电器**：之前插的是一个单口手机充电器，上面标着 10 W 和 20 W。插到 m4p 上读出来，它只有 5 V/3 A 和 9 V/2.77 A 两档，最多 25 W（`ioreg -rn AppleSmartBattery` 里的 `AdapterDetails`），m4p 插着它也在掉电。在这之前它一直撑得住，电池停在 97% 不动；2026-10-19 00:15 左右开始供电跟不上，电池以约 1.4 W 一直掉电。那一刻前后没有装软件，没有新服务启动，CPU 负载也一直在 1% 左右。2026-10-19 22:15 电量耗光后关机，内核和 journal 都没留下记录。表现和死机一样：插着它长按电源键也开不了机，换上 65 W 的充电器后马上就能开机充电。要确认是不是这个原因，看 `upower -i /org/freedesktop/UPower/devices/battery_BAT0`：插着电时 `state` 应该是 `charging` 或 `fully-charged`。历史记录在 `/var/lib/upower/history-charge-bq20z451-50.dat`。这个内核没有 applesmc，也没有 typec，读不到 PD 协商出的功率。
- Ubuntu 26.04 + t2linux 内核（`linux-t2`，来自 AdityaGarg8/t2-ubuntu-repo）。
- 电视通过 USB-C 转 HDMI 连接，在 DRM 里显示为 **DP-2**。`HDMI-A-1` 永远是 disconnected，这是正常的。
- 项目目录：`/home/ding/Interlace`。与 Mac、GitHub 之间用 `npm run sync` 同步（见 `scripts/sync.sh`）。

## 服务

| 服务 | 类型 | 作用 |
|---|---|---|
| `interlace.service` | 用户服务（开启了 linger） | 后端，uvicorn :8000 |
| `aria2.service` | 用户服务 | 下载 |
| `interlace-kodi-desktop.service` | 用户服务，挂在 `graphical-session.target` 上 | Kodi（Wayland，全屏在 DP-2 上），Web/JSON-RPC 在 :8080 |
| GDM 自动登录 `ding` | `/etc/gdm3/custom.conf` | 开机后自动进 GNOME，Kodi 才会跟着启动 |
| `interlace-uptime-reboot.timer` | 系统服务 | 见下文“定时重启” |
| `interlace-local-rescue.service` | 系统服务 | 本机按 Ctrl+Alt+K 显示/隐藏 Kodi，断网时也能用 |

重启后端：`XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart interlace`

### 谁能访问

后端监听所有网卡，家里 LAN 可直接访问，也接受主机名。除 Kodi 回环 relay 外，每个 API（包括 `/api/health`）都要求 `Authorization: Bearer <key>`；有效设备密钥即可访问，不再检查来源网络、Host 或 `X-Incandenza`。缺少、未知或已撤销的密钥统一返回 401 和 `{"detail": "device key required"}`。

设备表默认是 `~/.config/incandenza/devices.toml`，可用 `INCANDENZA_DEVICES` 指定路径。只存设备名、密钥的 SHA-256 和 admin 标记，由 Incandenza hub 的 add/revoke 命令管理。后端启动时读取，文件 mtime 改变后重读；移除设备后，下一个请求即被拒绝。设备表缺失或无效时拒绝所有密钥。本机 `doctor.py` 不持有密钥，探测 `/api/health` 收到 401 也视为服务存活。

Kodi 获取的 `GET` / `HEAD /api/stream/relay/{token}` 不需要设备密钥，但只接受回环地址连接；`STREAM_RELAY_BASE_URL` 保持 `http://127.0.0.1:8000`。

## 定时重启（`interlace-uptime-reboot`）

**为什么需要这个看起来很奇怪的重启：** 这台 T2 MacBook Air 在 Linux 下只要连续开机满 **5 天（432000 秒）** 就会被硬复位。重启前的 journal 里没有关机记录，也没有 kernel panic，pstore 是空的，下次开机 fsck 要修复文件系统日志。2026 年 9 月的记录显示，每次重启前的开机时长都在 431693 到 431984 秒之间，一次都没漏过。

- 这和内核版本无关。别人两台 MacBook Air 分别跑 6.12 和 6.19，也是一样每 5 天被复位（[doemefu/homelab#102](https://github.com/doemefu/homelab/issues/102)），怀疑是 T2/SMC 固件看门狗。t2linux 目前没有修复，升级内核解决不了。
- 这个复位会在看片时直接断掉，并且每次都是硬断电。

**做法：** 每天 04:30 检查一次，开机超过 3.5 天（302400 秒）就执行一次正常的 `systemctl reboot`。这样重启总落在开机后第 4 天的凌晨，永远到不了 5 天的硬复位。重启后，自动登录、Kodi、后端和 aria2 都会自己起来。

- 脚本：`scripts/interlace-uptime-reboot.sh`，安装后在 `/usr/local/bin/`。支持 `DRYRUN=1` 和 `THRESHOLD=` 两个环境变量。
- 安装：`sudo scripts/install-uptime-reboot.sh`
- 查看：`systemctl list-timers interlace-uptime-reboot.timer`、`journalctl -t interlace-uptime-reboot`
- 哪天 T2 的问题修好了：`sudo systemctl disable --now interlace-uptime-reboot.timer`

## 其它系统改动

- **旧的独占 GBM Kodi**（系统服务 `kodi.service`、`scripts/install-display-fix.sh`、`kodi-wait-for-display.sh`、`kodi-display-heal.sh`，以及 udev 规则 `99-kodi-display-hotplug.rules`）：已经停用，现在改用 GNOME 桌面里的 Kodi。`kodi.service` 和 `gdm.service` 互斥，别同时启用。
- **休眠被禁用**：`sleep` / `suspend` / `hibernate` / `suspend-then-hibernate` 这几个 target 都已 mask。
- **合盖熄屏**：`lid-monitor.service`（`/usr/local/bin/lid-backlight-monitor.sh`），合盖时把内屏背光关掉。
- **T2 Wi-Fi 自愈**：`t2-wifi-selfheal.service`、`t2-wifi-selfheal-resume.service`（`/usr/local/sbin/t2-wifi-selfheal.sh`），用来修复 brcmfmac 网卡掉线。
- **Kodi 本体**：自编译的 v21。JSON-RPC 不接受 `Player.Open {"item":{"file":…}}`，所以后端的 `kodi_client.play_file` 改用 playlist 按 position 播放。

## 电视没画面时的排查顺序

1. 长按电源键也开不了机：电池被耗光了，确认插的是 65 W 充电器（见“硬件与系统”），等几分钟再开机。能 ssh 时，用 `upower` 看插着电是不是还在掉电。
2. `uptime` / `journalctl --list-boots`：是不是刚被重启过？
3. `loginctl list-sessions`：seat0 上应该有 `ding` 的会话。只有 `gdm-greeter` 的话，说明卡在登录界面了，要检查自动登录。
4. `systemctl --user status interlace-kodi-desktop`
5. 上面都正常，再去看 `/sys/class/drm/card1-DP-2/status` 和 `~/.kodi/temp/kodi.log`。
