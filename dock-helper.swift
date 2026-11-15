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
        let r = bounds.insetBy(dx: -1, dy: -1)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26).fill()
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

    private func panelRect(_ cg: CGRect, top: CGFloat, flip: CGFloat) -> CGRect {
        let pad: CGFloat = 2
        return CGRect(x: cg.minX - pad, y: flip - (top + cg.height) - pad,
                      width: cg.width + pad * 2, height: cg.height + pad * 2)
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
            return
        }
        let settledTop = flip - cg.height - gap
        // Dock 自动隐藏时矩形落在屏外
        if cg.minY >= flip - 1 {
            // 收起：白板留在落定位置，等下次召唤直接点亮
            place(panelRect(cg, top: settledTop, flip: flip))
            rising = false
            setAlpha(Date() < armedUntil)
        } else if cg.minY > settledTop + 1 {
            // 升/收动画中：白板就停在最终位置。跟着动画走必然慢半拍，
            // Dock 顶边会先露出背景色，这正是要避免的那一闪。
            place(panelRect(cg, top: settledTop, flip: flip))
            rising = true
            setAlpha(true)
        } else {
            // 展开到位：贴住实测矩形，顺手学一次 Dock 离屏幕底边的间距
            gap = flip - cg.maxY
            place(panelRect(cg, top: cg.minY, flip: flip))
            rising = false
            setAlpha(true)
        }
    }
}

final class Driver {
    private let shade: DockShade
    private var timer: Timer?
    private var holdUntil = Date.distantPast
    private var wasHot = false
    private var atEdge = false
    private var interval: TimeInterval = 0
    private let hotBand: CGFloat = 160   // 距屏幕底边这么多点以内算「靠近 Dock」
    private let edgeBand: CGFloat = 6    // 真正压到 Dock 触发区的高度
    private let nearBand: CGFloat = 250  // 进入这个范围就提高采样率，好在指针压边时第一时间发现

    // 采样率：压着边缘、条正在升/收时 120Hz；接近底部 30Hz；其余 4Hz。
    // 为什么不用 NSEvent 全局监听：实测监听"什么都不做"也要 0.27% 单核
    // （事件本身要从 Window Server 送进本进程），而 4Hz 轮询只要 0.03%。
    // 这台笔屏有悬停漂移，指针一直在发事件，等于监听成本永远付满。
    private let trackInterval: TimeInterval = 1.0 / 120.0
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
                wasHot = true
                holdUntil = now.addingTimeInterval(0.8)
            } else if wasHot {
                wasHot = false
                holdUntil = now.addingTimeInterval(0.8)   // 指针离开后 Dock 还要播收起动画
            }
        } else {
            wasHot = hot
        }

        let tracking = atEdge || shade.engaged || now < holdUntil
        if tracking {
            shade.update()
            schedule(trackInterval)
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
        // 面板模式知道 Dock 是否升起，直接借用；没开面板时退化成总是显示
        if let shade = panelShade {
            hider.dockOnScreen = { [weak shade] in shade?.engaged ?? true }
        }
        hider.start()
        finderHider = hider     // 强引用
        print("\(Date()) dock-helper nofinder 已启动")
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
    private var timer: Timer?

    /// 由面板模式喂进来的「Dock 在不在屏上」。
    /// AX 的 Dock 矩形不反映实时状态（收起时仍返回落定位置 821），
    /// 而面板模式本来就知道 Dock 是否升起，直接借用最可靠。
    /// 面板没开时退化成「总是显示」。
    var dockOnScreen: (() -> Bool)?

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
        // 实测 level 5/10 完全盖不住，20 起能盖住，24 干净
        //（菜单栏窗口是 24，用同层但不抢它的位置；再高会压住菜单栏）。
        window.level = NSWindow.Level(rawValue: 24)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = FinderHiderView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        window.alphaValue = 0
        window.orderFrontRegardless()
    }

    /// Dock 的 AX 位置会跟着升降变（升起 y≈826、收起 y≈905），所以要跟住它。
    ///
    /// 采样率按状态自适应，和 Dock 白板同一套思路：
    ///   - Dock 在屏上（白板亮着）：0.1 秒，跟着升降不迟滞
    ///   - Dock 收起：1 秒，只为发现它重新升起
    /// 收起状态下的 1 秒一次是绝大部分时间，所以平均开销很低。
    private var visible = false

    func start() {
        refresh()
        schedule()
    }

    private func schedule() {
        let iv: TimeInterval = visible ? 0.1 : 1.0
        if let t = timer, t.timeInterval == iv { return }
        timer?.invalidate()
        let t = Timer(timeInterval: iv, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = iv * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard let pid = dockPID() else { hide(); return }
        if pid != lastDockPID { lastDockPID = pid; applied = nil }
        guard let flip = screenFlip() else { hide(); return }
        // AX 的 Dock 矩形不反映实时状态（收起后仍返回落定位置 821），
        // 所以用面板模式喂进来的信号判断 Dock 是否真的在屏上。
        if let probe = dockOnScreen, !probe() {
            hide()
            if visible { visible = false; schedule() }
            return
        }
        guard let item = finderDockItemRect() else {
            hide()
            return
        }
        if !visible { visible = true; schedule() }
        let target = coverRect(for: item, flip: flip)
        if applied != target {
            applied = target
            window.setFrame(target, display: true)
            window.orderFrontRegardless()
            if window.alphaValue < 1 { window.alphaValue = 1 }
        } else if window.alphaValue < 1 {
            window.alphaValue = 1
        }
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

    /// AX 左上原点 → NSWindow 左下原点。白板比图标略大一圈，盖掉阴影边。
    private func coverRect(for cg: CGRect, flip: CGFloat) -> CGRect {
        // 图标本身 53pt 宽。左右各外扩 6pt 把 Dock 的内边距吃掉，
        // 上面加 2pt 盖住图标的投影。这样整格被填满，不露蓝边。
        let padX: CGFloat = 6
        let padTop: CGFloat = 2
        return CGRect(x: cg.minX - padX,
                      y: flip - cg.maxY,
                      width: cg.width + padX * 2,
                      height: cg.height + padTop)
    }
}

/// Dock 底色的视觉近似。Dock 是毛玻璃，在彩墨屏上被白板压成接近纯白，
/// 这里用同色圆角块盖住，看起来就是"那个位置是空的"。
final class FinderHiderView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        // 不画圆角：Dock 的底板本身就是方角，圆角会在拐角露出底色，
        // 看着像"补了一块纸"。整块矩形铺满最稳。
        NSColor.white.setFill()
        bounds.fill()
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
