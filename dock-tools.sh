#!/bin/zsh
# Dock 不透明 + Chrome 菜单白底 + 去窗口阴影，一个 LaunchAgent、一个配置文件：
#   dock_opaque=1            在 Dock 条下面垫白板，Dock 材质取样成实色；
#                            不动窗口尺寸、不动菜单栏、跟随自动隐藏。
#   menu_white=1             Chrome 右键菜单后面垫白板，菜单不再透出网页内容。
#   remove_window_shadow=1   关掉所有窗口的阴影（含底部最重的那圈）。
#   apps_toggle=1            App 启动器打开时，再点 Dock 图标能正常关闭（macOS 26 的 bug 修正）。
#   menu_bar_line=1          盖掉菜单栏底边那条 1pt 深灰线（「降低透明度」开着时系统会画）。
#   hide_finder=1            用白板盖住 Dock 最左边的 Finder 图标（Finder 本身仍在，⌘N 照旧）。
#   改 ~/.config/dock-tools/config.conf 保存后约 2 秒生效，不用重装。
# 用法: dock-tools.sh [on|off|apply|revert|status|build|install|daemon]
#   on      一键全开：把五项开关写成 1，安装并启动 LaunchAgent。
#   off     一键全关：把五项开关写成 0，停止全部工具、卸载 LaunchAgent、恢复窗口阴影。
#   单项开关改 config.conf 即可；apply 按当前配置重新安装。
# 另行提供的脚本(不在 on/off 范围内):
#   eink-mac on|off|status      全新机器一键装齐/关闭全部优化(本脚本 + yabai + JankyBorders)。
#   dock-white.sh apply         换纯白壁纸(不可自动还原，请自行在系统设置改回)。
#   install-window-style.sh     安装 yabai + JankyBorders(去阴影功能依赖)。
#   uninstall-window-style.sh   彻底卸载 yabai + JankyBorders。
# 注意: dock-shade 与 apps-toggle 已合并为 dock-helper 一个进程，
#       用 --panel / --tap / --menubar 参数控制三个功能；辅助功能只需授权它一个条目。
#       改这两个开关会重启该进程(约 2 秒)，另一项会短暂中断。
#       重新 build 后二进制 cdhash 变了，旧授权会失效（开关仍显示开），
#       需要先移除 dock-helper 条目再添加一次。menu-shade 不需要任何授权。
# 运行位置: 程序从 ~/Library/Application Support/dock-tools/ 启动（本地磁盘），
#       源码留在当前目录。launchd 进程读不了 NFS 网络卷，直接跑会退出码 127。
set -euo pipefail

# zstat 用来取日志文件大小（内置，不起子进程）；zselect 用来代替 sleep。
# 守护循环每 2 秒一轮，这些小地方攒起来就是每轮的进程开销。
zmodload -F zsh/stat b:zstat 2>/dev/null || true
SLEEP_BUILTIN=0
zmodload -F zsh/zselect b:zselect 2>/dev/null && SLEEP_BUILTIN=1

LABEL="com.jack.dock-tools"
HERE=$(cd "$(dirname "$0")" && pwd)
SELF="$HERE/$(basename "$0")"
HELPER_BIN="$HERE/dock-helper"
HELPER_SRC="$HERE/dock-helper.swift"
MENU_BIN="$HERE/menu-shade"
MENU_SRC="$HERE/menu-shade.swift"
CONF="${DOCK_TOOLS_CONF:-$HOME/.config/dock-tools/config.conf}"
LOG="$HOME/Library/Logs/dock-tools.log"
# 运行位置。源码在 NFS 上，但 launchd 进程读不了网络卷（TCC 挡的，
# 不是挂载时机问题），所以程序要装到本地磁盘再跑，源码照旧在 NFS 上改。
LOCAL_DIR="$HOME/Library/Application Support/dock-tools"

YABAI=""
for p in /opt/homebrew/bin/yabai /usr/local/bin/yabai; do
    [ -x "$p" ] && { YABAI="$p"; break; }
done

build() {
    build_one "$HELPER_SRC" "$HELPER_BIN" dock-helper
    build_one "$MENU_SRC" "$MENU_BIN" menu-shade
}

# 自签证书: 用固定的证书签名后，辅助功能/屏幕录制的授权绑定到证书(certificate leaf)，
# 而不是二进制的 cdhash。这样以后重新编译，只要还签同一张证书，授权就不会失效。
# 默认 ad-hoc 签名每次编译 cdhash 都变，必须去系统设置里删掉再加一次，很烦。
SIGN_ID="3CD57B92BAB44BF7AE78967975ED0D867EADA9C9"          # dock-tools Local Signing
SIGN_KC="$HOME/Library/Keychains/dock-tools-signing.keychain-db"
SIGN_KC_PASS="docktools"

sign_one() {
    # 没装证书就跳过，退回 ad-hoc（能用，只是每次编译要重新授权）
    [ -f "$SIGN_KC" ] || return 0
    local bin="$1" name="$2"
    security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KC" >/dev/null 2>&1 || return 0
    codesign -f -s "$SIGN_ID" --identifier "$name" --keychain "$SIGN_KC" "$bin" >/dev/null 2>&1
}

build_one() {
    # 先编到临时目录再换上去: 直接覆盖正在运行的二进制会让签名在写入中途失效。
    # 输出文件名保持原名, 二进制的 Identifier 就是它。
    local src="$1" out="$2" name="$3"
    local tmpdir; tmpdir=$(mktemp -d)
    swiftc -O -o "$tmpdir/$name" "$src"
    chmod +x "$tmpdir/$name"
    sign_one "$tmpdir/$name" "$name"
    mv -f "$tmpdir/$name" "$out"
    rmdir "$tmpdir"
    echo "已编译: $out"
}

install_local() {
    # 把脚本和二进制同步到本地磁盘。launchd 从本地启动，不碰 NFS。
    # 源码仍然只在 NFS 上：改完源码执行 ./dock-tools.sh apply 就会重新编译并同步。
    [ -x "$HELPER_BIN" ] && [ -x "$MENU_BIN" ] || build
    mkdir -p "$LOCAL_DIR"
    local f src dst
    for f in dock-tools.sh dock-helper menu-shade; do
        src="$HERE/$f"
        dst="$LOCAL_DIR/$f"
        [ "$src" = "$dst" ] && continue          # 已经是本地副本在跑
        [ -f "$src" ] || { echo "缺少 $src" >&2; exit 1; }
        cp -f "$src" "$dst"
        chmod +x "$dst"
        # 拷过来的副本要保持签名有效，否则 TCC 又会对不上
        sign_one "$dst" "$f"
    done
    # 清掉已下线功能的旧副本（app-lines 已移除）
    rm -f "$LOCAL_DIR/app-lines"
    rm -rf "$LOCAL_DIR/app-lines.app" "$LOCAL_DIR/dock-helper.app"
    echo "已同步到本地: $LOCAL_DIR"
}

write_default_conf() {
    [ -f "$CONF" ] && return
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<'EOF'
# dock-tools 配置: 1=开启, 0=关闭。保存后约 2 秒内生效。

# Dock 不透明: 在 Dock 条下面垫一块白板,让 Dock 材质取样成实色。
dock_opaque=1

# Chrome 右键菜单白底: 在菜单后面垫白板, 菜单不再透出网页内容。
menu_white=1

# 去掉所有窗口的阴影(包括底部最强的那一圈)。
remove_window_shadow=1

# App 启动器打开时再点 Dock 图标能正常关闭。
apps_toggle=1

# 检查间隔(秒)。
poll=2

# 菜单栏底边: 盖掉「降低透明度」在菜单栏下面画的那条 1pt 深灰线。
menu_bar_line=0
EOF
}

ensure_conf_key() {
    # 老配置文件里没有新开关时补一行, 后续可以在同一个文件里改。
    local key="$1" default="$2" comment="${3:-}"
    [ -f "$CONF" ] || return 0
    grep -q "^[[:space:]]*${key}[[:space:]]*=" "$CONF" && return 0
    cat >> "$CONF" <<EOF

# ${comment}
${key}=${default}
EOF
}

conf_get() {
    local key="$1" default="$2" v=""
    if [ -f "$CONF" ]; then
        v=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$CONF" | tail -n 1)
    fi
    echo "${v:-$default}"
}

# 字符串型配置(颜色、透明度这类)，不能套用只认数字的 conf_get。
# 注意颜色值以 # 开头，正则不能把 # 当注释截断，否则读出来是空串。
conf_get_str() {
    local key="$1" default="$2" v=""
    if [ -f "$CONF" ]; then
        v=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$CONF" | tail -n 1)
    fi
    echo "${v:-$default}"
}

conf_set() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$CONF")"
    [ -f "$CONF" ] || write_default_conf
    if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$CONF"; then
        sed -i '' -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[0-9]+/${key}=${value}/" "$CONF"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$CONF"
    fi
}

# 配置只在内容变化时重新解析。
# 旧实现每轮 6 个键各起一次 sed + tail（约 12 个进程），守护循环每 2 秒跑一遍，
# 这是守护脚本那 0.5% 的大头。现在用 zsh 内置的 $(<file) 读取（不起子进程），
# 内容没变就直接返回；纯 zsh 解析，不再碰 sed。
load_conf() {
    local content="" tag="missing" line key val
    local -a st
    if [ -f "$CONF" ]; then
        # mtime+size 先比：大多数轮次文件没动，zstat 是内置、不读文件、不 fork。
        # zstat 的 +element 只能选一个，所以用 -H 取整张 hash。
        local -A zst
        if zstat -H zst -- "$CONF" 2>/dev/null; then
            local stamp="${zst[mtime]}:${zst[size]}"
            [ "$stamp" = "${_conf_stamp:-}" ] && return 0
            _conf_stamp="$stamp"
        fi
        content="$(<"$CONF")"
        tag="file"
    else
        [ "missing" = "${_conf_stamp:-}" ] && return 0
        _conf_stamp="missing"
    fi
    local key_digest="$tag:${#content}:$content"
    # 退化保护：mtime 一样但内容不一样（罕见，比如 cp 覆盖）→ 继续解析
    [ "$key_digest" = "${_conf_digest:-}" ] && return 0
    _conf_digest="$key_digest"

    local dock_opaque=1 menu_white=1 remove_window_shadow=1 apps_toggle=1 menu_bar_line=0 hide_finder=0 poll=2
    local -a lines
    lines=("${(@f)content}")
    for line in "${lines[@]}"; do
        case "$line" in ''|\#*) continue ;; esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        key="${key//[[:space:]]/}"
        val="${val//[[:space:]]/}"
        # 只取开头的数字，和旧的 sed 正则行为一致（dock_opaque=01 读成 01，下面归一成 1）
        val="${val%%[^0-9]*}"
        case "$key" in
            dock_opaque)            [ -n "$val" ] && dock_opaque="$val" ;;
            menu_white)             [ -n "$val" ] && menu_white="$val" ;;
            remove_window_shadow)   [ -n "$val" ] && remove_window_shadow="$val" ;;
            apps_toggle)            [ -n "$val" ] && apps_toggle="$val" ;;
            menu_bar_line)          [ -n "$val" ] && menu_bar_line="$val" ;;
            hide_finder)            [ -n "$val" ] && hide_finder="$val" ;;
            poll)                   [ -n "$val" ] && poll="$val" ;;
        esac
    done

    # 开关只认 0/1：配置里写成 01、2 之类的值会让 helper 报用法错误退出，
    # 守护进程又会不停重启它，这里统一归一成 0/1
    DOCK_OPAQUE=$dock_opaque;            [ "$DOCK_OPAQUE" = "0" ] || DOCK_OPAQUE=1
    MENU_WHITE=$menu_white;              [ "$MENU_WHITE" = "0" ] || MENU_WHITE=1
    REMOVE_WINDOW_SHADOW=$remove_window_shadow; [ "$REMOVE_WINDOW_SHADOW" = "0" ] || REMOVE_WINDOW_SHADOW=1
    APPS_TOGGLE=$apps_toggle;            [ "$APPS_TOGGLE" = "0" ] || APPS_TOGGLE=1
    MENU_BAR_LINE=$menu_bar_line;        [ "$MENU_BAR_LINE" = "0" ] || MENU_BAR_LINE=1
    HIDE_FINDER=$hide_finder;            [ "$HIDE_FINDER" = "0" ] || HIDE_FINDER=1
    POLL=$poll
    # poll=0 会让守护循环变成死循环空转
    [ "$POLL" -ge 1 ] 2>/dev/null || POLL=1
}

yabai_running() {
    [ -n "$YABAI" ] && pgrep -x yabai >/dev/null 2>&1
}

set_shadows() {
    "$YABAI" -m config window_shadow "$1" >/dev/null 2>&1 || true
}

shadow_count() {
    # 只数真正可见的窗口; 系统授权提示窗等隐藏窗口也带阴影, 但不该算进来
    yabai_running || { echo 0; return 0; }
    "$YABAI" -m query --windows 2>/dev/null | python3 -c '
import json, sys
n = 0
for w in json.load(sys.stdin):
    if w.get("has-shadow") and w.get("is-visible"):
        n += 1
print(n)' 2>/dev/null || echo 0
}

make_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>${LOCAL_DIR}/dock-tools.sh</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>${LOG}</string>
    <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
EOF
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    # 原来每轮都跑 wc -l（一个子进程）。改成：30 秒才检查一次，用文件大小判断。
    # 日志一行约 70~90 字节，500 行 ≈ 40KB，取 48KB 作阈值。
    local now=$SECONDS
    [ $(( now - ${_log_checked_at:-0} )) -lt 30 ] && return 0
    _log_checked_at=$now
    local -a st
    zstat -A st +size -- "$LOG" 2>/dev/null || return 0
    [ "${st[1]:-0}" -gt 49152 ] || return 0
    # 原地截断而不是 mv：launchd 和 helper 都拿着这个文件的 fd，
    # 换文件会让旧 fd 继续往被移走的文件里写
    tail -n 200 "$LOG" > "${LOG}.tmp" && cat "${LOG}.tmp" > "$LOG" && rm -f "${LOG}.tmp"
}

helper_args() {
    # 按进程名找，手动不带参数启动的实例也能被发现，避免两个 helper 并存
    local pid
    pid=$(pgrep -x dock-helper 2>/dev/null | head -n 1)
    [ -n "$pid" ] && ps -o args= -p "$pid" 2>/dev/null
    return 0
}
helper_running() { [ -n "$(helper_args)" ] }
panel_running() { [[ "$(helper_args)" == *"--panel=1"* ]] }
tap_running()   { [[ "$(helper_args)" == *"--tap=1"* ]] }
menubar_running() { [[ "$(helper_args)" == *"--menubar=1"* ]] }
nofinder_running() { [[ "$(helper_args)" == *"--nofinder=1"* ]] }

kill_by_name() {
    # 不判断返回值：pgrep/pkill 在某些状态下会返回非零，配合 set -e 会直接中断脚本
    local name="$1" i
    pkill -TERM -x "$name" >/dev/null 2>&1 || true
    for i in 1 2 3 4; do
        pgrep -x "$name" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
    pkill -KILL -x "$name" >/dev/null 2>&1 || true
    sleep 0.2
    return 0
}

# 运行的是本地副本；路径里有空格，所以用带引号的变量，不能用 $(...) 命令替换。
HELPER_EXE="$LOCAL_DIR/dock-helper"
pick_exe() {
    [ -x "$LOCAL_DIR/dock-helper" ] && HELPER_EXE="$LOCAL_DIR/dock-helper"
}

stop_helper() {
    kill_by_name dock-helper
    kill_by_name dock-shade     # 旧版本遗留进程
    kill_by_name apps-toggle
}

stop_menu() {
    kill_by_name menu-shade
}

daemon() {
    [ -x "$HELPER_BIN" ] && [ -x "$MENU_BIN" ] || build
    pick_exe
    trap 'stop_helper; stop_menu; exit 0' INT TERM EXIT
    local last_shadow="" started_flags=""
    # 缓存进程 pid，每轮只做 kill -0（内置）判断存活；
    # 只有 pid 失效或还没记录时才 pgrep 一次，省掉每轮的 pgrep + ps。
    local helper_pid="" menu_pid="" yabai_pid="" shadow_pid="" shadow_sent_at=0
    local now
    while :; do
        rotate_log
        load_conf

        now=$SECONDS
        if [ -n "$helper_pid" ] && kill -0 "$helper_pid" 2>/dev/null; then
            :   # 活着
        elif helper_pid=$(pgrep -x dock-helper 2>/dev/null | head -n 1); then
            :
        else
            helper_pid=""
        fi

        # 一个进程同时承担面板和点击修正，用参数说明开哪几项
        if [ "$DOCK_OPAQUE" = "0" ] && [ "$APPS_TOGGLE" = "0" ] && [ "$MENU_BAR_LINE" = "0" ] \
           && [ "$HIDE_FINDER" = "0" ]; then
            [ -n "$helper_pid" ] && { stop_helper; helper_pid=""; }
            started_flags=""
        else
            local want_flags="panel=$DOCK_OPAQUE tap=$APPS_TOGGLE menubar=$MENU_BAR_LINE nofinder=$HIDE_FINDER"
            if [ "$want_flags" != "$started_flags" ] || [ -z "$helper_pid" ]; then
                [ -n "$helper_pid" ] && stop_helper
                "$HELPER_EXE" --panel="$DOCK_OPAQUE" --tap="$APPS_TOGGLE" \
                    --menubar="$MENU_BAR_LINE" --nofinder="$HIDE_FINDER" >>"$LOG" 2>&1 &
                helper_pid=$!
                echo "$(date '+%F %T') 启动 dock-helper pid=$helper_pid (panel=$DOCK_OPAQUE tap=$APPS_TOGGLE menubar=$MENU_BAR_LINE nofinder=$HIDE_FINDER)"
                started_flags="$want_flags"
            fi
        fi

        if [ "$MENU_WHITE" = "1" ]; then
            if [ -z "$menu_pid" ] || ! kill -0 "$menu_pid" 2>/dev/null; then
                # 赋值失败（pgrep 没找到）会返回非零，set -e 下必须兜住
                menu_pid=$(pgrep -x menu-shade 2>/dev/null | head -n 1 || true)
                if [ -z "$menu_pid" ]; then
                    "$MENU_BIN" >>"$LOG" 2>&1 &
                    menu_pid=$!
                    echo "$(date '+%F %T') 启动菜单白底 pid=$menu_pid"
                fi
            fi
        else
            stop_menu
            menu_pid=""
        fi

        # yabai 只在 pid 变化、开关切换、或距上次下发满 60 秒时才重新设置。
        # yabai 自己的配置可能在重载后丢掉这项，60 秒的重发够兜住了。
        if [ -n "$yabai_pid" ] && kill -0 "$yabai_pid" 2>/dev/null; then
            :
        else
            # pgrep 没找到时返回 1，赋值算失败命令，set -e 下必须兜住
            yabai_pid=$(pgrep -x yabai 2>/dev/null | head -n 1 || true)
        fi
        if [ -n "$YABAI" ] && [ -n "$yabai_pid" ]; then
            local want_shadow="$REMOVE_WINDOW_SHADOW"
            if [ "$want_shadow" != "$last_shadow" ] || [ "$yabai_pid" != "${shadow_pid:-}" ] \
                || [ $(( now - shadow_sent_at )) -ge 60 ]; then
                if [ "$want_shadow" = "1" ]; then
                    set_shadows off
                else
                    set_shadows on
                fi
                shadow_sent_at=$now
                shadow_pid=$yabai_pid
                if [ "$want_shadow" != "$last_shadow" ]; then
                    if [ "$want_shadow" = "1" ]; then
                        echo "$(date '+%F %T') 关闭窗口阴影"
                    else
                        echo "$(date '+%F %T') 恢复窗口阴影"
                    fi
                    last_shadow="$want_shadow"
                fi
            fi
        fi

        if [ "$SLEEP_BUILTIN" = "1" ]; then
            # zselect 是内置的等待，-t 的单位是百分之一秒；超时返回 1，正常。
            zselect -t $(( POLL * 100 )) >/dev/null 2>&1 || true
        else
            sleep "$POLL"
        fi
    done
}

apply() {
    install_local
    write_default_conf
    ensure_conf_key menu_white 1 "Chrome 右键菜单白底: 在菜单后面垫白板, 菜单不再透出网页内容。"
    ensure_conf_key apps_toggle 1 "App 启动器打开时再点 Dock 图标能正常关闭。"
    ensure_conf_key menu_bar_line 0 "菜单栏底边: 盖掉\"降低透明度\"在菜单栏下面画的那条 1pt 深灰线。"
    mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
    make_plist > "$HOME/Library/LaunchAgents/${LABEL}.plist"
    local uid; uid=$(id -u)
    # 收掉旧的独立 LaunchAgent，避免两个服务抢同一批窗口
    local old
    for old in com.jack.dock-shade com.jack.no-shadow; do
        launchctl bootout "gui/${uid}/${old}" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/LaunchAgents/${old}.plist"
    done
    launchctl bootout "gui/${uid}/${LABEL}" >/dev/null 2>&1 || true
    stop_helper
    stop_menu
    # bootout 之后 launchd 还要几十毫秒才把旧 service 真正摘干净。
    # 早先只 sleep 1 就开始 bootstrap，实测会连着三次返回
    # "5: Input/output error"，然后 apply 直接失败——但等一会儿手动
    # bootstrap 又是好的。所以这里等到 launchctl print 真的查不到了再继续。
    local wait
    for wait in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "gui/${uid}/${LABEL}" >/dev/null 2>&1 || break
        sleep 0.3
    done
    # bootstrap 偶发 "5: Input/output error"，是瞬时错误，重试就好
    local i
    for i in 1 2 3 4 5; do
        if launchctl bootstrap "gui/${uid}" "$HOME/Library/LaunchAgents/${LABEL}.plist" 2>>"$LOG"; then
            break
        fi
        if [ "$i" = 5 ]; then
            echo "launchctl bootstrap 连续失败，看 $LOG" >&2
            exit 1
        fi
        sleep 1
    done
    sleep 3
    load_conf
    if launchctl print "gui/${uid}/${LABEL}" >/dev/null 2>&1; then
        echo "已应用: ${LABEL}"
        echo "配置: $CONF (dock_opaque=$DOCK_OPAQUE menu_white=$MENU_WHITE remove_window_shadow=$REMOVE_WINDOW_SHADOW apps_toggle=$APPS_TOGGLE menu_bar_line=$MENU_BAR_LINE hide_finder=$HIDE_FINDER)"
        echo "日志: $LOG"
    else
        echo "启动失败，看 $LOG" >&2
        exit 1
    fi
}

on() {
    echo "一键开启: Dock 不透明、Chrome 菜单白底、去窗口阴影、启动器点击修正、菜单栏底边"
    conf_set dock_opaque 1
    conf_set menu_white 1
    conf_set remove_window_shadow 1
    conf_set apps_toggle 1
    conf_set menu_bar_line 1
    conf_set hide_finder 1
    apply
}

off() {
    echo "一键关闭: 停止全部工具、卸载 LaunchAgent、恢复窗口阴影"
    conf_set dock_opaque 0
    conf_set menu_white 0
    conf_set remove_window_shadow 0
    conf_set apps_toggle 0
    conf_set menu_bar_line 0
    conf_set hide_finder 0
    revert
}

revert() {
    local uid; uid=$(id -u)
    launchctl bootout "gui/${uid}/${LABEL}" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/LaunchAgents/${LABEL}.plist"
    stop_helper
    stop_menu
    if yabai_running; then set_shadows on; fi
    echo "已恢复窗口阴影"
    echo "已卸载 ${LABEL}，Dock 恢复系统默认的半透明，Chrome 菜单恢复系统半透明。"
}

status() {
    load_conf
    echo "配置: $CONF"
    echo "  dock_opaque=$DOCK_OPAQUE  menu_white=$MENU_WHITE  remove_window_shadow=$REMOVE_WINDOW_SHADOW  apps_toggle=$APPS_TOGGLE  menu_bar_line=$MENU_BAR_LINE  hide_finder=$HIDE_FINDER  poll=$POLL"
    echo "运行位置: $LOCAL_DIR"
    echo "服务: $(launchctl print gui/$(id -u)/${LABEL} >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
    echo "面板: $(panel_running && echo 在跑 || echo 未运行)"
    echo "菜单白底: $(pgrep -x menu-shade >/dev/null 2>&1 && echo 在跑 || echo 未运行)"
    echo "启动器修正: $(tap_running && echo 在跑 || echo 未运行)"
    echo "菜单栏底边: $(menubar_running && echo 在跑 || echo 未运行)"
    echo "隐藏 Finder: $(nofinder_running && echo 在跑 || echo 未运行)"
    echo "yabai: $(yabai_running && echo 运行中 || echo 未运行)"
    if yabai_running; then
        echo "有阴影的窗口: $(shadow_count)"
    else
        echo "有阴影的窗口: 无法统计(yabai 未运行)"
    fi
    echo "autohide: $(defaults read com.apple.dock autohide 2>/dev/null || echo 0)"
    echo "Dock 条位置(屏外 y=屏高 表示已收起):"
    osascript -e 'tell application "System Events" to tell process "Dock"' \
              -e 'set p to position of UI element 1' \
              -e 'set s to size of UI element 1' \
              -e 'return (item 1 of p as string) & "," & (item 2 of p as string) & " " & (item 1 of s as string) & "x" & (item 2 of s as string)' \
              -e 'end tell' 2>/dev/null || echo "  读不到(缺辅助功能权限)"
}

case "${1:-apply}" in
    on)     on ;;
    off)    off ;;
    apply)  apply ;;
    revert) revert ;;
    status) status ;;
    build)  build ;;
    install) install_local ;;
    daemon) daemon ;;
    *) echo "用法: $(basename "$0") [on|off|apply|revert|status|build|daemon]" >&2; exit 1 ;;
esac
