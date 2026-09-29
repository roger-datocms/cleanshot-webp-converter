import CoreGraphics
import Testing
@testable import CleanShotWebPCore

/// A 1710×1107 laptop screen with a 66 pt Dock and 34 pt menu bar.
let visibleFrame = CGRect(x: 0, y: 66, width: 1710, height: 1007)
let toastSize = CGSize(width: 320, height: 60)

@Suite struct ToastPlacementTests {
    @Test func takesBottomRightSlotWithoutOverlay() {
        let frame = toastFrame(size: toastSize, visibleFrame: visibleFrame, overlayFrames: [], isLeftEdge: false)
        #expect(frame == CGRect(x: 1710 - 320 - 16, y: 66 + 16, width: 320, height: 60))
    }

    @Test func takesBottomLeftSlotWithoutOverlay() {
        let frame = toastFrame(size: toastSize, visibleFrame: visibleFrame, overlayFrames: [], isLeftEdge: true)
        #expect(frame == CGRect(x: 16, y: 66 + 16, width: 320, height: 60))
    }

    @Test func stacksAboveTopmostOverlayOnItsEdge() {
        let overlays = [
            CGRect(x: 1450, y: 90, width: 240, height: 160),
            CGRect(x: 1450, y: 260, width: 240, height: 160),
        ]
        let frame = toastFrame(size: toastSize, visibleFrame: visibleFrame, overlayFrames: overlays, isLeftEdge: false)
        #expect(frame == CGRect(x: 1690 - 320, y: 420 + 8, width: 320, height: 60))
    }

    @Test func alignsWithLeftOverlay() {
        let overlays = [CGRect(x: 20, y: 90, width: 240, height: 160)]
        let frame = toastFrame(size: toastSize, visibleFrame: visibleFrame, overlayFrames: overlays, isLeftEdge: true)
        #expect(frame.origin == CGPoint(x: 20, y: 258))
    }

    @Test func ignoresOverlaysOnTheOtherEdge() {
        let overlays = [CGRect(x: 20, y: 90, width: 240, height: 160)]
        let frame = toastFrame(size: toastSize, visibleFrame: visibleFrame, overlayFrames: overlays, isLeftEdge: false)
        #expect(frame.origin == CGPoint(x: 1374, y: 82))
    }

    @Test func staysOnScreenWhenOverlaysFillTheEdge() {
        let overlays = [CGRect(x: 1450, y: 90, width: 240, height: 980)]
        let frame = toastFrame(size: toastSize, visibleFrame: visibleFrame, overlayFrames: overlays, isLeftEdge: false)
        #expect(frame.maxY == visibleFrame.maxY)
    }

    @Test func convertsQuartzToCocoaCoordinates() {
        let rect = cocoaRect(fromQuartz: CGRect(x: 100, y: 50, width: 200, height: 100), primaryScreenHeight: 1107)
        #expect(rect == CGRect(x: 100, y: 1107 - 150, width: 200, height: 100))
    }
}
