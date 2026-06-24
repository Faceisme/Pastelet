#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export MACOSX_DEPLOYMENT_TARGET=26.0

# 构建缓存(.build 及其中的 CompilationCache.noindex 等)放到 Dropbox 外面。
# 否则 Dropbox 会同步这些频繁增删的临时缓存,把每个中途产物的历史版本都留在云端,
# 单个 CompilationCache.noindex 就能在云端堆到 13G(本地却只有几十 KB)。
BUILD_ROOT="${BUILD_ROOT:-$HOME/dev/build/Pastelet}"
mkdir -p "$BUILD_ROOT"

swift build -c release --arch arm64 --scratch-path "$BUILD_ROOT"
BIN_DIR="$(swift build -c release --arch arm64 --scratch-path "$BUILD_ROOT" --show-bin-path)"

APP_DIR="$ROOT_DIR/build/Pastelet.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/Pastelet" "$APP_DIR/Contents/MacOS/Pastelet"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
chmod +x "$APP_DIR/Contents/MacOS/Pastelet"

# 用「固定身份」签名：辅助功能(TCC)授权绑定的是签名身份而非二进制 hash，
# 因此重新编译后授权不会被吊销，不用每次重新授权。
# 默认自动取第一个有效的 codesigning 证书；可用 CODESIGN_IDENTITY 覆盖。
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 {print $2}')"
fi
if [ -n "$SIGN_ID" ]; then
  codesign --force --sign "$SIGN_ID" --identifier com.face.pastelet "$APP_DIR"
  echo "Signed with: $SIGN_ID"
  codesign --verify --verbose=2 "$APP_DIR"
else
  echo "WARNING: 未找到可用签名证书，回退为 ad-hoc（重编后需重新授权辅助功能）。"
fi

echo "Built $APP_DIR"
