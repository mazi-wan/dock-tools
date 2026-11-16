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
        // 白板只是"垫在 Dock 后面的白纸"，不需要自己描出 Dock 的轮廓：
        // Dock 底板会把整块采样掉，白板自己的边缘只在超出底板时才会露出来。
        //
        // 所以做法很简单——四周内缩 1pt、圆角用 dockPanelCornerRadius。
        // 内缩是为了让白板自己的抗锯齿边落在底板之内。
        //
        // 注意：Dock 底板自带一圈边缘高光（顶部和左上角那 1px 亮线），
        // 关掉本工具也在，那不是白板造成的，改不了。
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
    /// 展开到位后，Dock **命中区**底边离屏幕底边的距离。只用来从 AX 命中原点
    /// 反推落定位置，不参与白板自己的矩形计算（那个用实测的底板范围，
    /// 见 panelRect 里的 topInset / bottomInset——两者差 5pt，混用会错位）。
    private var gap: CGFloat = 10
    private var alphaOn = false
    private var lastDockPID: pid_t?
    /// 上一帧 Dock 顶边，用来判断当前是升起还是收起。
    /// 初值是 nil 而不是 ±infinity：第一帧还不知道方向，不该猜成"升起"。
    private var lastCgMinY: CGFloat?

    /// 指针是否还在 Dock 这条带子上（横向在 Dock 范围内、纵向在 Dock 顶边以下，
    /// 含最底那 5pt 白边）。收起是「指针离开这个区域」触发的：
    /// 离开后的那一两百毫秒里 AX 还报落定位置 821，但屏幕上的图标已经开始滑了，
    /// 这段时间也要把遮盖块下沿推出屏幕（见 FinderHider.sync 的 protectBottom）。
    ///
    /// 不能只看「是否压着底边」：那样指针在 Dock 里（y≈860）也算离开，
    /// 下沿会一直外推，落定后 Finder 那一格下方多一条 61×5pt 的暗条
    /// （236,235,233 vs 白边 250,244,237），常态可见。
    private var pointerOverDock = true

    /// 当前这段动画的方向。AX 在动画里会小抖（回退 1~2pt），
    /// 早先每帧拿相邻两帧直接比大小，方向会来回翻——表现为收起途中
    /// 白板/压平层闪回一下（实测 pan/flat 的 alpha 是 0→1→0）。
    /// 所以方向做成"粘性"状态：同向连续 3 帧才改。
    private enum Motion { case unknown, rising, falling }
    private var motion: Motion = .unknown
    private var motionVotes = 0

    /// 用相邻两帧的位移更新方向，粘性见上。
    private func updateMotion(_ y: CGFloat) {
        guard let last = lastCgMinY else { return }
        let delta = y - last
        guard abs(delta) >= 0.5 else { return }
        let dir: Motion = delta > 0 ? .falling : .rising
        if motion == dir { motionVotes = 0; return }
        motionVotes += 1
        if motion == .unknown || motionVotes >= 3 {
            motion = dir
            motionVotes = 0
        }
    }

    private func resetMotion() { motion = .unknown; motionVotes = 0 }

    /// 遮住 Dock 上的 Finder。挂在这里是为了和白板共用同一帧几何，完全同步。
    var finderHider: FinderHider?

    /// 压平 Dock 顶部那条内阴影。同样挂在这里，和白板共用几何。
    var topFlattener: DockTopFlattener?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 关掉 alpha/上屏的隐式动画：默认淡入会让窗口服务器用 0.25 秒
        // 从「几乎看不见」渐变到 1，升起开头那一百多毫秒遮盖块等于不存在。
        window.animationBehavior = .none
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
        // 遮盖块也算：收起动画里白板先灭、遮盖块要一直跟着图标滑到屏外，
        // 这段时间必须继续跟踪（否则最后一次 update 停在 alpha=1 就再没人改它）。
        alphaOn || rising || (finderHider?.isVisible ?? false)
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
        // 这两个 inset 是「AX 命中区 ↔ 底板实际渲染范围」的固定差，实测 5pt：
        //   命中区 y 821..890，底板 y 826..895（整体下移 5）。
        // 它们和白板自己记录屏幕底边距的 gap 是两回事（gap 描述命中区，
        // 由 AX 实测学习；这两个描述底板，是窗口内容的固定偏移）。
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

    // 指针压到下边缘：白板本来就停在落定位置（只是透明的），这里立刻点亮，
    // 好让 Dock 升起的第一帧就采到白。
    //
    // 只在"指针刚压上来"那一下点亮（由 Driver 的 atEdge 边沿触发），
    // 不能每帧都续期 armedUntil——指针停在屏幕底部不动时，Dock 其实会自己收起，
    // 而 expiresAfter 一直有效会让白板/遮盖块跟着一直亮着，
    // 表现为"Dock 收起了、Finder 那一块还没消失"。
    func summon() {
        setAlpha(true)
        // 遮盖块也要一起提前点亮。AX 在升起开始时还报「收起」（滞后约 100ms），
        // 这段时间 update() 走的是收起分支、遮盖块 alpha=0，图标从屏幕底部
        // 钻出来时整块都能看见（实测 3/6 次，最多 3677 个彩色像素、y 858..899）。
        expectRiseUntil = Date().addingTimeInterval(0.35)
        if applied == nil { update() }   // 刚启动还没校准过位置
    }

    /// 刚压边、Dock 还没被 AX 报出来的那段时间。只在这段时间里把遮盖块
    /// 提前摆到落定位置（白板本来就是这么干的，见 summon 的注释）。
    private var expectRiseUntil = Date.distantPast

    func update() {
        guard let flip = flippedY() else { return }
        // Dock 重启（pid 变了）时旧白板可能盖在还没画好的 Dock 上，先藏掉重新校准。
        // 这里查一次 pid 就够：dockTubeRect() 内部还会再查（它自己会缓存），
        // 但那个调用只在 pid 变化时才多花一次 NSRunningApplication。
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
            topFlattener?.sync(tube: .zero, innerTop: 0, flip: flip, dockVisible: false)
            return
        }
        let settledTop = flip - cg.height - gap
        // 落定位置的 Dock 条矩形。遮盖块/压平层都按它画——AX 报的位置比屏幕
        // 实际渲染滞后（升起最快时差 25pt 以上），拿实时 cg 算会慢半拍。
        let settledTube = CGRect(x: cg.minX, y: settledTop,
                                 width: cg.width, height: cg.height)
        // Dock 自动隐藏时矩形落在屏外
        let onScreen = cg.minY < flip - 1
        if !onScreen {
            // 收起：白板留在落定位置（下次召唤直接点亮，不用再搬窗口），并灭掉。
            // 不灭的话底板已经滑走、白板还亮着，看着就是"白板消失有延迟"。
            //
            // 这里必须无条件灭掉：Dock 的 AX 已经报"在屏外"，屏幕上也确实收起了，
            // 白板再亮着就是一块凭空多出来的白。
            // （唯一的例外是下面那段 expectRiseUntil：指针刚压边、Dock 正要升起，
            //   这时遮盖块必须提前亮，否则图标会从屏幕底部钻出来。）
            //
            // 早期这里写 setAlpha(Date() < armedUntil)，靠一个 0.25 秒保护期保底，
            // 结果是指针停在屏幕底部不动时 armedUntil 被反复续期，白板和 Finder
            // 遮盖块会一直亮着不消失。现在 summon() 只在刚压边时点一次，
            // 不参与这里的判断。
            place(panelRect(cg, top: settledTop, flip: flip))
            rising = false
            resetMotion()
            setAlpha(false)
            // 指针刚压边、AX 还没报出升起的那 100ms：遮盖块也要亮着。
            // 不亮的话图标会从屏幕底部直接钻出来（见 summon 的注释）。
            // settled 传 false：这会儿读到的图标矩形是屏外的 905，不能用。
            if Date() < expectRiseUntil {
                finderHider?.sync(tube: settledTube, flip: flip, dockVisible: true,
                                  settled: false, slide: 0, protectBottom: true)
                topFlattener?.sync(tube: settledTube, innerTop: settledTop + 20, flip: flip,
                                   dockVisible: true, slide: 0)
            } else {
                finderHider?.sync(tube: .zero, flip: flip, dockVisible: false, settled: false)
                topFlattener?.sync(tube: .zero, innerTop: 0, flip: flip, dockVisible: false)
            }
            // 这里必须返回：下面那段公共的 sync 用的是 dockVisible: onScreen，
            // 而收起时 onScreen 恰好是 false，会把上面刚点亮的遮盖块再 hide() 掉
            // （实测表现就是"压边后遮盖块晚了 40ms 才出现"）。
            return
        } else if cg.minY > settledTop + 1 {
            // 升/收动画中：白板停在最终位置。跟着动画走必然慢半拍，
            // Dock 顶边会先露出背景色，这正是要避免的那一闪。
            place(panelRect(cg, top: settledTop, flip: flip))
            // 方向决定亮还是灭：升起时白板要提前亮（Dock 一升上来就该采到白），
            // 收起时要立刻灭——底板正往下滑，露出来的是壁纸，
            // 白板留在原地就是一块"比 Dock 晚消失"的白，看着就是延迟。
            updateMotion(cg.minY)
            let goingDown = motion == .falling
            rising = !goingDown
            setAlpha(!goingDown)
        } else {
            // 展开到位：贴住实测矩形，顺手学一次 Dock 离屏幕底边的间距
            gap = flip - cg.maxY
            place(panelRect(cg, top: cg.minY, flip: flip))
            rising = false
            resetMotion()
            setAlpha(true)
        }

        // 和白板同一帧推进 Finder 遮盖。
        //
        // 几何按**落定位置**画，不是实时 cg：AX 报的位置比屏幕实际渲染滞后
        // （升起动画里底板已经到 860，AX 还报 886），拿它算遮罩的矩形会算歪。
        // 遮罩盖的是一块固定的面积，Dock 最终一定会到落定位置。
        // 只有收起时的位移例外，见下面的 slide。
        // settled：只有 Dock 真的停在落点时才让遮罩去读 AX 校准图标偏移。
        // 收起动画里遮盖块必须跟着图标一起往下滑——白板可以立刻灭（底板下方
        // 露出来的是壁纸），但 Finder 那一格如果留在原地，图标会从它下面露出来
        // （实测收起后 105ms、图标已经下滑 20pt 时，遮盖块 alpha 已经是 0，
        //   Finder 槽里有 1743 个彩色像素、y 861..899，就是用户看到的"闪一下"）。
        //
        // 位移直接用 AX 报的 Dock 顶边：实测它比屏幕上的实际渲染**滞后约 8pt**
        // （图标下滑 20pt 时 AX 只报 13pt），拿它当偏移等于让遮盖块略微滞后，
        // 永远不会比图标先走，也就不会露出图标上沿。
        // 遮盖块上边本来就比图标高 14pt、下边低 5pt，这点滞后全落在余量里。
        //
        // 再往前补 5pt：上面那个"滞后 8pt"是实测均值，补 5 之后遮盖块/压平层
        // 相对底板只偏低 3pt——底板顶边上方多出 3pt 白，比少盖 8pt（顶边露出
        // 一条深灰）更容易忽略。也不能补满 8：这 8pt 不是常数，动画起止时
        // 速度慢、滞后小，补满就会让遮盖块比图标先走，反而把图标上沿露出来。
        //
        // **只有收起（falling）才跟**。升起时同一份 AX 滞后方向正好相反：
        // 屏幕上图标已经升到 860，AX 还报 890，遮盖块按 890 摆就比图标低 30pt，
        // 图标整个上半截会从遮盖块上沿露出来（实测升起途中 Finder 槽
        // 2979 个彩色像素、y 844..875）。起落两个方向的滞后不对称，
        // 所以升起时遮盖块/压平层保持落定位置不动——落定位置本来就比图标
        // 顶端高 11pt（830 vs 841），够盖住整个升起过程。
        let rawSlide = max(0, cg.minY - settledTop)
        let slide = (motion == .falling && rawSlide > 0) ? rawSlide + 5 : 0
        //
        // 下沿外推还要多看一个信号：指针是否已经离开底边。收起是指针离开后
        // 才开始的，从离开到 AX 报出位移之间，屏幕上的图标已经在滑、AX 还报 821。
        // 这 8~16ms 里只靠 slide 判断不出来（slide=0、settled=true），
        // 屏幕最底 5pt 会露出图标底边（实测抓到过 845 个彩色像素、y 893..899）。
        // 指针还在不在 Dock 这条带子上。纵向只卡上边界：Dock 顶边以下是 Dock 本身
        // 和它下面那 5pt 白边，指针停在白边上（y≈893）时 Dock 照样开着，
        // 不该外推；只有指针升到 Dock 顶边以上、或横向移出 Dock 范围，收起才开始。
        let pm = NSEvent.mouseLocation
        let pt = CGPoint(x: pm.x, y: flip - pm.y)
        pointerOverDock = pt.x >= settledTube.minX - 1 && pt.x <= settledTube.maxX + 1
            && pt.y >= settledTube.minY - 1
        let stable = !rising && slide < 0.5
        lastCgMinY = cg.minY
        finderHider?.sync(tube: settledTube, flip: flip,
                          dockVisible: onScreen,
                          settled: stable,
                          slide: slide,
                          protectBottom: !(stable && pointerOverDock))
        // 内阴影带的下沿：图标真正开始绘制的那一行（AX 图标矩形从 826 起，
        // 但那是命中区，实测第一行彩色像素在 841）。
        // 下沿停在 840（settledTop 821 + 20，含 840 这一行）。
        //
        // 这个数字是一行一行试出来的（+17/+18/+19/+20/+21 各跑一遍截图对比）：
        //   +17、+18 → 838/839 整条暗 4 级，图标上方留一条浅横线
        //   +19     → 839 好了，但 840 在图标位置是 225（图标抗锯齿被切）
        //   +20     → 836..840 全部 237，图标从 841 的 16 开始，完整保留  ← 用这个
        //   +21     → 把图标第一行（841）也盖掉
        // 也就是说图标的抗锯齿实际从 841 才开始有可见像素，之前的暗行都是
        // 压平层自己下边缘的半行抗锯齿。
        topFlattener?.sync(tube: settledTube, innerTop: settledTop + 20, flip: flip,
                           dockVisible: onScreen, slide: slide)
    }
}

final class Driver {
    private let shade: DockShade
    private var timer: Timer?
    private var holdUntil = Date.distantPast
    private var wasHot = false
    /// 指针是否压在触发区里。带迟滞：
    /// 进入按 edgeBand(6pt)，退出要退到 edgeBand + 6pt 才算离开。
    /// 不加迟滞时指针停在边界上（这台笔屏 y≈898 抖动 ±1pt），
    /// atEdge 会每帧翻一次，justPressed 反复触发 summon()，
    /// 白板就以 120Hz 在亮/灭之间抖（日志里能看到 alpha 1→0→1→0）。
    private var atEdge = false
    private var interval: TimeInterval = 0
    private var lastPointer = CGPoint(x: -1, y: -1)
    private let hotBand: CGFloat = 160   // 距屏幕底边这么多点以内算「靠近 Dock」
    private let edgeBand: CGFloat = 6    // 真正压到 Dock 触发区的高度
    private let nearBand: CGFloat = 250  // 进入这个范围就提高采样率，好在指针压边时第一时间发现
    /// 已经贴到底边上方 80pt：随时会压边。这一档提到 120Hz，只为让 summon()
    /// 早几毫秒——Dock 一开始动就已经在画图标，30Hz 的轮询延迟（实测压边
    /// 到被发现的间隔能到 40ms）足够图标从屏幕底钻出来一整块
    /// （实测 y 858..899、3677 个彩色像素）。
    ///
    /// 40 不够：指针停在离底 40pt 时按 30Hz 轮询，最后那 24ms 的压边动作
    /// 正好落在两次轮询中间，第一次发现已经是 40ms 之后。
    /// 这一档只在「Dock 收着」时生效（Dock 在屏上走 engaged 分支），
    /// 而且只轮询指针、不查 AX，代价很小。
    private let pressBand: CGFloat = 80

    // 采样率：压边/动画 120Hz；贴到底边上方 80pt 30Hz；其余 20Hz。
    // 为什么不用 NSEvent 全局监听：实测监听"什么都不做"也要 0.27% 单核
    // （事件本身要从 Window Server 送进本进程）。
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
    /// 指针离 Dock 很远时的空闲档。**不能像早期那样写 1/2 秒**：
    /// 快速划到底边时，整段移动会落在两次采样之间。实测这样第一次发现
    /// "已经压边"时已经到了压边后 160ms，Dock 早升完、Finder 图标露了 3 帧。
    /// 20Hz 只读 NSEvent.mouseLocation，实测开销约 0.1% 单核。
    private let idleInterval: TimeInterval = 1.0 / 20.0

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
        // 迟滞：已经在触发区里就放宽退出阈值，避免边界抖动反复触发
        let edge = d <= (atEdge ? edgeBand + 6 : edgeBand)
        let now = Date()

        // 只在"指针刚压到边缘"这个边沿点亮白板（而不是压着就每帧点一次）。
        // 压着不放时 Dock 会自己收起，那时白板必须能灭掉——见 DockShade.update()
        // 收起分支的注释。
        let justPressed = edge && !atEdge
        if edge != atEdge {
            atEdge = edge
            dbg("edge=\(edge) d=\(Int(d)) t=\(Date().timeIntervalSince1970)")
        }
        if d < 200 { dbg("tick t=\(Date().timeIntervalSince1970) d=\(Int(d)) iv=\(Int(1000/interval))ms engaged=\(shade.engaged)") }
        // Dock 只在主屏上；副屏压边不该点亮主屏的白板
        if justPressed && screen.frame == NSScreen.screens.first?.frame { shade.summon() }

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
        } else if d < pressBand {
            // 只轮询指针、不碰窗口（update 不会跑），很便宜
            schedule(animInterval)
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

/// 压平 Dock 顶部内阴影的那条窄带。同样要强引用。
var topFlattener: DockTopFlattener?


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

    // 顶部内阴影压平：只依赖 panel（需要白板那套几何跟踪才知道 Dock 在哪）。
    // 不要绑到 wantsNoFinder 上——那是"隐藏 Finder"的开关，和这个功能无关，
    // 关掉 Finder 遮盖后顶部内阴影就会重新露出来。
    if wantsPanel {
        let flattener = DockTopFlattener()
        if let shade = panelShade {
            shade.topFlattener = flattener
        }
        topFlattener = flattener      // 强引用
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

// MARK: - 压平 Dock 顶部那条内阴影

// Dock 底板顶部有一条约 15pt 的内阴影带：从 y=826 的 239 一路降到 y=840 的 224，
// 而图标区下方的平坦值是 237。视觉上就是"上半截发灰、不是纯白"。
//
// 这条渐变是 Dock 自己画的，垫白板改不了（白板只能把整体抬到 234 上下）。
// 唯一能做的是**在 Dock 之上**（层级 24）盖一条同样颜色的窄带，把它抹平成 237。
//
// 为什么碰不到图标：AX 报的图标矩形从 y=826 起，但那是**命中区**；
// 图标真正开始绘制是 y=841（实测第一行彩色像素）。所以 826..840 这段是纯底色，
// 盖住它不会切到任何图标。
//
// 只在 Dock 展开时显示，和白板/遮盖块共用同一帧几何。

final class DockTopFlattener {
    private let window: NSWindow
    private var applied: CGRect?
    private var shown = false
    /// 落定位置。隐藏时窗口留在这里不动，只把内容画成透明。
    private var home: CGRect?

    init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 4, height: 4),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 关掉 alpha/上屏的隐式动画：默认淡入会让窗口服务器用 0.25 秒
        // 从「几乎看不见」渐变到 1，升起开头那一百多毫秒遮盖块等于不存在。
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: 24)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = DockTopFlatView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    /// tube 是落定的 Dock 命中区矩形；`innerTop` 是内阴影带的底边（屏幕坐标）。
    /// `slide` 是 Dock 收起时已经下滑的点数（0 表示停在落定位置）。
    func sync(tube: CGRect, innerTop: CGFloat, flip: CGFloat, dockVisible: Bool,
              slide: CGFloat = 0) {
        guard dockVisible else { hide(); return }
        // 带子从底板顶边（命中区顶 + 5）到最后一行非图标像素。
        let screenTop = tube.minY + 5
        let screenBottom = innerTop
        guard screenBottom > screenTop else { hide(); return }
        // 铺满整条，两端的圆角交给视图自己裁（见 DockTopFlatView）。
        // 缩进的做法会在圆角区留下一块没压平的暗区，交界处出现一条竖直硬边。
        var target = CGRect(x: tube.minX,
                            y: flip - screenBottom,
                            width: tube.width,
                            height: screenBottom - screenTop)
        if slide < 0.5 || home == nil { home = target }
        // 收起动画里压平层要跟着 Dock 一起下滑，不能直接灭掉：
        // Dock 收起时屏幕上能看到的其实主要是这条内阴影带（底板本体的
        // 平坦区跟着滑出屏幕了），不压平就是一条深灰横条在往下走。
        target.origin.y -= slide
        // 纯位移不重绘：收起动画里这一层每帧都在移动，
        // 内容（渐变）不变，交给窗口服务器搬表面就够。
        // 隐藏期间窗口停在 home（见 hide），所以上屏只是把内容改回不透明。
        if applied != target {
            applied = target
            // 改尺寸必须重绘：改 frame 不会重新落笔，多出来的那块是空的。
            // 只有 1258×15，重绘代价可以忽略。
            let resized = target.size != window.frame.size
            window.setFrame(target, display: resized)
            if resized { window.contentView?.needsDisplay = true }
            window.orderFrontRegardless()
        }
        if !shown {
            shown = true
            (window.contentView as? DockTopFlatView)?.faded = false
        }
    }

    private func hide() {
        guard applied != nil || shown else { return }
        applied = nil
        shown = false
        // 摆回落定位置、只把内容画成透明（理由同 FinderHider.hide）：
        // 窗口保持 alpha=1、留在屏内，表面和合成顺序都不会丢。
        if let home, window.frame != home { window.setFrame(home, display: true) }
        (window.contentView as? DockTopFlatView)?.faded = true
    }
}

/// 顶部压平层：图标区下方的平坦底板色，两端按底板圆角裁剪。
final class DockTopFlatView: NSView {
    override var isOpaque: Bool { false }

    /// 隐藏状态：只改图层不透明度，不重画。
    /// 原因见 FinderHiderView.faded（重画要打包上传，100ms 起）。
    var faded = false {
        didSet { layer?.opacity = faded ? 0.01 : 1 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 渐变只建一次：draw 会随几何变化重跑，颜色是常量。
    private lazy var gradient: NSGradient? = {
        let top = NSColor(srgbRed: 237.0 / 255, green: 237.0 / 255, blue: 236.0 / 255, alpha: 1)
        let bottom = NSColor(srgbRed: 237.0 / 255, green: 236.0 / 255, blue: 234.0 / 255, alpha: 1)
        return NSGradient(starting: bottom, ending: top)
    }()

    override func draw(_ dirtyRect: NSRect) {
        // 圆角只作用在**上边**两个角：这一条的下半截接着图标区，那里必须是直角
        // （图标区两侧是直的），下边画圆角会在中间凭空切出两个缺口。
        //
        // 用一个上圆下直的路径：左上/右上走圆角，左下/右下直接落到底。
        //
        // 上圆角半径要贴着底板真实轮廓：实测底板左边界从 y=826 的 x=191
        // 收缩到 y=844 的 x=172（相对窗口左沿 171 即 20 → 1），半径约 19。
        // 用 dockPanelCornerRadius（23）时圆角外侧留出一大片没盖住的壁纸。
        let r: CGFloat = 19
        let p = CGMutablePath()
        p.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        p.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY - r))
        p.addArc(tangent1End: CGPoint(x: bounds.minX, y: bounds.maxY),
                 tangent2End: CGPoint(x: bounds.minX + r, y: bounds.maxY), radius: r)
        p.addLine(to: CGPoint(x: bounds.maxX - r, y: bounds.maxY))
        p.addArc(tangent1End: CGPoint(x: bounds.maxX, y: bounds.maxY),
                 tangent2End: CGPoint(x: bounds.maxX, y: bounds.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        p.closeSubpath()

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        NSBezierPath(cgPath: p).addClip()
        // 顶端到底端有极轻的余留渐变（237 → 236），保证和下方图标区接得上。
        gradient?.draw(in: bounds, angle: 90)
    }
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

    /// 落定位置（67 高，不含下沿外推）。
    private var home: CGRect?
    /// 隐藏时停放的位置：落定矩形 + 下沿外推（91 高）。
    ///
    /// 隐藏时停在这里是有原因的：升起动画里遮盖块用的就是这个几何
    /// （`protectBottom` 把它往下推 24pt）。隐藏时就先把窗口摆好，升起时
    /// 它既不用改尺寸也不用改位置，只把内容改回不透明，省掉一次重绘。
    private var parked: CGRect?
    /// 是否处于「显示」状态。窗口 alphaValue 恒为 1，不能用它判断。
    private var shown = false

    init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 4, height: 4),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 关掉 alpha/上屏的隐式动画：默认淡入会让窗口服务器用 0.25 秒
        // 从「几乎看不见」渐变到 1，升起开头那一百多毫秒遮盖块等于不存在。
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        // 层级必须够高：Dock 的图标是它自己画的，不是独立窗口。
        // 实测 level 3/5/10 完全盖不住（Finder 区域蓝色像素 5055→601），
        // 20 起才干净。用 24（和菜单栏窗口同层，但不会压住菜单栏）。
        window.level = NSWindow.Level(rawValue: 24)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = FinderHiderView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        v.faded = true              // 起始就是隐藏状态
        window.contentView = v
        window.alphaValue = 1       // 恒为 1：隐藏靠视图画淡，不碰窗口
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
    /// AX 报的位置比屏幕实际渲染滞后（升起动画最快时能差 25pt 以上），
    /// 拿它算遮罩的矩形会慢半拍、让 Finder 露出来。
    /// `settled` 表示 Dock 此刻真的在落定位置——只有这时才去读 AX 算图标偏移，
    /// 动画中读到的偏移会被算歪（实测会把遮罩算到屏幕外 y=-73）。
    /// `slide` 是 Dock 收起动画里已经下滑的点数（0 表示停在落定位置）。
    /// 收起时遮盖块要跟着图标一起滑下去，否则图标会从它下面露出来。
    /// `protectBottom` 表示要把下沿推出屏幕：Dock 没停稳、或指针已经离开底边
    /// （收起即将开始/正在进行）时都要推。
    func sync(tube: CGRect, flip: CGFloat, dockVisible: Bool, settled: Bool,
              slide: CGFloat = 0, protectBottom: Bool = false) {
        guard dockVisible else { hide(); return }
        guard let item = finderItem(settled: settled, flip: flip,
                                    settledTubeTop: tube.minY) else { hide(); return }

        var target = coverRect(for: item, flip: flip, dockLeft: tube.minX)
        // 落定位置（不含 slide / 下沿外推）。隐藏时窗口停在这里。
        //
        // **只在真正落定时更新**：收起分支也会调 sync（好让遮盖块跟着图标
        // 滑下去），那时 target 已经被推到屏幕外。早先写成 `settled || home == nil`
        // 就踩过这个坑——home 记成屏幕外的矩形，隐藏时窗口照样搬出屏幕，
        // 表面还是丢，升起依旧漏帧。
        if settled && slide < 0.5 && !protectBottom { home = target }
        // 升起动画里用的几何：落定矩形再往下推 24pt（和下面的 protectBottom 同一算法）。
        if settled && slide < 0.5, let h = home {
            var p = h
            p.origin.y -= 24
            p.size.height += 24
            parked = p
        }
        // 只要不在稳定落定状态，就把下沿推到屏幕外再往下 24pt。
        //
        // 两个原因：
        //
        // 1. 落定位置的下沿在 `屏幕底 - 5`，左下角还是圆的（半径 16），
        //    正好和底板自己的圆角重合，静止时看不出缺口。图标一往下滑，
        //    缺口就切到图标左下角，屏幕最底部会露出一小段蓝色圆弧。
        // 2. 收起刚开始的 0~110ms 里 AX 还没报位移（`rawSlide` 仍是 0），
        //    但屏幕上的底板/图标已经在往下走了。实测这段时间里屏幕最底
        //    5pt（y 894..899）会露出 Finder 图标本体 500 多个像素，
        //    形状正是底板左下圆角的缺口——这不是"滑块没跟上"，
        //    而是滑块还停在落定点，图标已经从它下面的缺口钻出来了。
        //
        // 所以判据是「Dock 没停稳，或者指针已经离开底边」。
        // 一旦落定且指针还在底边，就恢复圆角，静止画面和原来完全一致。
        if protectBottom {
            let extra: CGFloat = 24
            target.origin.y -= extra
            target.size.height += extra
        }
        // AppKit 的 y 是窗口底边：往屏幕下方滑 = y 减小。
        target.origin.y -= slide

        if applied != target {
            applied = target
            // 尺寸变了必须重绘：改 frame 不会重新落笔，升起第一帧高度就从
            // 67 变 91（下沿外推），用 display:false 的话这块新区域是空的，
            // 图标正好从那儿露出来。这块视图只有 61×91，重绘代价可以忽略。
            let sizeChanged = target.size != window.frame.size
            window.setFrame(target, display: sizeChanged)
            if sizeChanged { window.contentView?.needsDisplay = true }
            window.orderFrontRegardless()
        }
        if !shown {
            shown = true
            // 只改图层不透明度，**不重画**：内容一直在图层缓存里，
            // 重画要走一遍打包/上传（实测 100ms 以上），
            // 那段时间屏幕上就是 Finder 图标。
            (window.contentView as? FinderHiderView)?.faded = false
        }
    }

    /// 遮盖块当前是否可见。DockShade.engaged 用它决定要不要继续跟踪。
    var isVisible: Bool { shown }

    /// 面板没开时的自驱路径。
    func refresh() {
        guard let pid = dockPID(), let flip = screenFlip() else { hide(); return }
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
    /// 遮罩就会停在 4x4 初始尺寸上从没校准过。所以每帧都试读：x/宽/高随时可信
    /// （Finder 槽位不会横移），y 一律换成落定顶推出来的值，不跟随动画。
    private func finderItem(settled: Bool, flip: CGFloat, settledTubeTop: CGFloat) -> CGRect? {
        let pid = dockPID()
        let now = Date()
        let cachedValid = itemRect.map { $0.midY < flip - 20 } ?? false
        if cachedValid, itemPID == pid, now.timeIntervalSince(itemAt) < 5 {
            return itemRect
        }
        // 图标槽位在 Dock 条里是固定的：AX 给的 x/宽/高在动画里也不会变；
        // y 则跟着 Dock 走（收起时甚至是屏外的 905），所以不能用。
        // 落定顶 = 条顶（settledTubeTop）+ 5，这是图标命中区的实际落点
        // （实测条 821..890、图标 826..895）。
        guard let r = finderDockItemRect(), r.width > 20, r.height > 20 else {
            return cachedValid ? itemRect : nil
        }
        let settledRect = CGRect(x: r.minX, y: settledTubeTop + 5,
                                 width: r.width, height: r.height)
        // 只有落定时才写缓存：动画里读到的 x 也可能在过渡（比如 Dock 正在换布局）。
        if settled {
            itemRect = settledRect
            itemPID = pid
            itemAt = now
            return settledRect
        }
        return cachedValid ? itemRect : settledRect
    }

    private func screenFlip() -> CGFloat? {
        guard let main = NSScreen.screens.first else { return nil }
        return main.frame.origin.y + main.frame.height
    }

    private func hide() {
        guard applied != nil || shown else { return }
        applied = nil
        shown = false
        // 停到「升起时要用」的位置，再把内容画成透明。
        //
        // 关键是**窗口本身不动**：不把 alpha 降到 0、不搬到屏幕外。
        // 那两种做法都会让窗口服务器把它摘出合成，重新上屏要重建表面，
        // 实测 150~200ms——正好是升起动画的长度（see FinderHiderView.faded）。
        if let p = parked ?? home, window.frame != p {
            window.setFrame(p, display: true)
        }
        (window.contentView as? FinderHiderView)?.faded = true
    }

    /// AX 左上原点 → NSWindow 左下原点。
    ///
    /// 遮盖块要正好盖住「底板 + Finder 那一格」：左边界取 Dock 底板左边（那里是圆角，
    /// 见 FinderHiderView），右边界取 Finder 图标右边，上下各让 1pt
    /// 让底板自己那圈抗锯齿边保持原样，别让这一格比旁边深一档。
    private func coverRect(for cg: CGRect, flip: CGFloat, dockLeft: CGFloat) -> CGRect {
        // 右边界必须正好停在 Finder 图标右边：实测图标间距为 0（Finder 125.6..178.6，
        // Strata 从 178.6 起），多盖 1pt 就会压到下一个图标的左边缘和它的投影。
        //
        // 上边界回到图标矩形顶端 +1（=827）。不能从压平层下沿（+20=846）开始：
        // 图标实测从 841 就开始绘制，846 已经越过了图标顶部，Finder 会露出一截。
        //
        // 和压平层的重叠是必须的——遮盖块左上角是圆的（半径 16），那段圆角
        // 只有在压平层覆盖上来之后才不露底色。压平层在层级和区域上都盖在它上面。
        let top = cg.minY + 1
        let bottom = cg.maxY - 1
        return CGRect(x: dockLeft,
                      y: flip - bottom,
                      width: cg.maxX - dockLeft,
                      height: bottom - top)
    }
}

// 两个圆角半径是不同的东西，别混：
//
// dockPanelCornerRadius —— 白板和顶部压平层用来画自己轮廓的半径。
//   实测 Dock 底板的左上圆角轮廓（相对窗口原点）：offset 2 → x=132、offset 4 → 128、
//   offset 8 → 123、offset 14 → 120、offset 24 → 118（直边），拟合半径约 16。
//   但白板/压平层都内缩了 1pt 以上，用 23 反而更贴合视觉效果（边缘不会露出直角的
//   硬折角）。这个值只影响"自己画出来的形状"，不影响采样结果。
let dockPanelCornerRadius: CGFloat = 23

/// Finder 遮盖块的圆角半径。遮盖块要精确卡在底板圆角上（它的边界是可见的），
/// 所以用实测拟合值。
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
/// 遮盖块顶端要和压平层的下沿接得上（压平层那里是 237,236,234），
/// 所以顶端用同一个值；底端对齐图标区下方的平坦值。
/// 两者不一致时，遮盖块和压平层的交界会出现一条能看出来的横向色阶
/// （实测遮盖块顶端用 234 时，交界比压平层暗 3 级，形成阶梯状接缝）。
let dockBaseTop = NSColor(srgbRed: 237.0 / 255, green: 236.0 / 255, blue: 234.0 / 255, alpha: 1)
let dockBaseBottom = NSColor(srgbRed: 236.0 / 255, green: 235.0 / 255, blue: 233.0 / 255, alpha: 1)

/// Dock 底色的视觉近似：和底板同色的圆角块。
final class FinderHiderView: NSView {
    override var isOpaque: Bool { false }

    /// 渐变只建一次。draw 会在每次几何变化时重跑，而这两个颜色是常量。
    private lazy var gradient = NSGradient(starting: dockBaseBottom, ending: dockBaseTop)

    /// 隐藏状态：把内容画成 1% 不透明。
    ///
    /// 隐藏不能碰**窗口**（alpha 不能降到 0、也不能搬出屏幕）：那样窗口服务器
    /// 会把它摘出合成，重新上屏要重建表面，实测要 150~200ms——正好是升起动画
    /// 的长度，这段时间里遮盖块整块不存在，Finder 图标完整露出来
    /// （洋红/绿色实验里漏帧的图案色计数都是 0，说明它压根没进合成）。
    ///
    /// 也不能靠"重新画一遍"来显示：重画要走「绘制 → 打包 IOSurface → 交给
    /// 窗口服务器」，实测 100ms 起。所以这里改的是**图层不透明度**，
    /// 属于合成阶段，当帧生效。
    ///
    /// 0.01 在视觉上等于没有：底色 237 上偏 2 级、白 250 上偏不到 1 级。
    var faded = false {
        didSet { layer?.opacity = faded ? 0.01 : 1 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 不透明内容一次性画进图层缓存，之后显隐只改 opacity，不重画。
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawBody(ctx)
    }

    private func drawBody(_ ctx: CGContext) {
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

        // 裁剪状态要自己收尾：addClip 改的是当前上下文的图形状态，
        // 虽然 AppKit 每轮 draw 都会重置，但成对写更安全（也避免嵌套 draw 时串味）。
        ctx.saveGState()
        defer { ctx.restoreGState() }
        NSBezierPath(cgPath: path).addClip()
        // NSGradient 的起点参数是「下」、终点是「上」。底板顶端更暗（内阴影）、底端更亮。
        gradient?.draw(in: bounds, angle: 90)
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
