import AppKit
import QuartzCore

@MainActor
public protocol LiquidGlassBoxViewDelegate: AnyObject {
    func glassBox(_ box: LiquidGlassBoxView, didMoveTo origin: NSPoint, snapped: Bool)
    func glassBoxDidClickConnectionAnchor(_ box: LiquidGlassBoxView)
    func glassBoxDidRequestDeletion(_ box: LiquidGlassBoxView)
    func glassBox(_ box: LiquidGlassBoxView, moveToLayer index: Int)
    func glassBoxDidChangeContent(_ box: LiquidGlassBoxView)
}

/// A native Liquid Glass card with an optional clipped image and perimeter anchors.
public final class LiquidGlassBoxView: NSView {
    public static let cornerRadius: CGFloat = 20
    public weak var delegate: LiquidGlassBoxViewDelegate?
    public var gridSnappingEnabled = true
    public private(set) var assetURL: URL?
    public var noteBody = "" { didSet { if bodyView.string != noteBody { bodyView.string = noteBody } } }
    private let contentHost = FlippedContentView()
    private let glassSurface = GlassSurfaceView(frame: .zero)
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let bodyView = TopAlignedTextView()
    private let bodyScrollView = NSScrollView()
    private var dragOffset: NSPoint?
    private var resizeStart: (frame: NSRect, pointer: NSPoint)?
    private var lastSnappedOrigin: NSPoint?
    private let anchorLayer = CAShapeLayer()

    public var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue }
    }
    public override var acceptsFirstResponder: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0.75
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -7)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        applyDynamicColors()

        contentHost.frame = bounds
        contentHost.autoresizingMask = [.width, .height]
        glassSurface.style = .regular
        glassSurface.cornerRadius = Self.cornerRadius
        glassSurface.tintColor = Self.paperTint
        glassSurface.fallbackMaterial = .hudWindow
        glassSurface.frame = bounds
        glassSurface.autoresizingMask = [.width, .height]
        addSubview(glassSurface)
        glassSurface.contentView = contentHost

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.cornerRadius
        imageView.layer?.masksToBounds = true
        imageView.isHidden = true
        contentHost.addSubview(imageView)
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.usesSingleLineMode = false
        titleField.maximumNumberOfLines = 0
        titleField.lineBreakMode = .byWordWrapping
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.delegate = self
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = .labelColor
        contentHost.addSubview(titleField)
        bodyView.isRichText = false
        bodyView.font = .systemFont(ofSize: 13)
        bodyView.textColor = .labelColor
        bodyView.backgroundColor = .clear
        bodyView.drawsBackground = false
        bodyView.textContainerInset = NSSize(width: 0, height: 4)
        bodyView.isEditable = true
        bodyView.isSelectable = true
        bodyView.isVerticallyResizable = true
        bodyView.isHorizontallyResizable = false
        bodyView.minSize = NSSize(width: 0, height: 0)
        bodyView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bodyView.textContainer?.widthTracksTextView = true
        bodyView.textContainer?.heightTracksTextView = false
        bodyView.textContainer?.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        bodyView.delegate = self
        bodyScrollView.drawsBackground = false
        bodyScrollView.borderType = .noBorder
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.documentView = bodyView
        contentHost.addSubview(bodyScrollView)

        anchorLayer.fillColor = NSColor.white.withAlphaComponent(0.95).cgColor
        anchorLayer.shadowColor = NSColor.black.cgColor
        anchorLayer.shadowOpacity = 0.18
        anchorLayer.shadowRadius = 2
        layer?.addSublayer(anchorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    public override var wantsUpdateLayer: Bool { true }
    public override var isFlipped: Bool { true }
    public override func updateLayer() { anchorLayer.frame = bounds; updateAnchors() }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDynamicColors()
    }

    public override func layout() {
        super.layout()
        glassSurface.frame = bounds
        imageView.frame = bounds.insetBy(dx: 1, dy: 1)
        let inset: CGFloat = 14
        let titleHeight = min(54, max(30, bounds.height * 0.28))
        titleField.frame = NSRect(x: inset, y: 12,
                                  width: max(0, bounds.width - inset * 2),
                                  height: max(0, titleHeight))
        let bodyTop = titleField.frame.maxY + 4
        bodyScrollView.frame = NSRect(x: inset, y: bodyTop,
                                      width: max(0, bounds.width - inset * 2),
                                      height: max(0, bounds.height - bodyTop - 12))
        let textWidth = max(0, bodyScrollView.contentSize.width)
        let textHeight = max(0, bodyScrollView.contentSize.height)
        bodyView.textContainer?.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        bodyView.frame = NSRect(x: 0, y: 0, width: textWidth, height: textHeight)
        anchorLayer.frame = bounds
        updateAnchors()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
    }

    /// Warm paper tint, white haze in dark mode.
    private static let paperTint = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.06)
                      : NSColor(srgbRed: 0.98, green: 0.96, blue: 0.92, alpha: 0.16)
    }

    /// Specular rim that reads as a light-catching glass edge.
    private static let specularBorder = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.white.withAlphaComponent(isDark ? 0.14 : 0.55)
    }

    /// Contact shadow under the floating card.
    private static let cardShadow = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.18)
    }

    /// Layer colors are static CGColors, so resolve them against the live appearance.
    private func applyDynamicColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.borderColor = Self.specularBorder.cgColor
            layer?.shadowColor = Self.cardShadow.cgColor
            glassSurface.tintColor = Self.paperTint
        }
    }

    private func updateAnchors() {
        let points = [NSPoint(x: bounds.midX, y: bounds.minY), NSPoint(x: bounds.maxX, y: bounds.midY),
                      NSPoint(x: bounds.midX, y: bounds.maxY), NSPoint(x: bounds.minX, y: bounds.midY)]
        let path = CGMutablePath()
        points.forEach { path.addEllipse(in: CGRect(x: $0.x - 5, y: $0.y - 5, width: 10, height: 10)) }
        let grip = NSRect(x: bounds.maxX - 12, y: bounds.maxY - 12, width: 8, height: 8)
        path.addRoundedRect(in: grip, cornerWidth: 2, cornerHeight: 2)
        anchorLayer.path = path
    }

    public func displayImage(_ image: NSImage, sourceURL: URL? = nil) {
        imageView.image = image
        imageView.isHidden = false
        assetURL = sourceURL
        needsLayout = true
    }

    public override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let resizeGrip = NSRect(x: bounds.maxX - 18, y: bounds.maxY - 18, width: 18, height: 18)
        if resizeGrip.contains(localPoint), let parent = superview {
            resizeStart = (frame, parent.convert(event.locationInWindow, from: nil))
            dragOffset = nil
            return
        }
        let anchorRadius: CGFloat = 16
        let anchors = [NSPoint(x: bounds.midX, y: bounds.minY), NSPoint(x: bounds.maxX, y: bounds.midY),
                       NSPoint(x: bounds.midX, y: bounds.maxY), NSPoint(x: bounds.minX, y: bounds.midY)]
        if anchors.contains(where: { hypot(localPoint.x - $0.x, localPoint.y - $0.y) <= anchorRadius }) {
            delegate?.glassBoxDidClickConnectionAnchor(self)
            return
        }
        guard let parent = superview else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        dragOffset = NSPoint(x: point.x - frame.origin.x, y: point.y - frame.origin.y)
        lastSnappedOrigin = nil
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let parent = superview else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        if let resizeStart {
            frame = NSRect(x: resizeStart.frame.minX, y: resizeStart.frame.minY,
                           width: max(180, resizeStart.frame.width + point.x - resizeStart.pointer.x),
                           height: max(120, resizeStart.frame.height + point.y - resizeStart.pointer.y))
            delegate?.glassBox(self, didMoveTo: frame.origin, snapped: false)
            return
        }
        guard let dragOffset else { return }
        var origin = NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
        var snapped = false
        if gridSnappingEnabled {
            let grid = PaperCanvasView.gridSpacing
            let next = NSPoint(x: (origin.x / grid).rounded() * grid, y: (origin.y / grid).rounded() * grid)
            snapped = hypot(next.x - origin.x, next.y - origin.y) < grid * 0.22
            origin = next
            if snapped && next != lastSnappedOrigin {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                lastSnappedOrigin = next
            }
        }
        frame.origin = origin
        delegate?.glassBox(self, didMoveTo: origin, snapped: snapped)
    }

    public override func mouseUp(with event: NSEvent) { dragOffset = nil; resizeStart = nil }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let layerMenu = NSMenu(title: "Move to Layer")
        for index in 0..<10 {
            let layerItem = NSMenuItem(title: "Layer \(index + 1)", action: #selector(moveToLayer(_:)), keyEquivalent: "")
            layerItem.target = self
            layerItem.tag = index
            layerMenu.addItem(layerItem)
        }
        let moveItem = NSMenuItem(title: "Move to Layer", action: nil, keyEquivalent: "")
        menu.addItem(moveItem)
        menu.setSubmenu(layerMenu, for: moveItem)
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Delete Note", action: #selector(deleteNote), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteNote()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func deleteNote() { delegate?.glassBoxDidRequestDeletion(self) }
    @objc private func moveToLayer(_ sender: NSMenuItem) { delegate?.glassBox(self, moveToLayer: sender.tag) }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadImage(from: sender) ? .copy : []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (image, url) = readImage(from: sender) else { return false }
        displayImage(image, sourceURL: url)
        return true
    }

    private func canReadImage(from sender: NSDraggingInfo) -> Bool { readImage(from: sender) != nil }
    private func readImage(from sender: NSDraggingInfo) -> (NSImage, URL?)? {
        let pasteboard = sender.draggingPasteboard
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL,
           let image = NSImage(contentsOf: url) { return (image, url) }
        if let image = NSImage(pasteboard: pasteboard) { return (image, nil) }
        return nil
    }
}

/// Hosts the card's text and image in top-down coordinates so `y: 0` is the
/// top edge, matching the flipped card itself.
private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

/// `NSClipView` adopts its document view's flipped state, so forcing the text
/// view flipped keeps short bodies pinned directly under the title instead of
/// sinking to the bottom of the scroll view.
private final class TopAlignedTextView: NSTextView {
    override var isFlipped: Bool { true }
}

extension LiquidGlassBoxView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        noteBody = bodyView.string
        delegate?.glassBoxDidChangeContent(self)
    }
}

extension LiquidGlassBoxView: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) { delegate?.glassBoxDidChangeContent(self) }
}
