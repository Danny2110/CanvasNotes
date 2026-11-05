import AppKit

/// Scroll view configured for an unbounded-feeling, magnifiable document canvas.
public final class WorkspaceScrollView: NSScrollView {
    public let canvasView: HapticCanvasView
    public var zoomScale: CGFloat { magnification }

    // Keep the layer-backed document below Core Animation's large-texture
    // tiling threshold. The previous 12k square produced visible tile seams.
    public init(frame frameRect: NSRect = .zero, canvasSize: NSSize = NSSize(width: 4_000, height: 4_000)) {
        canvasView = HapticCanvasView(frame: NSRect(origin: .zero, size: canvasSize))
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.25
        maxMagnification = 3.0
        documentView = canvasView
        setMagnification(1.0, centeredAt: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:canvasSize:)") }

    public func setZoomScale(_ scale: CGFloat, centeredAt point: NSPoint? = nil) {
        setMagnification(min(max(scale, minMagnification), maxMagnification), centeredAt: point ?? NSPoint(x: bounds.midX, y: bounds.midY))
    }
}

/// The stationery surface lives in document coordinates; AppKit magnification
/// scales its dots and all child views together.
public class PaperCanvasView: NSView {
    public static let gridSpacing: CGFloat = 20
    private static let dotDiameter: CGFloat = 1.5

    public override var isFlipped: Bool { true }

    /// Same endpoints as `AmbientBackdropView(tone: .paper)`; glass chrome needs
    /// a ramp behind it or its edges and blur read as flat gray.
    private var paperGradient: NSGradient? {
        let top: NSColor
        let bottom: NSColor
        if isDarkAppearance {
            top = NSColor(srgbRed: 0.125, green: 0.122, blue: 0.118, alpha: 1)
            bottom = NSColor(srgbRed: 0.086, green: 0.084, blue: 0.082, alpha: 1)
        } else {
            top = NSColor(srgbRed: 0.988, green: 0.980, blue: 0.965, alpha: 1)
            bottom = NSColor(srgbRed: 0.949, green: 0.933, blue: 0.902, alpha: 1)
        }
        return NSGradient(starting: top, ending: bottom)
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var dotColor: NSColor {
        isDarkAppearance
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
            : NSColor(srgbRed: 0.66, green: 0.62, blue: 0.57, alpha: 0.34)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: dirtyRect)

        // Draw the ramp into `bounds`, not `dirtyRect`: one continuous gradient
        // means no banding seams when scrolling or magnifying, while the clip
        // keeps rasterization cost proportional to the exposed strip.
        // The view is flipped, so +90 places the light start color at the visual
        // top — the mirror of `AmbientBackdropView`'s -90 in unflipped space.
        paperGradient?.draw(in: bounds, angle: 90)

        context.setFillColor(dotColor.cgColor)
        let spacing = Self.gridSpacing
        let startX = floor(dirtyRect.minX / spacing) * spacing
        let startY = floor(dirtyRect.minY / spacing) * spacing
        let diameter = Self.dotDiameter
        var y = startY
        while y <= dirtyRect.maxY {
            var x = startX
            while x <= dirtyRect.maxX {
                context.fillEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
                x += spacing
            }
            y += spacing
        }
        context.restoreGState()
    }
}
