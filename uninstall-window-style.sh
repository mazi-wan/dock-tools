#!/bin/zsh
set -euo pipefail
BREW=""
for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x $p ]] && { BREW=$p; break; }
done
PREFIX=""
[[ -z $BREW ]] || PREFIX=$($BREW --prefix)
YABAI="$PREFIX/bin/yabai"
[[ ! -x $BREW ]] || $BREW services stop FelixKratz/formulae/borders || true
if [[ -x $YABAI ]]; then
  $YABAI -m config window_shadow on || true
  $YABAI --stop-service || true
  sudo "$YABAI" --uninstall-sa || true
fi
sudo rm -f /private/etc/sudoers.d/yabai
rm -f "$HOME/.config/yabai/yabairc" "$HOME/.config/borders/bordersrc"
if [[ -x $BREW ]]; then
  # 只装过其中一个时另一个会报未安装，不该中断卸载
  $BREW uninstall borders yabai || true
fi
print '已卸载 yabai 和 JankyBorders，窗口阴影已恢复。SIP 与 NVRAM 启动参数仍需手动恢复：在恢复模式运行 csrutil enable，回到系统后运行 sudo nvram -d boot-args，再重启。'
