# Changelog

记录 dock-tools 的优化历程和重要变更。README 只保留当前状态，历史细节放这里。

## 修复：Finder 遮盖的延迟（2026-11-15）

上一版 Finder 遮盖用自己的 0.1 秒定时器，而 Dock 白板以 120Hz 跟踪，
两者必然错开，收起/升起时能看到遮盖块慢半拍。

改成和白板**共用同一帧几何**：Finder 图标在 Dock 条里的相对偏移是固定的
（条 `(144,821,1312,69)`、图标 `(152,826,53,69)` → 偏移 `+8,+5`），
缓存这个偏移后，用白板每帧已经拿到的实时 Dock 矩形推图标位置即可，
不需要额外查 AX，也不会错帧。

验证：沿升/收动画每 30ms 采样，两个窗口的 alpha 在同一帧一起从 0.0 → 1.0，
位置同时更新（819 / 824）。收起状态下 CPU 0.04% → 0.03%（hider 完全不工作）。

面板没开时保留退路：0.1 秒自查。

## 新增：隐藏 Dock 上的 Finder（2026-11-15）

需求：Dock 最左边是 Finder，想去掉它，改用 Strata。

先确认了 Finder 删不掉：

| 尝试 | 结果 |
| --- | --- |
| `persistent-apps` 里找 Finder | 不存在（12 项里第 0 项就是 Strata） |
| `defaults write com.apple.dock static-only -bool true` | **无效**，只是把图标重排了一遍 |
| 从 plist 删条目 | Finder 是 Dock 硬编码的，plist 里没有 |

所以做成叠加层（`hide_finder`）：读 AX 找 Dock 里 Finder 那一格，贴一块白色方块。
Finder 本身仍在，⌘N / 点桌面都照旧。

### 两个坑

1. **层级必须够高**：Dock 的图标是它自己画的、不是独立窗口。
   实测 level 3/5/10 完全盖不住（Finder 区域蓝色像素 5055 → 601），
   20 起干净，最终用 24（和菜单栏窗口同层，不会压住菜单栏）。
2. **AX 的 Dock 矩形不反映实时状态**：Dock 收起后 `AXPosition` 仍返回落定位置 821，
   不会变成 900；Finder 图标的矩形同样不动。所以「Dock 在不在屏上」不能靠 AX 判断，
   改为借用面板模式已有的 `engaged` 信号（面板本来就知道 Dock 是否升起）。

采样率自适应：Dock 在屏上 0.1 秒、收起 1 秒。Dock 收起时白板跟着隐藏。

### 调试过程中的教训

测试时多次误判，都是工具的问题而不是代码的问题：

- 合成鼠标事件卡在 (800,899)，Dock 从未收起 → 误以为「收起时不隐藏」
- 同时跑了两个 dock-helper 实例 → 测到别人的 CPU
- 合成 hover 出来的 Dock 状态和真实鼠标不一致

最后确认：展开时 Finder 区域蓝色像素 0/6000（完全遮住），收起时窗口 alpha=0。

## 移除 Finder 侧栏处理（2026-11-14）

原来加过一个 `finder_sidebar` 开关，给 Finder 侧栏选中行贴半透明浅蓝底。
功能本身是好的（AX 事件驱动、空闲 0 唤醒），但用户决定不要，整体移除：

- `dock-helper.swift`：删掉 `SidebarHighlight` / `SidebarPatchView` /
  `finderSidebarElements` / `finderSidebarSelection`，以及 `--sidebar` 参数
- `dock-tools.sh`：删掉 `finder_sidebar` 配置项、`sidebar_running()`、daemon 传参
- 配置文件里的 `finder_sidebar=1` 和它的注释一并清掉

移除后的开销：`dock-helper` 从 0.33% 降到 **0.12%**（省掉侧栏模块初始化）。
`axAttr` / `axFrame` 两个通用 AX 工具函数保留（面板功能还在用）。

保留的技术结论（以后要用可以参考）：

- 走固定路径查 AX 是 **0.44ms**，盲目遍历整棵树是 **122ms**
- `AXObserverAddNotification` 对 outline 的 `AXSelectedRowsChanged` 返回 0（可用），
  可以做到纯事件驱动、空闲 0 唤醒
- 墨水屏上 Finder 侧栏选中底 224、侧栏底 246，只差 22 级灰度；系统没有可调开关
  （accent 色只管列表选中行，`AppleHighlightColor` 只管文字选中）

## 第五轮优化（2026-11-14）：Finder 侧栏选中 + 纯事件驱动

墨水屏上 Finder 侧栏的选中条几乎看不出：选中底 224、侧栏底 246，只差 22 级灰度。

试过但无效的系统设置：

| 方案 | 结果 |
| --- | --- |
| 换 8 种 accent 色 | 最好的是黄色，但白字对比度只有 2.08:1（橙色 3.47:1 反而更好） |
| `AppleHighlightColor` | 只管文字选中，对列表/侧栏选中行无效 |
| `AppleAccentColorCustom` | 无效 |
| `increaseContrast` | 本来就开着，且 TCC 保护 |
| 浅底深字 | 系统在列表选中行上强制白字，侧栏则是灰底深字——两者都不受配置控制 |

最终用叠加层：读 AX 拿选中行矩形，贴一块 alpha 0.55 的浅蓝（文字/图标仍透出来）。

### 性能关键：怎么查 AX

| 做法 | 耗时 |
| --- | --- |
| 盲目遍历整棵 AX 树 | **122 ms** |
| 走固定路径 `window → AXSplitGroup[0] → AXScrollArea[0] → AXOutline` | **0.44 ms** |

0.44ms 才是这个方案能成立的原因；122ms 那种做法（每个 App 都扫一遍）根本没法用。

### 从轮询改成纯事件驱动

| | 之前 | 现在 |
| --- | --- | --- |
| 刷新方式 | 5Hz 轮询（AX 查询 0.44ms × 5 = 0.2%） | `AXSelectedRowsChanged` + `AXFocusedUIElementChanged` |
| 空闲开销 | 约 0.2%（稳定后） | **0.00%，0 唤醒** |
| 跟随延迟 | 约 200ms | 约 150ms（事件即时触发） |

`AXObserverAddNotification` 对 outline 上的 `AXSelectedRowsChanged` 返回 0（可用），
实测点侧栏、键盘上下移动都能触发。Finder 重启（pid 变）和睡眠唤醒后重新订阅。

### 其它

- 补丁只在 Finder 前台显示，切走立刻隐藏（之前会挂在最后一个前台窗口上）
- Dock 白板空闲档 4Hz → 2Hz
- 移除全局 `NSEvent` 监听（实测空闭包就要 0.27%）

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