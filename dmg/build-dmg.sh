#!/bin/bash
# 一条龙打 Mac (Catalyst) 版 DMG:
#   Release 编译 → 拷出 .app(重命名为 随便听.app)→ create-dmg 套上背景图。
# 用法: bash dmg/build-dmg.sh
# 产物: build/dmg/随便听.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="随便听"
BUILD_DIR="build/dmg"
DERIVED="$BUILD_DIR/DerivedData"

command -v create-dmg >/dev/null || { echo "缺 create-dmg: brew install create-dmg"; exit 1; }

# 背景图按脚本现状重新生成,保证文案/布局是最新的
swift dmg/make-background.swift

# 从 AppIcon 生成 macOS 风格 .icns(卷图标 + dmg 文件图标共用)
mkdir -p "$BUILD_DIR"
swift dmg/make-icns.swift
iconutil -c icns "$BUILD_DIR/shuhao.iconset" -o "$BUILD_DIR/shuhao.icns"

# 优先用手动导出的 Developer ID 签名版(放在 build/dmg/shuhao.app);
# 没有的话退回本机 Release 编译(开发签名,仅自用)。
SIGNED_APP="$BUILD_DIR/shuhao.app"
if [ -d "$SIGNED_APP" ]; then
  echo "==> 使用已签名 app: $SIGNED_APP"
  # Finder 拷贝会带进 FinderInfo/resource fork,codesign 校验过不了,先清掉
  xattr -cr "$SIGNED_APP"
  codesign --verify --deep --strict "$SIGNED_APP" || { echo "签名校验失败"; exit 1; }
  # 先落变量再过滤 —— 直接 grep -m1 截断管道会触发 pipefail + set -e 静默退出
  sign_info=$(codesign -dvvv "$SIGNED_APP" 2>&1 || true)
  echo "$sign_info" | sed -n '/Authority/{p;q;}'
  APP_SRC="$SIGNED_APP"
else
  echo "==> Release 编译 (Mac Catalyst)"
  xcodebuild -project shuhao.xcodeproj -scheme shuhao -configuration Release \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED" build | tail -3
  APP_SRC="$DERIVED/Build/Products/Release-maccatalyst/shuhao.app"
  [ -d "$APP_SRC" ] || { echo "没找到编译产物: $APP_SRC"; exit 1; }
fi

STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# ditto 比 cp -R 更适合拷贝签名 bundle(完整保留元数据)
ditto "$APP_SRC" "$STAGE/$APP_NAME.app"

echo "==> 打 DMG"
rm -f "$BUILD_DIR/$APP_NAME.dmg"
create-dmg \
  --volname "$APP_NAME" \
  --volicon "$BUILD_DIR/shuhao.icns" \
  --background dmg/dmg-background.png \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 150 205 \
  --app-drop-link 450 205 \
  --hide-extension "$APP_NAME.app" \
  "$BUILD_DIR/$APP_NAME.dmg" \
  "$STAGE"

# 给 .dmg 文件本身贴上图标(--volicon 只管挂载后的卷)
swift -e "
import AppKit
let ok = NSWorkspace.shared.setIcon(
    NSImage(contentsOfFile: \"$BUILD_DIR/shuhao.icns\"),
    forFile: \"$BUILD_DIR/$APP_NAME.dmg\", options: [])
print(ok ? \"dmg 文件图标已设置\" : \"dmg 文件图标设置失败\")
"

echo "done: $BUILD_DIR/$APP_NAME.dmg"
