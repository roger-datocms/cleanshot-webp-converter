import CoreGraphics

/// Where to put a toast of `size` so it sits next to CleanShot's Quick Access Overlay.
///
/// All rects use Cocoa screen coordinates (origin bottom-left).
/// - Parameters:
///   - visibleFrame: The screen's visible frame (excludes menu bar and Dock).
///   - overlayFrames: Frames of CleanShot overlay thumbnails currently on that screen.
///   - isLeftEdge: Whether CleanShot shows its overlay on the left edge instead of the right.
/// - Returns: The toast's frame: stacked just above the topmost overlay on that edge, or in the
///   overlay's bottom-corner slot when no overlay is showing.
public func toastFrame(
    size: CGSize,
    visibleFrame: CGRect,
    overlayFrames: [CGRect],
    isLeftEdge: Bool,
    margin: CGFloat = 16,
    gap: CGFloat = 8
) -> CGRect {
    let edgeOverlays = overlayFrames.filter { isLeftEdge ? $0.midX < visibleFrame.midX : $0.midX >= visibleFrame.midX }
    guard let topmost = edgeOverlays.max(by: { $0.maxY < $1.maxY }) else {
        let x = isLeftEdge ? visibleFrame.minX + margin : visibleFrame.maxX - size.width - margin
        return CGRect(origin: CGPoint(x: x, y: visibleFrame.minY + margin), size: size)
    }
    let x = isLeftEdge ? topmost.minX : topmost.maxX - size.width
    let y = min(topmost.maxY + gap, visibleFrame.maxY - size.height)
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

/// Converts a Quartz window rect (origin top-left of the primary display) to Cocoa screen coordinates.
public func cocoaRect(fromQuartz rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
}
