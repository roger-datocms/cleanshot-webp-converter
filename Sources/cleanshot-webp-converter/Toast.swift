import AppKit
import CleanShotWebPCore

@MainActor private var currentToast: NSPanel?

/// Frames (Cocoa coordinates) of CleanShot's floating windows on `screen`: its Quick Access Overlay thumbnails.
/// Reading window bounds needs no Screen Recording permission. Full-screen capture layers and the
/// Annotate editor (normal window layer) are excluded.
@MainActor
func cleanShotOverlayFrames(on screen: NSScreen) -> [CGRect] {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    return windows.compactMap { window in
        guard (window[kCGWindowOwnerName as String] as? String)?.hasPrefix("CleanShot") == true,
              (window[kCGWindowLayer as String] as? Int ?? 0) > 0,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let quartzRect = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        let rect = cocoaRect(fromQuartz: quartzRect, primaryScreenHeight: primaryHeight)
        return screen.frame.contains(rect) && rect.width < screen.frame.width / 2 ? rect : nil
    }
}

/// Shows a small HUD card next to CleanShot's Quick Access Overlay (or in its slot when none is showing)
/// on the screen under the mouse, then fades it out. It never takes focus or intercepts clicks;
/// a new toast replaces the previous one.
@MainActor
func showToast(_ message: String, isLeftEdge: Bool, symbol: String = "photo.badge.checkmark", duration: TimeInterval = 3) {
    currentToast?.orderOut(nil)

    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor

    let label = NSTextField(wrappingLabelWithString: message)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.maximumNumberOfLines = 3
    label.preferredMaxLayoutWidth = 360

    let stack = NSStackView(views: [icon, label])
    stack.spacing = 12
    stack.alignment = .centerY
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 16)

    let background = NSVisualEffectView()
    background.material = .hudWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 6
    background.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        stack.topAnchor.constraint(equalTo: background.topAnchor),
        stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])

    let size = background.fittingSize
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
    let frame = toastFrame(
        size: size, visibleFrame: screen.visibleFrame, overlayFrames: cleanShotOverlayFrames(on: screen), isLeftEdge: isLeftEdge
    )

    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentView = background
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    currentToast = panel

    NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(duration))
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                if currentToast === panel { currentToast = nil }
            }
        }
    }
}
