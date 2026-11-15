# dock-tools

给彩墨屏（Paperlike 253C，3200×1800）收拾 macOS 的几处毛玻璃/半透明：  
不注入进程、不改系统外观设置，全部用「自己画一块不透明窗口垫在后面」的方式实现。

| 开关                     | 作用                                    |
| ---------------------- | ------------------------------------- |
| `dock_opaque`          | Dock 条垫白板，Dock 材质取样成实色                |
| `menu_white`           | Chrome 右键菜单后面垫白板，菜单不再透出网页内容           |
| `remove_window_shadow` | 关掉所有普通窗口的阴影                           |
| `apps_toggle`          | 启动器打开时再点 Dock 图标能正常关闭（macOS 26 的 bug） |
| `menu_bar_line`        | 菜单栏漂成纯白，并压掉底边那条 1pt 深灰线               |
| `hide_finder`          | 用白板盖住 Dock 最左边的 Finder 图标                    |

配置文件 `~/.config/dock-tools/config.conf`，保存后约 2 秒生效。  
程序本体从 `~/Library/Application Support/dock-tools/` 启动（launchd 读不了 NFS）；  
源码留在本项目目录，改完执行 `./dock-tools.sh apply` 会重新编译并同步。

```sh
./dock-tools.sh on | off | apply | revert | status | build | install
```

---

## 工作原理

### 1. Dock 不透明（`dock_opaque`）

「降低透明度」开着时 Dock 是毛玻璃。在 Dock 条**正后方**放一块白色 window（level 3，点击穿透），
Dock 的材质从它取样，呈现为实色白。

- 位置靠 AX 读 Dock 的矩形；白板直接**停在最终落点**，避免慢半拍时顶边露出背景色
- 指针靠**自适应定时器轮询**跟踪（4/30/120Hz 三档）；Dock 重启/改设置/睡眠唤醒用通知直接跟上
- Dock 的 AX 元素缓存住；另有 60 秒一次的慢速兜底
- AX 查询 0.08 ms → 0.02 ms

### 2. 隐藏 Dock 上的 Finder（`hide_finder`）

Finder 是 macOS **硬编码在 Dock 第一位**的（`subrole=AXApplicationDockItem`，
`url=/System/Library/CoreServices/Finder.app`），它不在 `com.apple.dock.plist` 的
`persistent-apps` 里，`defaults write com.apple.dock static-only -bool true` 也删不掉
（实测无效，只是把图标重排了一遍）。

所以用叠加层：从 Dock 的 AX 列表里找到 Finder 那一格，在它上面贴一块白色方块。
Finder 本身没被禁用，⌘N、点桌面都照旧。

实现上有两个坑：

1. **层级必须 24**。Dock 的图标是它自己画的、不是独立窗口，
   level 3/5/10 完全盖不住（实测 Finder 区域蓝色像素 5055→601），20 起才干净。
2. **AX 的 Dock 矩形不反映实时状态**：Dock 收起后 `AXPosition` 仍返回落定位置 821，
   不会变成 900。所以「Dock 在不在屏上」借用面板模式已有的 `engaged` 信号，
   面板没开时退化成总是显示。

**和白板共用同一帧几何**：Finder 图标在 Dock 条里的相对位置是固定的
（实测条 `(144,821,1312,69)`、图标 `(152,826,53,69)`，偏移 `+8,+5`），
所以只要缓存这个偏移，就能用白板每帧拿到的实时 Dock 矩形推出图标位置，
跟着升/收动画一起走，不必额外查 AX，也没有可见延迟。
沿升/收动画中每 30ms 采样一次，两个窗口的 alpha 和位置都是同帧更新。

Dock 收起时两者一起隐藏；面板没开时退回 0.1 秒自查（精度差些，但至少能盖住）。

### 3. Chrome 菜单白底（`menu_white`）

Chrome 右键菜单（layer 101）也是毛玻璃。同样在它后面垫白色圆角板（level 3）。  
菜单一关闭窗口就从 `CGWindowList` 里消失，据此收掉白板——**空闲时不跑定时器**。

### 4. 去窗口阴影（`remove_window_shadow`）

交给 yabai：`yabai -m config window_shadow off`。  
守护循环只在 yabai 换 pid / 开关切换 / 60 秒时重发。

### 5. 启动器点击修正（`apps_toggle`）

macOS 26 里启动器（`com.apple.campo`）打开时，点 Dock 图标不会关闭它。  
用 CGEvent tap 监听点击，命中 Dock 的「启动器」格子且启动器正开着时，补发一次 AX press。

### 6. 菜单栏漂白（`menu_bar_line`）

「降低透明度」开着时系统把菜单栏画成不透明灰（实测 sRGB 218），  
并在底边压一条 1pt 深灰线（约 120）。彩墨屏上菜单栏和背景窗几乎同色。

|         | 处理前 | 处理后     |
| ------- | --- | ------- |
| 菜单栏主体   | 218 | **255** |
| 底边那 1pt | 122 | **255** |

用 ScreenCaptureKit 的常驻 `SCStream` 只订阅菜单栏那一个窗口（Window Server layer 24），  
每帧把亮度 ≥200 的像素归一化成纯白，图标/文字原样保留，再以 level 25 贴回。  
另有一根 1pt 白条盖住底边深线。idle 帧直接丢弃（不做漂白、不建位图）。

为什么只能这么绕：菜单栏是 Window Server 自己的窗口，背景和图标在同一张图里，  
AX 读不到里面的元素，所以没法「只重绘背景、保留图标」地重建。

旧做法每秒起一个 `screencapture` 子进程：单帧 100ms+、占单核 4~6%、内存 96 MB。  
改成常驻 stream 后：空闲开销 0.15%、内存 7~10 MB、切 App / 菜单 / 时钟 1 秒内跟上。

---

## 性能消耗

| 组件 | CPU | 内存 |
| --- | --- | --- |
| 菜单栏漂白（常驻 stream + 1fps 心跳）| 约 0.15%          | 位图约 1–2 MB    |
| Dock 白板（2Hz 轮询，指针远离 Dock）  | 约 0.05%          | 约 10 MB       |
| 启动器点击修正                     | 约 0.01%          | 约 7 MB        |
| 隐藏 Finder（跟白板同帧，收起不耗）  | 约 0.03%          | 约 1 MB        |
| `dock-helper` 合计             | **约 0.2~0.45%** | 17~67 MB（见下） |
| `menu-shade`                | 0%（无定时器）         | 约 60 MB       |
| 守护脚本                        | **约 0.05%**      | 约 3 MB        |

内存那 60 MB 是 ScreenCaptureKit 的帧缓冲池，按需分配、能完全回收（`phys_footprint` 纯业务部分只有 7~10 MB）。

---

## 睡眠

- 显示器/整机睡眠时停掉菜单栏的 `SCStream`，唤醒后再重建。
- 不申请任何电源断言，不会阻止系统或显示器休眠。

---

## 硬盘读写

| 组件 | 磁盘行为 |
| --- | --- |
| `dock-helper` | **无**：SCStream 完全在内存（IOSurface），不落盘 |
| `menu-shade` | **无**：纯窗口绘制 |
| 守护脚本 | 配置只在 mtime/size 变化时读；日志 30 秒才轮转一次；零子进程 |
| `panel alpha=` 日志 | 已改为 debug-gate（`DOCK_SHADE_DEBUG=1`），日常不写盘 |
| 菜单栏底色层 | `CGContext` 复用，不落盘 |

30 秒测量：日志文件大小稳定（0 字节变化），无持续 I/O。

---

## 权限

- **辅助功能**：`dock-helper`（读 Dock 矩形、启动器 AX 点击）。
- **屏幕录制**：`dock-helper`（抓菜单栏）。没有权限时不会崩，只退化成盖住底边那 1pt 深线，  
  并在日志里提示一次。
- `menu-shade` 不需要任何授权。

## 签名与授权

`build` 时用本地自签证书签名（identity `dock-tools Local Signing`）。  
TCC 授权绑定到证书（`certificate leaf = H"3cd57b92..."`）而不是二进制的 cdhash，  
所以**重新编译不会再丢授权**。

## 已知限制

- 菜单栏只能整条重贴，多屏时只处理主屏。
- 菜单栏自动隐藏或全屏（高度为 0 或整屏）时不做处理。
- 白板是叠加层，不是真的改应用绘制；极端情况下有不到 1 秒的滞后。

---

## 优化记录

详见 [CHANGELOG.md](CHANGELOG.md)。
