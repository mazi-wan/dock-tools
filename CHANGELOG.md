# Changelog

记录 dock-tools 的优化历程和重要变更。README 只保留当前状态，历史细节放这里。

## 第四轮优化（2026-11-14）：指针跟踪 + idle 帧 + 缓存

真正的开销来源：`NSEvent` 全局监听（哪怕空闭包也要 0.27% 单核），笔屏有悬停漂移时指针一直在发事件，等于监听成本永远付满。

| | 之前 | 现在 |
| --- | --- | --- |
| 指针跟踪 | `NSEvent` 全局监听（0.27%） | 自适应定时器 4/30/120Hz |
| 指针在底部热区空转 | 每次移动都开 60Hz 跟踪 → **1.8%** | 只读一个变量 → **0.27%** |
| 菜单栏 idle 帧 | 每帧都漂白 | 直接丢弃（丢 32/42 帧） |
| 位图 context | 每帧新建 77 万字节 | 按尺寸复用 |
| `visibleFrame` | 菜单栏每 2 秒、面板每帧都查（9.9 µs） | 缓存，仅几何变化时失效 |
| Dock 兜底轮询 | 10 秒 | 60 秒 |
| yabai 阴影 | 每 2 秒 fork 一次 | 仅 pid 变化 / 开关切换 / 60 秒 |
| 守护脚本 | 每轮十几个子进程（**0.5%**） | 零子进程（**0.05%**） |

守护脚本零子进程的做法：配置用 zsh 内置的 `$(<file)` 读、内容没变就返回；  
进程存活用缓存 pid + `kill -0`；日志轮转 30 秒才查一次（`zstat` 取大小）；  
循环等待用内置 `zselect` 代替 `sleep`。

### 关键参数

- `minimumFrameInterval = 1 秒` **不能放开**：不设它时系统按 50fps 送 "idle" 帧（30 秒 1572 帧），设成 5 秒则真实变化也要等最多 5 秒才送达。这个参数就是延迟上限。
- `minimumFrameInterval` 是延迟上限，不是频率上限。真实变化（`SCFrameStatus.complete`）由内容触发，不受 idle 心跳影响。

### 修了一个 Bug

换成轮询后 `Driver` 变成了局部变量，Timer 用 `[weak self]` 捕获它 —— 没有任何强引用，函数一返回就被释放，Dock 召唤完全失效。之前 `NSEvent` 闭包恰好强引用着它，所以没暴露。现在挂在全局变量上。

### 睡眠

- 显示器睡眠（`screensDidSleep`）和整机睡眠（`willSleep`）时停掉菜单栏的 `SCStream`，唤醒后再重建。
- 不申请任何电源断言（`pmset -g assertions` 里没有 `dock-helper` / `menu-shade`）。
- 所有定时器都设了 `tolerance`。

## 第三轮优化（2026-11-14）：菜单栏漂白改为常驻 `SCStream`

之前菜单栏漂白每秒起一个 `screencapture` 子进程落盘解 PNG：单帧 100ms+、占单核 4~6%、内存 96 MB。

重写为常驻 `SCStream` 单窗口订阅（Window Server layer 24）：

- 窗口内容变了才送帧（时钟走字、切 App、展开菜单），静止时一帧都没有
- 实测静止 20 秒 0~7 帧，进程 CPU 0.1%、每帧漂白约 0.5ms
- `SCStream` 采集时 `minimumFrameInterval = 1s`，`queueDepth = 3`，`showsCursor = false`
- idle 帧直接丢弃（不做漂白、不建位图）—— 这条 alone 把菜单栏从 0.24% 降到 0.15%
- 位图 context 按尺寸复用（每帧新建要 77 万字节）
- `visibleFrame` 缓存（9.9 µs，`frame` 的 90 倍）

成果：菜单栏漂白 4.5% → 0.15%；`dock-helper` 合计 6% → 0.5~1%；内存 96MB → 17~67MB。

### `SCStream` 的 `SCFrameStatus`

- `complete` (0)：内容有变化，需要画
- `idle` (1)：内容没变，直接丢弃
- `blank` (2)：没画面（睡眠中），丢弃
- `started` (4)：刚启动，必须画（避免永远没有图）

## 第二轮优化（2026-11-14）：Dock 白板 + 事件驱动 + AX 缓存

- Dock 的 AX 元素缓存住，每次只做一次「位置 + 大小」合并查询：0.08 ms → 0.02 ms
- Dock 重启 / 改 Dock 设置用 `NSWorkspace` 启动/退出通知：`killall Dock` 后 **1 秒内**重新校准
- 唤醒通知补一次校准
- 兜底轮询 3 秒 → 10 秒
- AX 元素失效时丢缓存重试一次

## 第一轮优化（2026-11-14）：移除应用内框线（app-lines）

- 删除 `app-lines.swift`、`app-lines` 二进制、`README-app-lines.md`
- `dock-tools.sh` 中移除 `app_lines`/`app_line_color`/`app_line_alpha` 配置项、编译/安装/启停/status 项
- `~/.config/dock-tools/config.conf` 三行已删（备份 `config.conf.bak-*`）

## 项目结构

```
dock/
├── dock-helper.swift      # 主进程：Dock 白板 + 启动器修正 + 菜单栏漂白
├── menu-shade.swift       # Chrome 右键菜单白底（独立进程，0% CPU）
├── dock-tools.sh          # 守护脚本 + apply/status/build/install
├── dock-white.sh          # 换纯白壁纸（不可自动还原）
├── install-window-style.sh
├── uninstall-window-style.sh
├── eink-mac              # 一键装齐/关闭全部优化
├── README.md
└── CHANGELOG.md
```

## 已知限制

- 菜单栏只能整条重贴，多屏时只处理主屏。
- 菜单栏自动隐藏或全屏（高度为 0 或整屏）时不做处理。
- 白板是叠加层，不是真的改应用绘制；极端情况下有不到 1 秒的滞后。
- `minimumFrameInterval = 1 秒` 是延迟上限，不能放开。