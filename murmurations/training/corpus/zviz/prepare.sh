#!/usr/bin/env bash
set -euo pipefail

ZVIZ_COMMIT="470e9cfa03bbe84c1bf1320748363168f9bd3cd6"
ZIG_VERSION="0.16.0"
ROOT=".cache/murmurations/zviz"
SOURCE="$ROOT/source"
BUNDLE="$ROOT/corpus-v1"
TOOLS="$ROOT/tools"
IMAGE="murmurations-corpus-v1:local"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ZViz corpus execution requires a Linux host." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64)
    ZIG_ARCH="x86_64"
    ;;
  aarch64|arm64)
    ZIG_ARCH="aarch64"
    ;;
  *)
    echo "Unsupported Linux architecture for the pinned corpus environment: $(uname -m)" >&2
    exit 1
    ;;
esac

echo "Preparing Linux prerequisites..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  docker.io \
  git \
  xz-utils

sudo systemctl enable --now docker

mkdir -p "$ROOT" "$TOOLS"

ZIG_DIR="$TOOLS/zig-$ZIG_ARCH-linux-$ZIG_VERSION"
ZIG_BIN="$ZIG_DIR/zig"
if [[ ! -x "$ZIG_BIN" ]]; then
  echo "Installing pinned Zig $ZIG_VERSION for $ZIG_ARCH..."
  archive="$TOOLS/zig-$ZIG_ARCH-linux-$ZIG_VERSION.tar.xz"
  curl -fL \
    "https://ziglang.org/download/$ZIG_VERSION/zig-$ZIG_ARCH-linux-$ZIG_VERSION.tar.xz" \
    -o "$archive"
  tar -xJf "$archive" -C "$TOOLS"
  rm -f "$archive"
fi

"$ZIG_BIN" version

if [[ ! -d "$SOURCE/.git" ]]; then
  git clone https://github.com/Skelf-Research/zviz.git "$SOURCE"
fi
git -C "$SOURCE" fetch origin "$ZVIZ_COMMIT"
git -C "$SOURCE" checkout --detach "$ZVIZ_COMMIT"
(
  cd "$SOURCE"
  "$OLDPWD/$ZIG_BIN" build -Doptimize=ReleaseSafe
)
cp "$SOURCE/zig-out/bin/zviz" "$ROOT/zviz"

sudo docker build \
  --build-arg "ZIG_ARCH=$ZIG_ARCH" \
  --build-arg "ZIG_VERSION=$ZIG_VERSION" \
  -t "$IMAGE" \
  -f murmurations/training/corpus/zviz/Dockerfile \
  murmurations/training/corpus/zviz

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/rootfs"
cid="$(sudo docker create "$IMAGE")"
trap 'sudo docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
sudo docker export "$cid" | tar -C "$BUNDLE/rootfs" -xf -
sudo docker rm "$cid" >/dev/null
trap - EXIT

"$ROOT/zviz" version
printf 'Prepared ZViz corpus bundle: %s\n' "$BUNDLE"
