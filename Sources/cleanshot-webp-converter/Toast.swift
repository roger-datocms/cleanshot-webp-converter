import AppKit

@MainActor private var currentToast: NSPanel?

/// Shows a small HUD at the top center of the screen under the mouse (clear of notification banners), then fades it out.
/// It never takes focus or intercepts clicks; a new toast replaces the previous one.
@MainActor
func showToast(_ message: String, symbol: String = "photo.badge.checkmark", duration: TimeInterval = 3) {
    currentToast?.orderOut(nil)

    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
    icon.contentTintColor = .secondaryLabelColor

    let label = NSTextField(labelWithString: message)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.lineBreakMode = .byTruncatingMiddle
    label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

    let stack = NSStackView(views: [icon, label])
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 14)

    let background = NSVisualEffectView()
    background.material = .hudWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        stack.topAnchor.constraint(equalTo: background.topAnchor),
        stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])

    let size = background.fittingSize
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    let margin: CGFloat = 12
    let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - margin, width: size.width, height: size.height)

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
