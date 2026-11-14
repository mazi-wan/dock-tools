#!/bin/zsh
# 桌面壁纸换成纯白图(只是主题的一部分,Dock 不透明由 dock-tools.sh 负责):
#   dock-tools.sh 在 Dock 条正下方垫一块白板,Dock 材质取样到白,窗口尺寸和菜单栏都不动。
#   不用辅助功能「减少透明度」: 那是全局开关,会把菜单栏变成实色灰。
# 用法: dock-white.sh [apply|revert]
set -euo pipefail

WALLPAPER="$HOME/Library/Pictures/pure_white.png"

make_white_png() {
    # 纯白 64x64 PNG,用 python3 标准库手写,不依赖第三方包
    python3 - "$1" <<'EOF'
import struct, sys, zlib
path = sys.argv[1]
w = h = 64
row = b'\x00' + b'\xff' * 3 * w
raw = row * h
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw))
png += chunk(b'IEND', b'')
open(path, 'wb').write(png)
EOF
}

set_wallpaper() {
    osascript -e 'tell application "System Events" to set picture of every desktop to "'"$WALLPAPER"'"'
}

apply() {
    if [ ! -f "$WALLPAPER" ]; then
        mkdir -p "$(dirname "$WALLPAPER")"
        make_white_png "$WALLPAPER"
        echo "生成纯白壁纸: $WALLPAPER"
    fi
    set_wallpaper
    echo "已应用:纯白壁纸。Dock 不透明由 dock-tools.sh 负责。"
}

revert() {
    echo "壁纸请在 系统设置 → 墙纸 中手动选回。"
}

case "${1:-apply}" in
    apply)  apply  ;;
    revert) revert ;;
    *) echo "用法: $(basename "$0") [apply|revert]" >&2; exit 1 ;;
esac
