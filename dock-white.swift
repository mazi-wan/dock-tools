// Dock 漂白：把整条 Dock 的底板推成纯白。
//
// 为什么不能靠垫白板：Dock 底板是「它背后的画面 × 0.93」的材质
//（实测白壁纸 253 → 236，蓝壁纸 233 → 218），在它下面垫多白都到不了 255。
// 唯一办法和菜单栏一样：截屏 → 把背景推成纯白 → 以更高层级贴回去。
//
// 和菜单栏的三处区别：
//   1. 采集「显示器的一块区域」而不是单个窗口。Dock 的窗口是整个屏幕
//      （实测 1600x900），单窗口采集每帧要 3200x1800，太贵；
//      sourceRect 只裁 Dock 那一条，3200x146。
//   2. 15fps（菜单栏 1fps 就够，Dock 要跟得上升降和悬停）。
//   3. 漂白判据是「接近中性灰且够亮」，不能只看亮度：Dock 图标里有大量
//      浅色像素，单纯亮度阈值会把图标洗成白块（实测 200 阈值下日历、
//      备忘、设置几乎消失）。

import AppKit
import CoreMedia
import ScreenCaptureKit

final class DockWhitener: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let window: NSWindow
    private let view = DockWhiteView(frame: .zero)

    private var stream: SCStream?
    private var starting = false
    private var restartPending = false
    private var suspended = false
    private var retry: Timer?

    /// 采集区域（CG 坐标，左上原点）。矩形变了（Dock 加减图标）才重建 stream。
    private var captureRect = CGRect.zero
    /// 上一次滚动出来的内容哈希：没变就不重新漂白、不重绘。
    private var lastRawHash = 0
    /// 位图按尺寸复用，避免每帧新分配 3200x146 的 context。
    private var canvas: CGContext?
    private var canvasSize = CGSize.zero
    private var pixelScale: CGFloat = 2
    private var expected = CGSize.zero
    private var hasImage = false

    private var shown = false
    private var lastNoteAt = Date.distantPast
    private let queue = DispatchQueue(label: "dock-tools.dock.whiten", qos: .userInitiated)

    /// 面板没开时的退路（自己低频跟踪 Dock 位置）。
    private var timer: Timer?

    private func note(_ text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastNoteAt) > 30 else { return }
        lastNoteAt = now
        FileHandle.standardError.write("\(now) \(text)\n".data(using: .utf8)!)
        fflush(stderr)
    }

    override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 4, height: 4),
                          styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        // Dock 的窗口在 layer 20，24 足够压住它（和 Finder 遮盖同层，
        // 但那个在 25，会盖在这层上面——Finder 那一格必须是白的）。
        window.level = NSWindow.Level(rawValue: 24)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        window.alphaValue = 0
        window.orderFrontRegardless()
    }

    deinit { timer?.invalidate(); retry?.invalidate() }

    /// 面板在跑时由它的跟踪循环驱动（和 Dock 白板同帧）。
    func start(drivenByPanel: Bool) {
        if drivenByPanel { return }
        refresh()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 每帧由 DockShade 调用：tube 是（可能正在动画中的）Dock 条矩形。
    func sync(tube: CGRect, flip: CGFloat, dockVisible: Bool) {
        guard dockVisible, tube.height > 20, tube.width > 100 else { hide(); return }

        // 和面板白板同样的外扩：左右各 2pt。
        // 底下多要 5pt：AX 给的 Dock 条是图标区（821…890），
        // 底板实际一直画到 895（实测 892…894 仍是 236 的底板色），
        // 少了这一段会在 Dock 最底下留一条 3pt 灰边。
        let w = tube.width + 4
        let h = tube.height + 7
        let frame = CGRect(x: tube.minX - 2, y: flip - tube.maxY - 5, width: w, height: h)
        if abs(window.frame.minX - frame.minX) > 0.5 || abs(window.frame.minY - frame.minY) > 0.5
            || abs(window.frame.width - frame.width) > 0.5 || abs(window.frame.height - frame.height) > 0.5 {
            window.setFrame(frame, display: false)
        }

        let cg = CGRect(x: frame.minX, y: flip - frame.maxY, width: w, height: h)
        if captureRect != cg {
            captureRect = cg
            restart()
        }

        if !shown {
            shown = true
            // 没有图时先别显示，否则会闪一下空白窗口
            window.alphaValue = hasImage ? 1 : 0
            window.orderFrontRegardless()
        }
    }

    /// 面板没开时的自驱路径。
    func refresh() {
        guard let flip = screenFlip(), let tube = dockTubeRect() else { hide(); return }
        guard tube.minY < flip - 20 else { hide(); return }
        sync(tube: tube, flip: flip, dockVisible: true)
    }

    private func hide() {
        guard shown || window.alphaValue != 0 else { return }
        shown = false
        if window.alphaValue != 0 { window.alphaValue = 0 }
    }

    private func screenFlip() -> CGFloat? {
        guard let main = NSScreen.screens.first else { return nil }
        return main.frame.origin.y + main.frame.height
    }

    // MARK: - 采集

    func suspend() {
        guard !suspended else { return }
        suspended = true
        let old = stream
        stream = nil
        lastRawHash = 0
        old?.stopCapture { _ in }
        print("\(Date()) Dock 漂白已暂停（屏幕/系统睡眠）")
        fflush(stdout)
    }

    func resume() {
        suspended = false
        start()
    }

    func restart() {
        lastRawHash = 0
        if suspended { return }
        if starting { restartPending = true; return }
        let old = stream
        stream = nil
        start()
        old?.stopCapture { _ in }
    }

    private func start() {
        guard stream == nil, !starting, !suspended, captureRect.width > 100 else { return }
        starting = true
        let rect = captureRect
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                guard let display = content.displays.first(where: { $0.frame.contains(center) })
                        ?? content.displays.first else {
                    throw NSError(domain: "dock-tools", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "找不到显示器"])
                }
                // 排除自己的窗口：白板、Finder 遮盖、菜单栏那几张都在里面，
                // 不排除就会把自己上一帧贴的白图当成 Dock 再采一遍（拖着残影）。
                let mine = DockWhitener.ourWindowIDs()
                let exclude = content.windows.filter { mine.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: exclude)
                let scale = CGFloat(filter.pointPixelScale)
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = rect
                cfg.width = Int(rect.width * scale)
                cfg.height = Int(rect.height * scale)
                // 15fps：Dock 的升降动画约 0.2 秒，1fps 会明显拖影；
                // 静止时 ScreenCaptureKit 不送帧，所以这个上限不产生常驻开销。
                let fps = Int(ProcessInfo.processInfo.environment["DOCK_WHITE_FPS"] ?? "") ?? 15
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
                cfg.queueDepth = 3
                cfg.showsCursor = false
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await s.startCapture()

                let w = cfg.width, h = cfg.height
                let adopted = await MainActor.run { () -> Bool in
                    self.starting = false
                    guard !self.suspended else { return false }
                    // 启动期间 Dock 位置变了：这张 stream 的 sourceRect 已经过时
                    guard self.captureRect == rect else { return false }
                    self.pixelScale = scale
                    self.expected = CGSize(width: w, height: h)
                    self.stream = s
                    self.lastRawHash = 0
                    return true
                }
                guard adopted else {
                    s.stopCapture { _ in }
                    DispatchQueue.main.async { self.restart() }
                    return
                }
                let pending = await MainActor.run { () -> Bool in
                    let p = self.restartPending
                    self.restartPending = false
                    return p
                }
                if pending { DispatchQueue.main.async { self.restart() } }
                print("\(Date()) Dock 漂白采集已启动 \(w)x\(h) @\(Int(rect.minX)),\(Int(rect.minY))")
                fflush(stdout)
            } catch {
                let reason = error.localizedDescription
                await MainActor.run {
                    self.starting = false
                    self.note("Dock 漂白需要屏幕录制权限(系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 dock-helper)：\(reason)")
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

    func stream(_ s: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard s === self.stream else { return }
            self.stream = nil
            guard !self.suspended else { return }
            self.note("Dock 漂白采集中断，5 秒后重试：\(error.localizedDescription)")
            self.scheduleRetry()
        }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !suspended, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CGFloat(w) == expected.width, CGFloat(h) == expected.height else {
            DispatchQueue.main.async { self.restart() }
            return
        }
        // 先用原始像素算个廉价哈希：屏幕上别处一动就会送帧，
        // 但 Dock 那一小条没变的话没必要重跑整幅漂白（3200x146 ≈ 46 万像素）。
        guard let raw = rawHash(pb), raw != lastRawHash else { return }
        guard let img = whiten(pb) else { return }
        lastRawHash = raw
        DispatchQueue.main.async {
            self.view.image = img
            self.view.needsDisplay = true
            self.hasImage = true
            if self.shown, self.window.alphaValue < 1 { self.window.alphaValue = 1 }
        }
    }

    private func rawHash(_ pb: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        var hash = 5381
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<w {
                hash = ((hash &* 33) ^ Int(truncatingIfNeeded: row[x])) & 0x7fffffff
            }
        }
        return hash
    }

    private func bitmapContext(_ w: Int, _ h: Int) -> CGContext? {
        let size = CGSize(width: w, height: h)
        if let c = canvas, canvasSize == size { return c }
        // ScreenCaptureKit 给的是 BGRA；用 byteOrder32Little + premultipliedFirst
        // 才是同一套字节序，否则红蓝会对调（Telegram 的蓝会变成橙色）。
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: info) else { return nil }
        canvas = c
        canvasSize = size
        return c
    }

    /// 「接近中性灰且够亮」→ 纯白。
    ///
    /// Dock 底板实测 (236,236,236)、白壁纸 (253,251,245)、白板 (255,255,255)
    /// 都满足；图标里的浅色部分大多带彩度或不够亮，会被留下。
    private static let whiteFloor = 228
    private static let whiteChroma = 8

    private func whiten(_ pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = bitmapContext(w, h), let dst = ctx.data else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        let out = dst.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            var si = y * stride
            var di = y * w * 4
            for _ in 0..<w {
                let b = Int(src[si]), g = Int(src[si + 1]), r = Int(src[si + 2])
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let lum = (299 * r + 587 * g + 114 * b) / 1000
                let white = lum >= DockWhitener.whiteFloor && mx - mn <= DockWhitener.whiteChroma
                out[di] = white ? 255 : src[si]
                out[di + 1] = white ? 255 : src[si + 1]
                out[di + 2] = white ? 255 : src[si + 2]
                out[di + 3] = 255
                si += 4
                di += 4
            }
        }
        return ctx.makeImage()
    }

    /// 本进程所有在屏窗口的 CGWindowID（用来从采集里排除自己）。
    private static func ourWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return ids }
        let me = Int(getpid())
        for d in list where (d[kCGWindowOwnerPID as String] as? Int) == me {
            if let n = d[kCGWindowNumber as String] as? CGWindowID { ids.insert(n) }
        }
        return ids
    }
}

/// 只负责把漂白后的图原样贴出来。图是 2x 位图、窗口也是 2x 逻辑尺寸，
/// 一一对应，不缩放（缩放会在图标边缘糊出一圈灰）。
final class DockWhiteView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(img, in: bounds)
    }
}
