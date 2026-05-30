#!/usr/bin/env bash
#
# npm run sync — 在 Mac 和 Interlace 本机之间做一次双向同步。
#
# 流程:
#   1. fetch 后报告三方(Mac / Interlace / GitHub)谁领先谁落后
#   2. 两端各自 auto-commit 未提交的改动(带主机名 + 时间戳)
#   3. Interlace 先 rebase + push,再 Mac rebase + push,最后 Interlace 再 pull 对齐
#   4. 任一端 rebase 冲突 → 中止并提示手动处理,不留半截状态
#
set -euo pipefail

REMOTE_HOST="interlace"
REMOTE_DIR="/home/ding/Interlace"
BRANCH="main"

# ---- 输出辅助 ----
c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'
c_red=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_blue" "$1" "$c_off"; }
ok()   { printf '%s   ✓ %s%s\n' "$c_green" "$1" "$c_off"; }
warn() { printf '%s   ! %s%s\n' "$c_yellow" "$1" "$c_off"; }
die()  { printf '\n%s✗ %s%s\n' "$c_red" "$1" "$c_off" >&2; exit 1; }

# 在 Interlace 上跑一段命令(cd 到项目目录)
remote() { ssh "$REMOTE_HOST" "cd '$REMOTE_DIR' && $1"; }

# ---- 0. 健全性检查 + 抓取最新状态 ----
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "当前目录不是 git 仓库"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || die "本地不在 $BRANCH 分支"

step "抓取远端状态…"
git fetch -q origin
remote "git fetch -q origin" || die "无法 SSH 到 $REMOTE_HOST(试试 ssh $REMOTE_HOST)"

# rev-list --left-right --count A...B  →  "<A 独有>  <B 独有>"
read -r mac_ahead mac_behind < <(git rev-list --left-right --count "$BRANCH...origin/$BRANCH")
read -r ila_ahead ila_behind < <(remote "git rev-list --left-right --count $BRANCH...origin/$BRANCH")

step "三方状态(相对 GitHub):"
report() { # $1=名字 $2=ahead $3=behind
  if [[ "$2" == 0 && "$3" == 0 ]]; then printf '   %-10s 已同步\n' "$1"
  else printf '   %-10s 领先 %s,落后 %s\n' "$1" "$2" "$3"; fi
}
report "Mac"       "$mac_ahead" "$mac_behind"
report "Interlace" "$ila_ahead" "$ila_behind"
if [[ "$mac_ahead" -gt 0 && "$ila_ahead" -gt 0 ]]; then
  warn "两端都有 GitHub 上没有的提交,将通过 rebase 合并"
fi

# ---- 1. 两端各自 auto-commit ----
commit_msg() { echo "sync: auto-commit on $1 $(date '+%F %T')"; }

step "提交 Mac 端未提交改动…"
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git commit -q -m "$(commit_msg "$(hostname -s)")"
  ok "已提交 Mac 端改动"
else
  ok "Mac 端无改动"
fi

step "提交 Interlace 端未提交改动…"
if remote 'test -n "$(git status --porcelain)"'; then
  remote "git add -A && git commit -q -m \"sync: auto-commit on \$(hostname -s) \$(date '+%F %T')\""
  ok "已提交 Interlace 端改动"
else
  ok "Interlace 端无改动"
fi

# ---- 2. Interlace 先 rebase + push ----
step "Interlace:rebase + push → GitHub…"
if ! remote "git pull --rebase --autostash -q origin $BRANCH"; then
  remote "git rebase --abort" >/dev/null 2>&1 || true
  die "Interlace 端 rebase 冲突,请登录 $REMOTE_HOST 手动解决后重试"
fi
remote "git push -q origin $BRANCH"
ok "Interlace 已推送"

# ---- 3. Mac rebase + push ----
step "Mac:rebase + push → GitHub…"
if ! git pull --rebase --autostash -q origin "$BRANCH"; then
  git rebase --abort >/dev/null 2>&1 || true
  die "Mac 端 rebase 冲突,请手动解决(git status)后重试"
fi
git push -q origin "$BRANCH"
ok "Mac 已推送"

# ---- 4. Interlace 再 pull,三方对齐 ----
step "Interlace:拉取 Mac 的提交,完成对齐…"
remote "git pull --rebase --autostash -q origin $BRANCH"
ok "Interlace 已对齐"

printf '\n%s✓ 同步完成 — Mac、Interlace、GitHub 已一致%s\n' "$c_green" "$c_off"
git --no-pager log --oneline -3
