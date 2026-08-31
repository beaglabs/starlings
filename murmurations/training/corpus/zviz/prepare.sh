#!/usr/bin/env bash
set -euo pipefail

ZVIZ_COMMIT="470e9cfa03bbe84c1bf1320748363168f9bd3cd6"
ROOT=".cache/murmurations/zviz"
SOURCE="$ROOT/source"
BUNDLE="$ROOT/corpus-v1"
IMAGE="murmurations-corpus-v1:local"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ZViz corpus execution requires a Linux host." >&2
  exit 1
fi

mkdir -p "$ROOT"
if [[ ! -d "$SOURCE/.git" ]]; then
  git clone https://github.com/Skelf-Research/zviz.git "$SOURCE"
fi
git -C "$SOURCE" fetch origin "$ZVIZ_COMMIT"
git -C "$SOURCE" checkout --detach "$ZVIZ_COMMIT"
(
  cd "$SOURCE"
  zig build -Doptimize=ReleaseSafe
)
cp "$SOURCE/zig-out/bin/zviz" "$ROOT/zviz"

docker build \
  --platform linux/amd64 \
  -t "$IMAGE" \
  -f murmurations/training/corpus/zviz/Dockerfile \
  murmurations/training/corpus/zviz

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/rootfs"
cid="$(docker create --platform linux/amd64 "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
docker export "$cid" | tar -C "$BUNDLE/rootfs" -xf -
docker rm "$cid" >/dev/null
trap - EXIT

"$ROOT/zviz" version
printf 'Prepared ZViz corpus bundle: %s\n' "$BUNDLE"
