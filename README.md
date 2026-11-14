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
| `finder_sidebar`       | Finder 侧栏选中行换一块更明显的浅色底（墨水屏上原色几乎看不出） |

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

### 2. Chrome 菜单白底（`menu_white`）

Chrome 右键菜单（layer 101）也是毛玻璃。同样在它后面垫白色圆角板（level 3）。  
菜单一关闭窗口就从 `CGWindowList` 里消失，据此收掉白板——**空闲时不跑定时器**。

### 3. 去窗口阴影（`remove_window_shadow`）

交给 yabai：`yabai -m config window_shadow off`。  
守护循环只在 yabai 换 pid / 开关切换 / 60 秒时重发。

### 4. 启动器点击修正（`apps_toggle`）

macOS 26 里启动器（`com.apple.campo`）打开时，点 Dock 图标不会关闭它。  
用 CGEvent tap 监听点击，命中 Dock 的「启动器」格子且启动器正开着时，补发一次 AX press。

### 5. Finder 侧栏选中（`finder_sidebar`）

墨水屏上 Finder 侧栏的选中条几乎看不出来：实测选中底是 (224,224,224)、
侧栏底色是 (246,246,246)，只差 **22 级灰度**，这块屏的灰阶分辨力把它压平了。

系统没有可用的开关：侧栏选中不走 accent 色（那是给列表选中行的橙底白字），
`AppleHighlightColor` 只管文字选中，`increaseContrast` 已经开着也没用。
所以用和 Dock 白板同一套办法：读 AX 拿到选中行的矩形，贴一块 alpha 0.55 的浅蓝，
底下的图标和文字照常透出来，只是把背景压深一档。

关键是**怎么查 AX**。这一点决定了方案贵不贵：

| 做法 | 耗时 |
| --- | --- |
| 盲目遍历整棵 AX 树 | **122 ms** |
| 走固定路径 `window → AXSplitGroup[0] → AXScrollArea[0] → AXOutline` | **0.44 ms** |

拿到 outline 后读 `AXSelectedRowsAttribute` 就是选中行。
刷新用 **AX 事件驱动**（`AXSelectedRowsChanged` + `AXFocusedUIElementChanged`），
空闲时 0 唤醒、0 CPU；切走 Finder 时立刻隐藏。
只在 Finder 前台时生效，其它 App 的侧栏不受影响。

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
| Finder 侧栏（AX 事件驱动）          | **0.00%**（0 唤醒）| 约 10 MB       |
| `dock-helper` 合计             | **约 0.2~0.35%** | 17~67 MB（见下） |
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
