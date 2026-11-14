import AppKit

// Chrome 的右键菜单是毛玻璃材质，会吸取背后的内容，深色网页上会透出黑色。
// 这里在菜单窗口正后方（层级更低）垫一块白色圆角板，菜单材质取样到白色，
// 看起来和 Dock 白底一样。只动我们自己的窗口，不注入、不改 Chrome。
//
// Chrome 菜单是 layer 101 的一对窗口：
//   阴影窗  bounds = 菜单 + 四周 75pt，CGWindowList 标记 onscreen=1
//   内容窗  bounds = 菜单本体，标记 onscreen=0，只能用 optionAll 查到
// 菜单关闭后两类窗口都从列表里消失，据此判断开关。
// 菜单是用户操作时短暂出现的，空闲时不跑定时器，CPU 为 0。

let CHROME_BUNDLE = "com.google.Chrome"
let BOARD_LEVEL = 3
let CORNER: CGFloat = 10
let MAX_BOARDS = 4

final class BoardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                     xRadius: CORNER, yRadius: CORNER).fill()
    }
}

final class Board: NSWindow {
    init() {
        super.init(contentRect: CGRect(x: 0, y: -20000, width: 10, height: 10),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: BOARD_LEVEL)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = BoardView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func park() {
        let f = CGRect(x: 0, y: -20000, width: 10, height: 10)
        if frame != f { setFrame(f, display: false) }
    }
}

struct MenuWin {
    let id: Int
    let rect: CGRect
}

final class Shade {
    private let boards = (0..<MAX_BOARDS).map { _ in Board() }
    private var timer: Timer?
    private var watching = false
    private var sawMenu = false
    private var armDeadline = Date()
    private var chromePID: pid_t = 0
    private var lastSig: [Int] = []
    private var ticks = 0

    init() {
        boards.forEach { $0.orderFrontRegardless() }
    }

    func arm() {
        if watching { return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == CHROME_BUNDLE && !$0.isTerminated
        }) else { return }
        chromePID = app.processIdentifier
        watching = true
        sawMenu = false
        ticks = 0
        lastSig = []
        armDeadline = Date().addingTimeInterval(1.5)
        timer?.invalidate()
        // 菜单刚弹出的前 0.4 秒每帧都查，之后降到 60Hz：关菜单到藏板最多 16ms，
        // 低于屏幕一帧，不会闪出白块。
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stop() {
        watching = false
        timer?.invalidate()
        timer = nil
        boards.forEach { $0.park() }
        lastSig = []
    }

    private func tick() {
        guard watching else { return }
        ticks += 1
        let fast = ticks < 48
        if !fast && ticks % 2 != 0 { return }

        let shadows = chromeWindows(onScreenOnly: true)
        if shadows.isEmpty {
            if sawMenu || Date() > armDeadline { stop() }
            return
        }
        let sig = shadows.map { $0.id }.sorted()
        if sig != lastSig {
            lastSig = sig
            let bodies = menuBodies()
            sawMenu = sawMenu || !bodies.isEmpty
            apply(bodies)
        }
    }

    private func apply(_ rects: [CGRect]) {
        let sorted = rects.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        for (i, r) in sorted.prefix(MAX_BOARDS).enumerated() {
            let f = nsFrame(r)
            if boards[i].frame != f {
                boards[i].setFrame(f, display: true)
                boards[i].orderFrontRegardless()
            }
        }
        for i in sorted.count..<MAX_BOARDS {
            boards[i].park()
        }
    }

    private func nsFrame(_ r: CGRect) -> CGRect {
        // CG 是左上原点，AppKit 是左下原点，换算后摆放位置不会上下颠倒。
        let h = NSScreen.screens[0].frame.height
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private func chromeWindows(onScreenOnly: Bool) -> [MenuWin] {
        let opts: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [MenuWin] = []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int, pid_t(pid) == chromePID,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 101,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let bx = (b["X"] as? NSNumber)?.doubleValue,
                  let by = (b["Y"] as? NSNumber)?.doubleValue,
                  let bw = (b["Width"] as? NSNumber)?.doubleValue,
                  let bh = (b["Height"] as? NSNumber)?.doubleValue,
                  let id = w[kCGWindowNumber as String] as? Int else { continue }
            let r = CGRect(x: bx, y: by, width: bw, height: bh)
            out.append(MenuWin(id: id, rect: r))
        }
        return out
    }

    // 菜单本体 = 被另一个窗口套住、且自己不再套别人的那个；外扩的阴影窗本身不被套，会被排除。
    // 只认成对出现的窗口，避免刚开机/刚弹出时只有阴影窗、误把大矩形垫白。
    private func menuBodies() -> [CGRect] {
        let all = chromeWindows(onScreenOnly: false)
        func contains(_ outer: MenuWin, _ inner: MenuWin) -> Bool {
            outer.id != inner.id &&
            outer.rect.minX <= inner.rect.minX - 8 &&
            outer.rect.maxX >= inner.rect.maxX + 8 &&
            outer.rect.minY <= inner.rect.minY - 8 &&
            outer.rect.maxY >= inner.rect.maxY + 8
        }
        let contained = all.filter { w in all.contains { contains($0, w) } }
        let bodies = contained.filter { w in !contained.contains { contains(w, $0) } }
        return bodies.map { $0.rect }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let shade = Shade()
NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { e in
    // 右键和 Control+左键都会弹上下文菜单
    if e.type == .leftMouseDown && !e.modifierFlags.contains(.control) { return }
    shade.arm()
}

app.run()
