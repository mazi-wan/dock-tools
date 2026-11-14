#!/bin/zsh
set -euo pipefail
BREW=""
for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x $p ]] && { BREW=$p; break; }
done
[[ -n $BREW ]] || { echo '需要先安装 Homebrew' >&2; exit 1; }
PREFIX=$($BREW --prefix)
YABAI=$PREFIX/bin/yabai
BORDERS=$PREFIX/bin/borders
$BREW install asmvik/formulae/yabai FelixKratz/formulae/borders
mkdir -p "$HOME/.config/yabai" "$HOME/.config/borders"
YRC="$HOME/.config/yabai/yabairc"
BRC="$HOME/.config/borders/bordersrc"
[[ ! -f $YRC ]] || cp "$YRC" "$YRC.backup.$(date +%Y%m%d%H%M%S)"
[[ ! -f $BRC ]] || cp "$BRC" "$BRC.backup.$(date +%Y%m%d%H%M%S)"
cat > "$YRC" <<CONF
#!/bin/sh
sudo -n $YABAI --load-sa
$YABAI -m signal --add label=reload-shadow-extension event=dock_did_restart action="sudo -n $YABAI --load-sa && $YABAI -m config window_shadow on && $YABAI -m config window_shadow off"
$YABAI -m config layout float
$YABAI -m config window_shadow off
CONF
cat > "$BRC" <<CONF
#!/bin/sh
$BORDERS style=round width=2.0 hidpi=on active_color=0xff007aff inactive_color=0xff808080
CONF
chmod +x "$YRC" "$BRC"
HASH=$(shasum -a 256 "$YABAI" | awk '{print $1}')
RULE="$(id -un) ALL=(root) NOPASSWD: sha256:$HASH $YABAI --load-sa"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
print -r -- "$RULE" > "$TMP"
sudo visudo -cf "$TMP"
sudo install -m 0440 -o root -g wheel "$TMP" /private/etc/sudoers.d/yabai
$YABAI --start-service || true
$BREW services start FelixKratz/formulae/borders
# --load-sa 在已加载时也返回非 0，不能让它中断安装
sudo -n "$YABAI" --load-sa || true
$YABAI --restart-service
$YABAI -m config window_shadow off || true
print '已安装。若窗口仍有阴影，请确认 yabai 的辅助功能权限，以及 SIP 和 -arm64e_preview_abi 启动参数。'
