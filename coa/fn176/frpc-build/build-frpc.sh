#!/usr/bin/env bash
# Build the local frpc image from the official frp release binary.
#
#   ./build-frpc.sh [version]      # default 0.71.0 (matches the VPS frps)
#
# Why not the registry: `docker pull snowdreamtech/frpc` on fn176 runs at
# ~50 kB/s through the configured registry mirrors; the release tarball comes
# down through the mihomo proxy instead. The tarball is re-downloaded only
# when it is missing or does not extract cleanly.
set -euo pipefail

VER="${1:-0.71.0}"
PROXY_URL="${PROXY_URL:-http://127.0.0.1:7890}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="frp_${VER}_linux_amd64"
TARBALL="frp_${VER}_linux_amd64.tar.gz"
URL="https://github.com/fatedier/frp/releases/download/v${VER}/${TARBALL}"

cd "$HERE"

# fetch into *.part and only publish a complete file (a killed curl otherwise
# leaves a truncated tarball that tar refuses with "Unexpected EOF")
if [ ! -s "$TARBALL" ] || ! tar tzf "$TARBALL" >/dev/null 2>&1; then
  echo "== downloading $TARBALL (proxy $PROXY_URL)"
  rm -f "$TARBALL" "$TARBALL.part"
  curl -sSL -x "$PROXY_URL" -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi

rm -rf "$PKG"
tar xzf "$TARBALL"
cp -f "$PKG/frpc" ./frpc
chmod +x ./frpc
./frpc --version

echo "== building coa-frpc:local"
docker build -t coa-frpc:local "$HERE"
docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep '^coa-frpc:'
echo
echo "next:  docker compose --profile tunnel up -d coa-frpc"
