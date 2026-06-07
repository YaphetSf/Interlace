#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${FFMPEG_RUNTIME_DIR:-$ROOT/backend/.runtime/ffmpeg}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

packages=(
  ffmpeg
  libavdevice62
  libjack-jackd2-0
  libopenal1
  libdc1394-25
)

mkdir -p "$DEST"
cd "$WORK"
apt-get download "${packages[@]}"
for package in ./*.deb; do
  dpkg-deb -x "$package" "$DEST"
done

lib_dir="$DEST/usr/lib/x86_64-linux-gnu"
LD_LIBRARY_PATH="$lib_dir" "$DEST/usr/bin/ffmpeg" -version | head -n 1
echo "Installed local ffmpeg runtime at $DEST"
