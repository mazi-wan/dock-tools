// 一个可执行文件、一个进程同时承担三件事，用启动参数控制开哪几项：
//   --panel=1   Dock 下方白色面板（原 dock-shade）
//   --tap=1     App 启动器点击修正（原 apps-toggle）
//   --menubar=1 菜单栏底色漂白 + 压掉底边那条深灰分隔线
//   --nofinder=1 用白板盖住 Dock 最左边的 Finder 图标（Finder 本身仍在）
// 两件事共用同一条辅助功能授权，系统设置里只需 dock-helper 一个条目。
// 守护脚本按配置传参；参数变化时重启这一个进程，两个开关仍互不影响。
//
// 面板模式：在 Dock 条正下方放一块白色面板，Dock 的半透明材质取样到这块白，
// 于是看起来是实色白，而窗口尺寸、菜单栏都不受影响。
// 层级必须是 floating(3)：实测 Dock 只采样到这一层，
// 普通层(0)会被别的窗口压住，Dock 层-1(19) 则完全采样不到。
// 条的矩形来自 Dock 进程的 AXList（CGWindowList 里 Dock 的窗口是整屏，不可用）。
//
// Dock 不发 AX 位置/大小通知（AXObserverAddNotification 返回 -25207），
// 所以触发源用鼠标事件：指针压到下边缘就开跟踪，离开后再跟一下收起动画，
// 其余时间不跑定时器；只在实际矩形变化时才移动窗口，避免无谓重绘。
// 跟踪期间每次都要问 Dock 位置，所以 Dock 的 pid 缓存起来，位置和大小一次取回。
//
// 白板一直挂在 Dock 落定后的位置上、alpha=0 隐身。召唤时只翻 alpha，不移动窗口：
// 窗口从屏幕外挪进屏幕要 2~3 帧才上屏，而 Dock 的升起动画两三帧就到了，
// 那样头几帧 Dock 会先透出背景再变白（闪一下）。alpha 切换一帧内就生效，
// 指针刚压到边缘先把白板点亮，Dock 升起时采样的第一帧就已经是白色。
//
// 点击模式：macOS 26 的 App 启动器(com.apple.campo, 进程名 "Siri AI")有个问题:
// 打开时点击 Dock 上的 App 图标, 会在 mouseDown 关闭窗口、mouseUp 又把它打开,
// 看起来像"点了没反应"。这里在打开状态下吞掉这次点击, 改发 AXPress 关闭。
import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit

let dbgOn = ProcessInfo.processInfo.environment["DOCK_SHADE_DEBUG"] != nil
let dbgStart = Date()
func dbg(_ s: @autoclosure () -> String) {
    guard dbgOn else { return }
    FileHandle.standardError.write(String(format: "%6.0f %@\n", Date().timeIntervalSince(dbgStart) * 1000, s()).data(using: .utf8)!)
}

func requestAccessibility() {
    let exe = CommandLine.arguments.first ?? "dock-helper"
    // 未授权时守护脚本会反复重启本进程；用二进制 mtime 做标记，同一次编译只弹一次提示
    let marker = NSHomeDirectory() + "/.cache/dock-helper-prompted"
    let mtime = ((try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let prev = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
    if prev == String(mtime) { return }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    FileHandle.standardError.write("等待授权：系统设置 → 隐私与安全性 → 辅助功能 → 点 + 添加 \(exe) 并勾选\n".data(using: .utf8)!)
    try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.cache", withIntermediateDirectories: true)
    try? String(mtime).write(toFile: marker, atomically: true, encoding: .utf8)
}

// MARK: - 面板模式

final class PanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // 圆角半径必须和 Dock 底板一致（实测 r≈23，见 dockCornerRadius）。
        // 以前写 26，白板比底板"更圆"，左上/左下角就在底板外多出一小块白。
        //
        // 也不再向外扩 1pt：扩出去的那一圈正好压在底板自己的抗锯齿边上，
        // 两个边缘互相咬合，放大看是一排细碎的灰点（"左上角有点不干净"）。
        // 白板略微内缩 0.5pt，让底板自己的边缘完整保留。
        // 白板圆角必须和 Dock 底板**同心同半径**，否则白板会在四角伸到底板外侧露白。
        //
        // 实测底板左边界轮廓（相对窗口原点）：y-offset 2 → x=132、offset 4 → 128、
        // offset 8 → 123、offset 14 → 120、offset 24 → 118（直边）。
        // 拟合出半径 16、圆心在 (118+16, 826+16)——比早先估的 23 小得多。
        // 用 23 时白板在 offset 2~14 这一段比底板更靠左，露出 255 的白色圆弧。
        // 白板本身画一个略大的白色圆角矩形。
        //
        // 注意：Dock 底板自己带一圈边缘高光（顶部和左上角那 1px 亮线），
        // 关掉本工具也在——那不是白板造成的，改不了。
        // 白板只要保证自己整块落在底板之内，就不额外引入白边。
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: dockPanelCornerRadius,
                     yRadius: dockPanelCornerRadius).fill()
    }
}

private var cachedDockPID: pid_t?

func dockPID() -> pid_t? {
    // Dock 重启后旧 pid 不再是运行中的 App，重新找一次
    if let p = cachedDockPID, NSRunningApplication(processIdentifier: p) != nil { return p }
    cachedDockPID = NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier
    return cachedDockPID
}

// Dock 的「条」元素缓存起来：每次重新 CreateApplication + 取 children 要多一次 IPC，
// 而 60/120Hz 跟踪时这个函数每秒要跑上百次。实测缓存后 0.08ms → 0.02ms 一次。
private var cachedTube: AXUIElement?
private var cachedTubePID: pid_t?

private func tubeElement(_ pid: pid_t) -> AXUIElement? {
    if cachedTubePID != pid { cachedTube = nil; cachedTubePID = pid }
    if let el = cachedTube { return el }
    let app = AXUIElementCreateApplication(pid)
    var kids: AnyObject?
    guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
          let el = (kids as? [AXUIElement])?.first else { return nil }
    cachedTube = el
    return el
}

func dockTubeRect() -> CGRect? {
    guard let pid = dockPID() else { return nil }
    // 位置和大小合并成一次 IPC，60Hz 下这点开销才压得住
    let attrs = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
    func query(_ el: AXUIElement) -> CGRect? {
        var vals: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &vals) == .success,
              let arr = vals as? [AnyObject], arr.count == 2,
              CFGetTypeID(arr[0]) == AXValueGetTypeID(),
              CFGetTypeID(arr[1]) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(arr[0] as! AXValue, .cgPoint, &p)
        AXValueGetValue(arr[1] as! AXValue, .cgSize, &s)
        guard s.width > 40, s.height > 20 else { return nil }
        return CGRect(origin: p, size: s)   // CG 全局坐标：原点在主屏左上，y 向下
    }
    guard let tube = tubeElement(pid) else { return nil }
    if let r = query(tube) { return r }
    // 元素失效（Dock 内部重建但 pid 没变）：丢掉缓存再找一次
    cachedTube = nil
    guard let fresh = tubeElement(pid) else { return nil }
    return query(fresh)
}

final class DockShade {
    let window: NSWindow
    private(set) var rising = false
    private var applied: CGRect?
    private var gap: CGFloat = 10      // 展开到位后 Dock 底边离屏幕底边的距离
    private var alphaOn = false
    private var lastDockPID: pid_t?
    private var armedUntil = Date.distantPast   // 压过边缘后的保护期，等 AX 跟上
    /// 上一帧 Dock 顶边，用来判断当前是升起还是收起。
    private var lastCgMinY: CGFloat = .infinity

    /// 遮住 Dock 上的 Finder。挂在这里是为了和白板共用同一帧几何，完全同步。
    var finderHider: FinderHider?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        // 想试别的层级：DOCK_SHADE_LEVEL=19 ./dock-helper --panel=1 --tap=0
        let lvl = Int(ProcessInfo.processInfo.environment["DOCK_SHADE_LEVEL"] ?? "") ?? 3
        window.level = NSWindow.Level(rawValue: lvl)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = PanelView(frame: .zero)
        window.alphaValue = 0
        window.orderFrontRegardless()
    }

    private func setAlpha(_ on: Bool) {
        guard on != alphaOn else { return }
        alphaOn = on
        window.alphaValue = on ? 1 : 0
        // 常驻日志：偶发空白 Dock 时靠这条轨迹定位是面板没藏还是 Dock 没画。
        // 每次切换都写盘：Dock 每 summon/收起一次就是一个 write syscall + 日志增长，
        // 且笔屏悬停漂移时 Dock 会频繁召唤/收起，I/O 比 CPU 更先成为瓶颈。
        if dbgOn { dbg("panel alpha=\(on ? 1 : 0)") }
    }

    private func place(_ rect: CGRect) {
        guard rect != applied else { return }
        dbg("place rect=\(rect)")
        window.setFrame(rect, display: false)
        applied = rect
    }

    /// 是否正处在「需要高频跟踪」的状态：白板亮着（Dock 在屏上）或 Dock 正在升/收。
    /// Dock 完全收起、白板也隐藏时，指针在热区里随便移动都不需要查 AX——
    /// 实测这种空转占掉了 helper 常驻开销的一半以上。
    var engaged: Bool {
        alphaOn || rising || Date() < armedUntil
    }

    // 白板矩形 = Dock 的 x/宽/高 + 上下留 pad，顶边跟随落定后的 Dock 顶
    // 翻转坐标在升/收动画期间每帧都要用（120Hz），缓存起来避免反复取 NSScreen。
    private var cachedFlip: CGFloat?
    private var cachedFlipSize = CGSize.zero

    /// 屏幕几何变了（分辨率、菜单栏、Dock 位置）时丢掉缓存。
    func invalidateGeometry() { cachedFlip = nil; applied = nil }

    private func flippedY() -> CGFloat? {
        guard let main = NSScreen.screens.first else { return nil }
        if let f = cachedFlip, cachedFlipSize == main.frame.size { return f }
        let f = main.frame.origin.y + main.frame.height
        cachedFlip = f
        cachedFlipSize = main.frame.size
        return f
    }

    /// 白板矩形。
    ///
    /// 不能直接用 AX 的条矩形：AX 报的是 Dock 的**命中区**（展开时 821..890），
    /// 而底板实际画在 826..895——命中区比底板整体高 5pt。
    /// 早期版本按命中区放白板，顶边就从 Dock 上方露出一条纯白（实测 819..826 全白）。
    ///
    /// 竖向直接对齐实测的底板范围：顶 = 落定后的 Dock 顶 + 5，
    /// 底 = 屏幕底边往上让 5pt（底板到 895，屏幕 900）。
    ///
    /// 横向同理，也要对齐底板而不是命中区：实测命中区 x=118 起，底板也是 118 起，
    /// 但早期给了 2pt pad，白板就比底板宽出一圈，在左右两端的圆角外侧
    /// 露出纯白（底色是壁纸 250,244,237，一眼能看出来）。
    /// 所以横向用零 pad——白板只要盖住底板，宽出去的每一像素都会露白。
    private func panelRect(_ cg: CGRect, top: CGFloat, flip: CGFloat) -> CGRect {
        let padX: CGFloat = 0
        let topInset: CGFloat = 5      // 命中区顶边 → 底板顶边
        let bottomInset: CGFloat = 5   // 底板底边 → 屏幕底边
        // 先按「屏幕坐标」（左上原点）算出上下边，再翻成 AppKit 的左下原点：
        // AppKit 的 y 是窗口底边，等于 flip - 屏幕下边。
        let screenTop = top + topInset
        let screenBottom = flip - bottomInset
        let h = screenBottom - screenTop
        return CGRect(x: cg.minX - padX, y: flip - screenBottom,
                      width: cg.width + padX * 2, height: h)
    }

    // 指针压到下边缘：白板本来就停在落定位置（只是透明的），这里立刻点亮。
    // 不查 AX，避免在事件回调里多等一次 IPC。
    func summon() {
        let now = Date()
        if now < armedUntil { return }
        armedUntil = now.addingTimeInterval(0.25)
        setAlpha(true)
        if applied == nil { update() }   // 刚启动还没校准过位置
    }

    func update() {
        guard let flip = flippedY() else { return }
        // Dock 重启（pid 变了）时旧白板可能盖在还没画好的 Dock 上，先藏掉重新校准
        let pid = dockPID()
        if pid != lastDockPID {
            lastDockPID = pid
            applied = nil
            setAlpha(false)
            FileHandle.standardError.write("\(Date()) Dock pid=\(pid.map { String($0) } ?? "nil")\n".data(using: .utf8)!)
        }
        guard let cg = dockTubeRect() else {
            // 读不到 Dock 矩形（Dock 正在重启/AX 暂不可用）：藏掉白板，避免一条空白 bar
            setAlpha(false)
            rising = false
            finderHider?.sync(tube: .zero, flip: flip, dockVisible: false, settled: false)
            return
        }
        let settledTop = flip - cg.height - gap
        // Dock 自动隐藏时矩形落在屏外
        if cg.minY >= flip - 1 {
            // 收起：白板留在落定位置（下次召唤直接点亮，不用再搬窗口），并灭掉。
            // 不灭的话底板已经滑走、白板还亮着，看着就是"白板消失有延迟"。
            //
            // armedUntil 里的例外：指针刚压到边缘时 summon() 会先点亮白板，
            // 好让 Dock 升起的第一帧就采到白。但 AX 这时还报"已收起"，
            // 这里不能再无脑灭掉——否则 summon 和 update 会以 120Hz 互相打架，
            // 表现为每 250ms 闪一下（同时把 CPU 拉到 2%）。
            place(panelRect(cg, top: settledTop, flip: flip))
            rising = false
            setAlpha(Date() < armedUntil)
        } else if cg.minY > settledTop + 1 {
            // 升/收动画中：白板停在最终位置。跟着动画走必然慢半拍，
            // Dock 顶边会先露出背景色，这正是要避免的那一闪。
            place(panelRect(cg, top: settledTop, flip: flip))
            // 方向决定亮还是灭：升起时白板要提前亮（Dock 一升上来就该采到白），
            // 收起时要立刻灭——底板正往下滑，露出来的是壁纸，
            // 白板留在原地就是一块"比 Dock 晚消失"的白，看着就是延迟。
            let goingDown = cg.minY > lastCgMinY + 0.5
            rising = !goingDown
            if goingDown {
                setAlpha(false)
            } else {
                setAlpha(true)
            }
        } else {
            // 展开到位：贴住实测矩形，顺手学一次 Dock 离屏幕底边的间距
            gap = flip - cg.maxY
            place(panelRect(cg, top: cg.minY, flip: flip))
            rising = false
            setAlpha(true)
        }

        // 和白板同一帧推进 Finder 遮盖。
        //
        // 注意这里传的是**落定位置**的 Dock 矩形，不是实时的 cg：
        // AX 报的位置比屏幕实际渲染滞后约 150ms（实测升起动画里底板已经到 860，
        // AX 还报 886），跟着它走遮罩就会慢半拍、让 Finder 露出来一大截。
        // 遮罩盖的是一块固定的面积，Dock 最终一定会到落定位置，
        // 所以直接按落点画——动画期间多盖的部分是白板/屏外，看不出来。
        // 白板自己也是这么做的（见上面 rising 分支的注释）。
        let settledTube = CGRect(x: cg.minX, y: settledTop,
                                 width: cg.width, height: cg.height)
        // dockVisible 用白板自己的状态：它已经知道 Dock 是否在屏上。
        // settled：只有 Dock 真的停在落点时才让遮罩去读 AX 校准图标偏移。
        lastCgMinY = cg.minY
        finderHider?.sync(tube: settledTube, flip: flip,
                          dockVisible: alphaOn || rising, settled: !rising)
    }
}

final class Driver {
    private let shade: DockShade
    private var timer: Timer?
    private var holdUntil = Date.distantPast
    private var wasHot = false
    private var atEdge = false
    private var interval: TimeInterval = 0
    private var lastPointer = CGPoint(x: -1, y: -1)
    private let hotBand: CGFloat = 160   // 距屏幕底边这么多点以内算「靠近 Dock」
    private let edgeBand: CGFloat = 6    // 真正压到 Dock 触发区的高度
    private let nearBand: CGFloat = 250  // 进入这个范围就提高采样率，好在指针压边时第一时间发现

    // 采样率：压着边缘、条正在升/收时 120Hz；接近底部 30Hz；其余 4Hz。
    // 为什么不用 NSEvent 全局监听：实测监听"什么都不做"也要 0.27% 单核
    // （事件本身要从 Window Server 送进本进程），而 4Hz 轮询只要 0.03%。
    // 这台笔屏有悬停漂移，指针一直在发事件，等于监听成本永远付满。
    // 三档采样率。
    //
    // 动画档只在 Dock 正在升/收、或指针压在触发区时用：这两段时间要跟住位置变化。
    // 静止档给「Dock 已经在屏上、指针也停住了」用——这时 Dock 位置不变，
    // 查 AX 纯属空转。实测这台屏只有 33Hz，静止时按 120Hz 轮询只能把 CPU 从
    // 0.6% 拉到 1.9%，画面一点不变。
    private let animInterval: TimeInterval = 1.0 / 120.0
    private let trackInterval: TimeInterval = 1.0 / 30.0
    private let nearInterval: TimeInterval = 1.0 / 30.0
    private let idleInterval: TimeInterval = 1.0 / 2.0

    init(shade: DockShade) {
        self.shade = shade
        // 启动时指针可能就压在 Dock 上，先按实际位置初始化，
        // 否则离开那一下不会被当成「刚离开」而补跟踪
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.screens.first
        let d = p.y - (screen?.frame.minY ?? 0)
        wasHot = d < hotBand
        atEdge = d <= edgeBand
    }

    func start() {
        schedule(idleInterval)
    }

    /// 切到指定采样率。和当前一致就什么都不做（Timer 每秒重建代价不小）。
    private func schedule(_ iv: TimeInterval) {
        if timer != nil && iv == interval { return }
        timer?.invalidate()
        interval = iv
        let t = Timer(timeInterval: iv, repeats: true) { [weak self] _ in self?.tick() }
        // 允许系统合并唤醒：这几档本来就不要求硬实时，省电优先
        t.tolerance = iv * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let p = NSEvent.mouseLocation   // 左下原点
        // 指针是否移动过：停在原地的悬停不该持续续期高频跟踪。
        let moved = p != lastPointer
        lastPointer = p
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.screens.first
        guard let screen else { schedule(idleInterval); return }
        let d = p.y - screen.frame.minY
        let hot = d < hotBand
        let edge = d <= edgeBand
        let now = Date()

        if edge != atEdge {
            atEdge = edge
            dbg("edge=\(edge) d=\(Int(d))")
        }
        // Dock 只在主屏上；副屏压边不该点亮主屏的白板
        if edge && screen.frame == NSScreen.screens.first?.frame { shade.summon() }

        // Dock 正在屏上/正在进出时才需要搬窗口；纯悬停不碰它
        if shade.engaged {
            if hot {
                // 只在指针**真的动了**才续期。否则指针停在 Dock 上不动时，
                // 每帧都续 0.35 秒，animating 永远为真，就一直按 120Hz 空转
                // （实测这会把 CPU 从 0.6% 拉到 2%）。
                if moved { holdUntil = now.addingTimeInterval(0.35) }
                wasHot = true
            } else if wasHot {
                wasHot = false
                // 指针离开后 Dock 还要播收起动画。实测整段约 210ms，
                // 这里给 350ms 留余量；早期写 0.8 秒，多出来的半秒全在 120Hz 空转。
                holdUntil = now.addingTimeInterval(0.35)
            }
        } else {
            wasHot = hot
        }

        // 采样率分两档：
        //   120Hz — 只在 Dock 真的在升/收的那一小段（rising 或刚离开后的 holdUntil）。
        //           这段时间位置每帧都变，跟不上就会露出壁纸/漏出 Finder。
        //   30Hz  — 其余所有需要跟踪的时间，包括指针压着触发区、Dock 稳定在屏上。
        //           这台屏本身只有 33Hz，30Hz 已经够用；实测按 120Hz 空转
        //           会把 CPU 从 0.6% 拉到 2%，画面毫无区别。
        let animating = shade.rising || now < holdUntil
        let tracking = atEdge || animating || shade.engaged
        if tracking {
            shade.update()
            schedule(animating ? animInterval : trackInterval)
        } else if d < nearBand {
            schedule(nearInterval)
        } else {
            schedule(idleInterval)
        }
    }
}

var lastTapPermissionLog = Date.distantPast

/// 面板的轮询驱动。必须强引用：它用 [weak self] 的 Timer，
/// 只放在 runHelper 的局部变量里会在函数返回后被释放，tick 就停了。
var panelDriver: Driver?

/// 面板在跑时留一个引用，供 FinderHider 判断 Dock 是否在屏上。
var panelShade: DockShade?

/// 遮住 Dock 上的 Finder。Timer 用 weak self，必须强引用。
var finderHider: FinderHider?


func runHelper() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // 面板和点击修正都依赖辅助功能：一个进程只授权一次。
    // 授权结果在旧进程里会被缓存，所以未授权时退出，交给守护脚本重启新进程重新检查。
    if !AXIsProcessTrusted() {
        requestAccessibility()
        sleep(5)
        exit(0)
    }

    if wantsPanel {
        let shade = DockShade()
        // 遮住 Dock 上的 Finder：需要跟着 Dock 升降一起动，
        // 所以复用面板那套跟踪循环，不自己起定时器。
        panelShade = shade
        let driver = Driver(shade: shade)
        driver.start()
        // Driver 内部用 [weak self] 的 Timer，如果没有强引用会被立刻释放、tick 再也不跑。
        // 挂在全局上跟进程同寿命。
        panelDriver = driver

        // 屏幕分辨率变化、切换桌面、Dock 重启、睡眠唤醒：都是低频事件，
        // 用通知直接补一次校准，不靠轮询去撞。
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            shade.invalidateGeometry()
            shade.update()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            shade.invalidateGeometry()   // 全屏 App 进出会改菜单栏显隐
            shade.update()
        }

        // Dock 重启 / 改 Dock 设置都会让 Dock 进程换一个 pid，有通知就直接跟上，不用等轮询
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.dock" else { return }
                cachedDockPID = nil
                cachedTube = nil
                shade.invalidateGeometry()
                shade.update()
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            shade.invalidateGeometry()
            shade.update()
        }

        // 慢速兜底：只防「矩形变了但没有任何通知」的极端情况，
        // 60 秒一次就够（每次 AX 查询 0.02ms，矩形没变时不会重绘、也不写日志）。
        let sweep = Timer(timeInterval: 60, repeats: true) { _ in shade.update() }
        sweep.tolerance = 20
        RunLoop.main.add(sweep, forMode: .common)

        shade.update()
        print("\(Date()) dock-helper panel 已启动")
        fflush(stdout)
    }

    if wantsNoFinder {
        let hider = FinderHider()
        if let shade = panelShade {
            // 面板在跑：由它的 120Hz 跟踪循环驱动，和 Dock 白板同帧
            shade.finderHider = hider
            hider.start(drivenByPanel: true)
        } else {
            // 面板没开：自己 0.1 秒查一次（精度差一些，但至少能盖住）
            hider.start(drivenByPanel: false)
        }
        finderHider = hider     // 强引用
        print("\(Date()) dock-helper nofinder 已启动（\(panelShade != nil ? "同步于 Dock 白板" : "独立轮询")）")
        fflush(stdout)
    }

    if wantsTap {
        if !startTap() { startTapRetry() }
    }

    if wantsMenuBar {
        let clean = MenuBarClean()
        clean.update()
        // 抓图由常驻 SCStream 在内容变化时推送，这里只做几何校正：
        // 菜单栏自动隐藏、全屏进出、改分辨率都不一定产生采集帧。
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in clean.restart() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { _ in clean.update() }
        // 睡眠：停掉 stream（省电，也不给睡眠添负担）；两个睡眠通知都挂上，
        // 显示器睡眠和整机睡眠是两条独立路径。
        let wsn = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            wsn.addObserver(forName: name, object: nil, queue: .main) { _ in clean.suspend() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            wsn.addObserver(forName: name, object: nil, queue: .main) { _ in clean.resume() }
        }
        let geo = Timer(timeInterval: 2, repeats: true) { _ in clean.update() }
        geo.tolerance = 0.8      // 允许系统合并唤醒，几何校正不要求准点
        RunLoop.main.add(geo, forMode: .common)
        print("\(Date()) dock-helper menubar 已启动")
        fflush(stdout)
    }

    app.run()
}

func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pv = axAttr(el, kAXPositionAttribute),
          let sv = axAttr(el, kAXSizeAttribute),
          CFGetTypeID(pv) == AXValueGetTypeID(),
          CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    guard s.width > 0, s.height > 0 else { return nil }
    return CGRect(origin: p, size: s)
}

// MARK: - 隐藏 Dock 最左边的 Finder

// Finder 是 macOS 硬编码在 Dock 第一位（subrole=AXApplicationDockItem，
// url=/System/Library/CoreServices/Finder.app）。它不在 com.apple.dock.plist 的
// persistent-apps 里，`defaults write com.apple.dock static-only -bool true` 也删不掉
// （实测无效，只是让图标重新排了一遍）。
//
// 所以走叠加层：从 Dock 的 AX 列表里找到 Finder 那一格，在它上面贴一块
// 和 Dock 底色一致的圆角白板。Finder 本身没被禁用，⌘N、点桌面都照旧。
//
// 成本：一次 AX 查询（0.02~0.05ms）。位置固定在落定位置，
// 和 Dock 白板一样不跟随升降动画，所以只需要低频校正。

final class FinderHider {
    private let window: NSWindow
    private var applied: CGRect?
    private var lastDockPID: pid_t?


    /// 由面板模式喂进来的「Dock 在不在屏上」。
    var dockOnScreen: (() -> Bool)?

    /// Finder 图标的**绝对**矩形（CG 全局坐标），只在 Dock 落定时读 AX 更新。
    ///
    /// 不用「相对 Dock 条的偏移」：Dock 收起时 tube 在屏外（[118,900]），
    /// 而 AX 给的图标坐标还是落定值（[125,826]），相减会得到 dy=+83，
    /// 反推回去就把遮罩算到屏幕外（实测 y=-73）。
    /// 图标在 Dock 里的落定位置是固定的，直接缓存绝对矩形最稳。
    private var itemRect: CGRect?
    private var itemPID: pid_t?
    private var itemAt = Date.distantPast

    /// 面板没开时的退路：自己的低频定时器（不太准但能用）。
    private var timer: Timer?

    init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 4, height: 4),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        // 层级必须够高：Dock 的图标是它自己画的，不是独立窗口。
        // 实测 level 3/5/10 完全盖不住（Finder 区域蓝色像素 5055→601），
        // 20 起才干净。用 24（和菜单栏窗口同层，但不会压住菜单栏）。
        window.level = NSWindow.Level(rawValue: 24)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = FinderHiderView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        window.alphaValue = 0
        window.orderFrontRegardless()
    }

    /// 面板在跑时由它驱动（120Hz，和 Dock 白板完全同步）。
    /// 面板没开则退回 0.1 秒自查。
    func start(drivenByPanel: Bool) {
        if drivenByPanel { return }
        refresh()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 由 DockShade 的跟踪循环每帧调用。
    ///
    /// `tube` 必须是**落定位置**的 Dock 条矩形（不是动画中的实时位置）：
    /// AX 报的位置比屏幕实际渲染滞后约 150ms，跟着它走遮罩会慢半拍、让 Finder 露出来。
    /// `settled` 表示 Dock 此刻真的在落定位置——只有这时才去读 AX 算图标偏移，
    /// 动画中读到的偏移会被算歪（实测会把遮罩算到屏幕外 y=-73）。
    func sync(tube: CGRect, flip: CGFloat, dockVisible: Bool, settled: Bool) {
        guard dockVisible else { hide(); return }
        guard let item = finderItem(settled: settled, flip: flip) else { hide(); return }

        let target = coverRect(for: item, flip: flip, dockLeft: tube.minX)

        if applied != target {
            applied = target
            window.setFrame(target, display: true)
            window.orderFrontRegardless()
            if window.alphaValue < 1 { window.alphaValue = 1 }
        } else if window.alphaValue < 1 {
            window.alphaValue = 1
        }
    }

    /// 面板没开时的自驱路径。
    func refresh() {
        guard let pid = dockPID(), let flip = screenFlip() else { hide(); return }
        if let probe = dockOnScreen, !probe() { hide(); return }
        guard let tube = dockTubeRect() else { hide(); return }
        guard tube.minY < flip - 20 else { hide(); return }
        if pid != lastDockPID { lastDockPID = pid; itemRect = nil }
        sync(tube: tube, flip: flip, dockVisible: true, settled: true)
    }

    /// 图标的绝对矩形（落定位置）。
    ///
    /// **不无条件缓存**：Dock 收起时 AX 给的图标坐标也在屏外（实测 y=905），
    /// 一旦缓存这个值，遮罩就会一直贴着屏外不动，看起来就是"完全没反应"。
    /// 所以只在图标位于屏幕内、尺寸正常时才采信。
    ///
    /// 也不能只在 settled 时读：进程刚启动、或 Dock 一直收着时永远等不到 settled，
    /// 遮罩就会停在 4x4 初始尺寸上从没校准过。所以每帧都试读，
    /// 只是把"动画期间读到的"丢掉（`settled` 只用来决定读取时机是否可信）。
    private func finderItem(settled: Bool, flip: CGFloat) -> CGRect? {
        let pid = dockPID()
        let now = Date()
        let cachedValid = itemRect.map { $0.midY < flip - 20 } ?? false
        if cachedValid, itemPID == pid, now.timeIntervalSince(itemAt) < 5 {
            return itemRect
        }
        // 动画中 AX 的 tube 在动、图标还是落定值，这两者不同步，读到的不能当落定数据。
        guard settled else { return cachedValid ? itemRect : nil }
        guard let r = finderDockItemRect(), r.width > 20, r.height > 20,
              r.midY < flip - 20 else { return cachedValid ? itemRect : nil }
        itemRect = r
        itemPID = pid
        itemAt = now
        return r
    }

    private func screenFlip() -> CGFloat? {
        guard let main = NSScreen.screens.first else { return nil }
        return main.frame.origin.y + main.frame.height
    }

    private func hide() {
        guard applied != nil || window.alphaValue > 0 else { return }
        applied = nil
        window.alphaValue = 0
    }

    /// AX 左上原点 → NSWindow 左下原点。
    ///
    /// 遮盖块要正好盖住「底板 + Finder 那一格」：左边界取 Dock 底板左边（那里是圆角，
    /// 见 FinderHiderView），右边界取 Finder 图标右边，上下各让 1pt
    /// 让底板自己那圈抗锯齿边保持原样，别让这一格比旁边深一档。
    private func coverRect(for cg: CGRect, flip: CGFloat, dockLeft: CGFloat) -> CGRect {
        // 右边界必须正好停在 Finder 图标右边：实测图标间距为 0（Finder 125.6..178.6，
        // Strata 从 178.6 起），多盖 1pt 就会压到下一个图标的左边缘和它的投影。
        let top = cg.minY + 1
        let bottom = cg.maxY - 1
        return CGRect(x: dockLeft,
                      y: flip - bottom,
                      width: cg.maxX - dockLeft,
                      height: bottom - top)
    }
}

/// Dock 底板左上/左下圆角半径，实测 r≈23（y=827 处边界在 x≈161，y=845 处到 x≈144）。
/// Dock **底板**的圆角半径（白板按这个画）。
/// 由左边界轮廓实测拟合：offset 2 → x=132、offset 4 → 128、offset 8 → 123、
/// offset 14 → 120、offset 24 → 118，即半径 16、圆心 (118+16, 826+16)。
let dockPanelCornerRadius: CGFloat = 23

/// Finder 遮盖块的圆角半径。遮盖块只盖最左边一格，边界要刚好停在底板圆角上，
/// 用同一套半径。
let dockCornerRadius: CGFloat = 16

/// Dock 底板的实测色，上下两端。
///
/// 白板生效时 Dock 是中性灰，但**有竖直渐变**（这是 Dock 材质自己的顶部内阴影，
/// 不是壁纸透出来的）：顶端 230,230,228 → 底端 237,237,235，单调递增，相差 7 级。
/// 实测（x=180 纯底色列，y 827..894）：230,231,232,233,234,235,236,237 一路爬上去。
///
/// 渐变方向搞反正是"上部看着有点透明"的根源：早期写成 顶237 → 底235，
/// 结果 Dock 顶部本该更暗、遮盖块却更亮，交界一眼能看出来。
///
/// 这两个值是固定写死的，运行时不做任何截图采样。
/// 注意别用「白板还没亮起来」时量到的值（例如 236,235,230）：那时 Dock 采到的是
/// 暖白壁纸 253,251,245，蓝通道低 6，拿它去画遮盖块会让左边发暖。
let dockBaseTop = NSColor(srgbRed: 234.0 / 255, green: 233.0 / 255, blue: 233.0 / 255, alpha: 1)
let dockBaseBottom = NSColor(srgbRed: 236.0 / 255, green: 235.0 / 255, blue: 233.0 / 255, alpha: 1)

/// Dock 底色的视觉近似：和底板同色的圆角块。
final class FinderHiderView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 左边两个角要跟底板一样圆：底板在屏幕左端是圆角，方块盖上去会在那儿多出一块灰。
        // 右边两角是直角——那条边落在两格图标之间的底色空隙里，同色相接看不出接缝。
        let r = min(dockCornerRadius, min(bounds.width, bounds.height) / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX + r, y: bounds.maxY))
        path.addArc(tangent1End: CGPoint(x: bounds.minX, y: bounds.maxY),
                    tangent2End: CGPoint(x: bounds.minX, y: bounds.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + r))
        path.addArc(tangent1End: CGPoint(x: bounds.minX, y: bounds.minY),
                    tangent2End: CGPoint(x: bounds.minX + r, y: bounds.minY), radius: r)
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.closeSubpath()

        let clip = NSBezierPath(cgPath: path)
        clip.addClip()
        // NSGradient 的起点参数是「下」、终点是「上」。底板顶端更暗（内阴影）、底端更亮。
        NSGradient(starting: dockBaseBottom, ending: dockBaseTop)?.draw(in: bounds, angle: 90)
    }
}

/// 找到 Dock 里 Finder 那一格的矩形（CG 全局坐标，左上原点）。
/// 直接遍历 Dock 的 AXList，取第一个 subrole 为 AXApplicationDockItem
/// 且 URL 指向 Finder.app 的元素。
private var cachedFinderItem: AXUIElement?
private var cachedFinderItemPID: pid_t?

func finderDockItemRect() -> CGRect? {
    guard let pid = dockPID() else { return nil }
    if cachedFinderItemPID != pid { cachedFinderItem = nil; cachedFinderItemPID = pid }
    var items: [AXUIElement] = []
    if let cached = cachedFinderItem {
        items = [cached]
    } else {
        guard let tube = tubeElement(pid),
              let all = axAttr(tube, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        items = all
    }
    for it in items {
        guard let url = axAttr(it, kAXURLAttribute) as? URL,
              url.path.hasSuffix("Finder.app") else { continue }
        cachedFinderItem = it
        guard let pv = axAttr(it, kAXPositionAttribute),
              let sv = axAttr(it, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(),
              CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        guard s.width > 20, s.height > 20 else { return nil }
        return CGRect(origin: p, size: s)
    }
    return nil
}

// MARK: - 菜单栏清理

// 「降低透明度」开着时(用户要求保留)，系统把菜单栏画成不透明灰(实测 sRGB 218)，
// 并在底边压一条 1pt 深灰线(约 120)加一段渐隐。彩墨屏上菜单栏本身和背景窗几乎同色，
// 这几样都是画面里最扎眼的横向条带。
//
// 系统没有单独控制它们的开关，所以自己画。分两部分：
//
//   1. 底色层：抓菜单栏窗口(layer 24)的内容，把浅色背景(218)归一化成纯白、图标文字保持原样，
//      以 level 25 原样贴回菜单栏位置。这是唯一能把图标和背景分离的办法——
//      菜单栏是 Window Server 的窗口，图标和背景在同一个窗口里，
//      AX 读不到里面元素(右侧状态栏由 ControlCenter 直接绘制，AX 节点为空)。
//   2. 底边：那条深线在菜单栏窗口之外(是这条窗口的投影)，上面那张图不含它，
//      所以在最底下再补 1pt 纯白。
//
// 采集用常驻 SCStream，只订阅菜单栏那一个窗口：窗口内容变了才送帧
// (时钟走字、切 App、展开菜单)，静止时一帧都没有。实测静止 20 秒 0~7 帧、
// 进程 CPU 0.1%、每帧漂白约 0.5ms。旧做法是每秒起一个 screencapture 子进程
// 再落盘解 PNG，稳定占 4~6% CPU。
//
// 睡眠：显示器睡眠/整机睡眠时把 stream 停掉，唤醒后重建；睡眠期间不做任何采集。
//
// 需要**屏幕录制权限**。被拒绝时 stream 起不来，只保留 1pt 白条
// (纯绘制，无需权限)，不会留下黑屏或白块。

final class MenuBarLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
    }
}

final class MenuBarImageView: NSView {
    var image: CGImage?
    var imagePointSize = CGSize.zero
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        guard let img = image else { return }
        // 按位图的原始尺寸贴，不拉伸：图高通常比菜单栏少 1pt(深线所在的那 1pt)，
        // 少掉的部分由上面的白底补足。
        let ih = min(bounds.height, imagePointSize.height > 0 ? imagePointSize.height : bounds.height)
        ctx.draw(img, in: CGRect(x: 0, y: bounds.height - ih, width: bounds.width, height: ih))
    }
}

/// 菜单栏窗口的单窗口采集。内容有变化才送帧，静止时不产生任何工作。
final class MenuBarCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// (漂白后的图, 内容哈希, 这张图对应的逻辑尺寸)
    var onFrame: ((CGImage, Int, CGSize) -> Void)?

    private var stream: SCStream?
    private var starting = false
    private var restartPending = false
    private var suspended = false
    private var retry: Timer?
    private var lastHash = 0
    private var pixelScale: CGFloat = 2
    private var expected = CGSize.zero
    private var lastNoteAt = Date.distantPast
    private let queue = DispatchQueue(label: "dock-tools.menubar.whiten", qos: .userInitiated)

    /// 失败提示 30 秒最多一条：守护进程会重试，别把日志刷爆
    private func note(_ text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastNoteAt) > 30 else { return }
        lastNoteAt = now
        FileHandle.standardError.write("\(now) \(text)\n".data(using: .utf8)!)
        fflush(stderr)
    }

    func start() {
        guard stream == nil, !starting, !suspended else { return }
        starting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // 菜单栏窗口：Window Server 的 layer 24、标题 "Menubar"，没有 owningApplication
                guard let bar = content.windows.first(where: { $0.windowLayer == 24 && $0.frame.width > 400 }) else {
                    throw NSError(domain: "dock-tools", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "找不到菜单栏窗口"])
                }
                let filter = SCContentFilter(desktopIndependentWindow: bar)
                let scale = CGFloat(filter.pointPixelScale)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(filter.contentRect.width * scale)
                cfg.height = Int(filter.contentRect.height * scale)
                // 最多 1 帧/秒。内容不变时 ScreenCaptureKit 不送帧，所以静止时开销接近 0。
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                cfg.queueDepth = 3
                cfg.showsCursor = false
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await s.startCapture()
                let w = cfg.width, h = cfg.height
                let adopted = await MainActor.run { () -> Bool in
                    self.starting = false
                    // 启动途中系统睡眠了：这张 stream 直接扔掉，等唤醒后重建
                    guard !self.suspended else { return false }
                    self.pixelScale = scale
                    self.expected = CGSize(width: w, height: h)
                    self.stream = s
                    self.lastHash = 0
                    return true
                }
                guard adopted else {
                    s.stopCapture { _ in }
                    return
                }
                let pending = await MainActor.run { () -> Bool in
                    let p = self.restartPending
                    self.restartPending = false
                    return p
                }
                // 启动期间又要过重启（改分辨率/唤醒）：拿新滤镜再来一次
                if pending { DispatchQueue.main.async { self.restart() } }
                print("\(Date()) 菜单栏采集已启动 \(w)x\(h)")
                fflush(stdout)
            } catch {
                let reason = error.localizedDescription
                await MainActor.run {
                    self.starting = false
                    self.note("菜单栏底色需要屏幕录制权限(系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 dock-helper)，暂时只处理底边：\(reason)")
                    self.scheduleRetry()
                }
            }
        }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.retry = nil
            self?.start()
        }
    }

    /// 屏幕/系统睡眠时停掉采集：睡眠期间没有画面可采，停掉既省电，
    /// 也不让 stream 在低功耗状态里继续占着捕获资源。
    func suspend() {
        guard !suspended else { return }
        suspended = true
        let old = stream
        stream = nil
        lastHash = 0
        old?.stopCapture { _ in }
        print("\(Date()) 菜单栏采集已暂停（屏幕/系统睡眠）")
        fflush(stdout)
    }

    /// 唤醒后重启采集。已经在跑时 start() 会直接返回。
    func resume() {
        let wasSuspended = suspended
        suspended = false
        if wasSuspended {
            print("\(Date()) 菜单栏采集已恢复（唤醒）")
            fflush(stdout)
        }
        start()
    }

    /// 分辨率变了、菜单栏窗口被重建、或从睡眠唤醒后滤镜可能已失效，重建一次
    func restart() {
        lastHash = 0
        if suspended { return }
        if starting {
            restartPending = true
            return
        }
        let old = stream
        stream = nil
        start()
        old?.stopCapture { _ in }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            // 主动重启/暂停时旧 stream 也会回调，别把新 stream 清掉
            guard s === self.stream else { return }
            self.stream = nil
            guard !self.suspended else { return }
            self.note("菜单栏采集中断，5 秒后重试：\(error.localizedDescription)")
            self.scheduleRetry()
        }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !suspended, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // 内容没变时 ScreenCaptureKit 仍按 1fps 送 "idle" 帧（实测静止 40 秒 42 帧里有 25 帧是 idle）。
        // 这些帧和上一帧画面完全相同，直接丢掉：省掉每秒一次的整幅漂白和新位图分配
        // （3200x60 约 77 万字节），这也是常驻内存的大头。
        // 只丢 idle/blank：started/complete 都要画，否则刚启动或刚唤醒时会一直没有图。
        if let status = frameStatus(sb), status == .idle || status == .blank { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CGFloat(w) == expected.width, CGFloat(h) == expected.height else {
            DispatchQueue.main.async { self.restart() }
            return
        }
        guard let (img, hash) = whiten(pb) else { return }
        // 内容哈希没变就不换图，避免无谓重绘和闪烁
        guard hash != lastHash else { return }
        lastHash = hash
        let scale = pixelScale
        let logical = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        DispatchQueue.main.async { self.onFrame?(img, hash, logical) }
    }

    /// 取这帧的 SCStreamFrameInfo.status。拿不到就当作有内容（宁可多重画一次，不要漏帧）。
    private func frameStatus(_ sb: CMSampleBuffer) -> SCFrameStatus? {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// BGRA 像素里把浅色背景(亮度 ≥200)推成纯白，深色像素(图标/文字)原样保留。
    /// 哈希按「漂白之后」的内容算，只反映图标文字的增减，背景扰动不会触发重绘。
    /// 位图缓冲按尺寸复用：每帧新建一个 3200x60 的 context 要 77 万字节，
    /// 频繁换图（展开菜单时每秒几次）会让分配器反复 mmap/munmap。
    private var canvas: CGContext?
    private var canvasSize = CGSize.zero

    private func bitmapContext(_ w: Int, _ h: Int) -> CGContext? {
        let size = CGSize(width: w, height: h)
        if let c = canvas, canvasSize == size { return c }
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        canvas = c
        canvasSize = size
        return c
    }

    private func whiten(_ pb: CVPixelBuffer) -> (CGImage, Int)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = bitmapContext(w, h), let dst = ctx.data else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        let out = dst.assumingMemoryBound(to: UInt8.self)
        var hash = 5381
        for y in 0..<h {
            var si = y * stride
            var di = y * w * 4
            for _ in 0..<w {
                let b = Int(src[si]), g = Int(src[si + 1]), r = Int(src[si + 2])
                let lum = (299 * r + 587 * g + 114 * b) / 1000
                let white = lum >= 200
                out[di] = white ? 255 : src[si]
                out[di + 1] = white ? 255 : src[si + 1]
                out[di + 2] = white ? 255 : src[si + 2]
                out[di + 3] = 255
                hash = ((hash &* 33) ^ (white ? 255 : lum)) & 0x7fffffff
                si += 4
                di += 4
            }
        }
        guard let img = ctx.makeImage() else { return nil }
        return (img, hash)
    }
}

final class MenuBarClean {
    private let bg: NSWindow
    private let line: NSWindow
    private let capture = MenuBarCapture()
    private var hasImage = false
    private var lastBar: CGFloat = -1     // 0 = 已隐藏（全屏/自动隐藏）

    init() {
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))

        bg = NSWindow(contentRect: CGRect(x: 0, y: -20000, width: 4, height: 4),
                      styleMask: .borderless, backing: .buffered, defer: false)
        bg.isOpaque = true
        bg.backgroundColor = .white
        bg.hasShadow = false
        bg.ignoresMouseEvents = true
        bg.isMovable = false
        bg.isReleasedWhenClosed = false
        bg.level = NSWindow.Level(rawValue: menuLevel + 1)
        bg.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        bg.orderFrontRegardless()

        line = NSWindow(contentRect: CGRect(x: 0, y: -20000, width: 4, height: 1),
                        styleMask: .borderless, backing: .buffered, defer: false)
        line.isOpaque = true
        line.backgroundColor = .white
        line.hasShadow = false
        line.ignoresMouseEvents = true
        line.isMovable = false
        line.isReleasedWhenClosed = false
        line.level = NSWindow.Level(rawValue: menuLevel + 1)
        line.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        line.contentView = MenuBarLineView(frame: CGRect(x: 0, y: 0, width: 4, height: 1))
        line.orderFrontRegardless()

        capture.onFrame = { [weak self] img, _, logical in self?.show(img, logical) }
        capture.start()
    }

    private func parkAll() {
        lastBar = 0
        let off = CGRect(x: 0, y: -20000, width: 4, height: 4)
        if bg.frame != off { bg.setFrame(off, display: false) }
        let offLine = CGRect(x: 0, y: -20000, width: 4, height: 1)
        if line.frame != offLine { line.setFrame(offLine, display: false) }
    }

    private func show(_ img: CGImage, _ logical: CGSize) {
        hasImage = true
        if let v = bg.contentView as? MenuBarImageView {
            v.image = img
            v.imagePointSize = logical
            v.needsDisplay = true
        } else {
            let v = MenuBarImageView(frame: CGRect(origin: .zero, size: bg.frame.size))
            v.autoresizingMask = [.width, .height]
            v.image = img
            v.imagePointSize = logical
            bg.contentView = v
        }
        update()
    }

    func restart() {
        capture.restart()
        invalidateGeometry()
        update()
    }

    func suspend() { capture.suspend() }

    func resume() {
        capture.resume()
        invalidateGeometry()
        update()
    }

    /// 只摆位置，不抓图：抓图由常驻 stream 在内容变化时推送。
    /// orderFrontRegardless 是 Window Server 调用，只在几何真的变了才发，
    /// 2 秒一次的纯几何校正不应该有窗口副作用。
    ///
    /// visibleFrame 要走一次 Window Server 通讯（实测 9.9µs，是 frame 的 90 倍），
    /// 而这里每 2 秒就会被调一次。它只在菜单栏显隐、Dock 位置、分辨率变化时改变，
    /// 所以缓存起来，靠尺寸和屏幕参数通知失效。
    private var cachedBar: CGFloat?
    private var cachedScreenSize = CGSize.zero

    /// 屏幕几何变化（分辨率、菜单栏显隐、Dock 位置）时丢掉缓存。
    func invalidateGeometry() { cachedBar = nil }

    private func menuBarHeight(_ s: NSScreen) -> CGFloat {
        if let b = cachedBar, cachedScreenSize == s.frame.size { return b }
        let b = s.frame.maxY - s.visibleFrame.maxY
        cachedBar = b
        cachedScreenSize = s.frame.size
        return b
    }

    func update() {
        guard let s = NSScreen.screens.first else { parkAll(); return }
        let bar = menuBarHeight(s)
        // 菜单栏自动隐藏/全屏时高度是 0 或整屏，此时没有菜单栏可处理
        guard bar >= 20, bar <= 80 else { parkAll(); return }

        let lineFrame = CGRect(x: s.frame.minX, y: s.frame.maxY - 1,
                               width: s.frame.width, height: 1)
        if line.frame != lineFrame {
            line.setFrame(lineFrame, display: true)
            line.orderFrontRegardless()
        }

        // 还没有图（没授权 / stream 还没来第一帧）：只保留底边那条白条
        guard hasImage else {
            let off = CGRect(x: 0, y: -20000, width: 4, height: 4)
            if bg.frame != off { bg.setFrame(off, display: false) }
            return
        }

        let bgFrame = CGRect(x: s.frame.minX, y: s.frame.maxY - bar,
                             width: s.frame.width, height: bar)
        if bg.frame != bgFrame {
            bg.setFrame(bgFrame, display: true)
            bg.orderFrontRegardless()
            // 底色层换位后，底边白条要重新提到最前，否则会被盖住
            line.orderFrontRegardless()
        }

        if bar != lastBar {
            let reappeared = lastBar == 0
            lastBar = bar
            dbg("menubar bar=\(Int(bar)) 已漂白")
            // 从全屏/隐藏状态回来时手上那张图可能是几十秒前的，重新取一帧
            if reappeared { capture.restart() }
        }
    }
}

// MARK: - 启动器点击修正模式


let launcherBundle = "com.apple.campo"
let dockBundle = "com.apple.dock"

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func findAppsItem(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 6 { return nil }
    if let u = attr(el, kAXURLAttribute) as? URL, u.path.contains("Apps.app") { return el }
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { if let f = findAppsItem(k, depth: depth + 1) { return f } }
    }
    return nil
}

func dockAppsItem() -> AXUIElement? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundle).first else { return nil }
    let appEl = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(appEl, 0.4)
    guard let item = findAppsItem(appEl) else { return nil }
    AXUIElementSetMessagingTimeout(item, 0.4)
    return item
}

func itemFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}

func launcherOpen() -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: launcherBundle).first else { return false }
    let pid = Int32(app.processIdentifier)
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
              (w[kCGWindowLayer as String] as? Int) == 23,
              ((w[kCGWindowAlpha as String] as? Double) ?? 0) > 0.5,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              ((b["Width"] as? Double) ?? 0) > 500,
              ((b["Height"] as? Double) ?? 0) > 300 else { continue }
        return true
    }
    return false
}

var pendingToggle = false
var tap: CFMachPort?

func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // 点击中途 tap 被禁用时 mouseUp 可能收不到，清掉状态免得之后一直吞拖动
        pendingToggle = false
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    case .leftMouseDown:
        let p = event.location
        // Dock 只在主屏底边一带；点在别处直接放行，
        // 不然每次点击都要枚举全系统窗口（launcherOpen），白白卡一下
        if let h = NSScreen.screens.first?.frame.height, p.y < h - 160 {
            return Unmanaged.passUnretained(event)
        }
        if launcherOpen(), let item = dockAppsItem(), let f = itemFrame(item), f.contains(p) {
            pendingToggle = true
            return nil
        }
    case .leftMouseDragged:
        if pendingToggle { return nil }
    case .leftMouseUp:
        if pendingToggle {
            pendingToggle = false
            DispatchQueue.main.async {
                if let item = dockAppsItem() {
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                }
            }
            return nil
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

let tapCallback: CGEventTapCallBack = { proxy, type, event, _ in
    handle(proxy, type, event)
}

let tapMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
    | (1 << CGEventType.leftMouseUp.rawValue)
    | (1 << CGEventType.leftMouseDragged.rawValue)

func startTap() -> Bool {
    if tap != nil { return true }
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: tapMask, callback: tapCallback, userInfo: nil) else { return false }
    tap = t
    let src = CFMachPortCreateRunLoopSource(nil, t, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    print("\(Date()) dock-helper tap 已启动")
    fflush(stdout)
    return true
}

func startTapRetry() {
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        if tap != nil { return }
        if !startTap(), Date().timeIntervalSince(lastTapPermissionLog) > 10 {
            print("\(Date()) 无法创建事件监听，10 秒后重试")
            fflush(stdout)
            lastTapPermissionLog = Date()
        }
    }
}

func usageAndExit(_ code: Int32) -> Never {
    FileHandle.standardError.write("用法: dock-helper [--panel=0|1] [--tap=0|1] [--menubar=0|1] [--nofinder=0|1]\n".data(using: .utf8)!)
    exit(code)
}

// 不带参数时两个功能都开，方便手动调试；守护脚本总是显式传两个开关
var wantsPanel = CommandLine.arguments.count == 1
var wantsTap = CommandLine.arguments.count == 1
var wantsMenuBar = CommandLine.arguments.count == 1
var wantsNoFinder = CommandLine.arguments.count == 1
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--panel=1": wantsPanel = true
    case "--panel=0": wantsPanel = false
    case "--tap=1": wantsTap = true
    case "--tap=0": wantsTap = false
    case "--menubar=1": wantsMenuBar = true
    case "--menubar=0": wantsMenuBar = false
    case "--nofinder=1": wantsNoFinder = true
    case "--nofinder=0": wantsNoFinder = false
    case "help", "-h", "--help": usageAndExit(0)
    default: usageAndExit(2)
    }
}

if wantsPanel || wantsTap || wantsMenuBar || wantsNoFinder {
    runHelper()
}
