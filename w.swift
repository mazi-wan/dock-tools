import AppKit
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in l where (w[kCGWindowOwnerName as String] as? String) == "dock-helper" {
    print("  layer=\(w[kCGWindowLayer as String] as? Int ?? 0) a=\(w[kCGWindowAlpha as String] as? Double ?? -1) \(w[kCGWindowBounds as String] as? [String: Any] ?? [:])")
}
