import AppKit

/// Document canvas that owns cards and redraws all relationship tracks in one
/// retained CAShapeLayer. Paths are expressed in canvas coordinates.
public final class HapticCanvasView: PaperCanvasView, LiquidGlassBoxViewDelegate {
    public var connections: [NoteConnection] = [] { didSet { setNeedsConnectionRedraw() } }
    public var onConnectionCreated: ((NoteConnection) -> Void)?
    public var onCanvasChanged: (() -> Void)?
    public var cards: [(UUID, LiquidGlassBoxView)] { boxOrder.compactMap { id in boxes[id].map { (id, $0) } } }
    private var boxes: [UUID: LiquidGlassBoxView] = [:]
    private var boxOrder: [UUID] = []
    private var boxLayers: [UUID: Int] = [:]
    private var layerVisibility = Array(repeating: true, count: 10)
    public private(set) var activeLayerIndex = 0
    private var boxIDs: [ObjectIdentifier: UUID] = [:]
    private var connectionTypeForNewLinks: ConnectionType = .simple
    private var pendingSourceID: UUID?
    /// For free-floating arrow creation: stores the start point while dragging.
    private var pendingFreeArrowStart: CGPoint?
    private var pendingFreeArrowIndex: Int?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    public override func layout() {
        super.layout()
        needsDisplay = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Connection ink that stays legible on both paper ramps without turning
    /// into white noise in dark mode.
    private var connectionColor: NSColor {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45)
            : NSColor(srgbRed: 0.40, green: 0.35, blue: 0.29, alpha: 0.78)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: dirtyRect)
        context.setStrokeColor(connectionColor.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for connection in connections {
            var start: CGPoint
            var end: CGPoint
            if connection.type == .freeArrow,
               let s = connection.startPoint?.cgPoint,
               let e = connection.endPoint?.cgPoint {
                start = s
                end = e
            } else {
                guard let sourceID = connection.sourceID,
                      let destinationID = connection.destinationID,
                      let source = boxes[sourceID],
                      let destination = boxes[destinationID] else { continue }
                guard !source.isHidden, !destination.isHidden else { continue }
                start = boundaryPoint(of: source.frame, toward: destination.frame.midPoint)
                end = boundaryPoint(of: destination.frame, toward: source.frame.midPoint)
            }
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(hypot(dx, dy), 1)
            let direction = CGPoint(x: dx / length, y: dy / length)
            let perpendicular = CGPoint(x: -direction.y, y: direction.x)
            let offset = min(length * 0.32, 120)
            let path = CGMutablePath()
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + direction.x * offset, y: start.y + direction.y * offset),
                          control2: CGPoint(x: end.x - direction.x * offset, y: end.y - direction.y * offset))
            context.addPath(path)
            context.strokePath()
            if connection.type == .directional || connection.type == .freeArrow {
                let base = CGPoint(x: end.x - direction.x * 11, y: end.y - direction.y * 11)
                let arrow = CGMutablePath()
                arrow.move(to: CGPoint(x: base.x + perpendicular.x * 6, y: base.y + perpendicular.y * 6))
                arrow.addLine(to: end)
                arrow.addLine(to: CGPoint(x: base.x - perpendicular.x * 6, y: base.y - perpendicular.y * 6))
                context.addPath(arrow)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    // MARK: - Free Arrow Mouse Handling (Option+drag creates free arrows)

    public override func mouseDown(with event: NSEvent) {
        // Option+drag creates free-floating arrows
        if event.modifierFlags.contains(.option) {
            let point = convert(event.locationInWindow, from: nil)
            beginFreeArrow(at: point)
            return
        }
        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.option), let start = pendingFreeArrowStart, let index = pendingFreeArrowIndex, connections.indices.contains(index) {
            let currentPoint = convert(event.locationInWindow, from: nil)
            var conn = connections[index]
            conn.endPoint = CanvasPoint(x: currentPoint.x, y: currentPoint.y)
            connections[index] = conn
            needsDisplay = true
            return
        }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if pendingFreeArrowStart != nil {
            let point = convert(event.locationInWindow, from: nil)
            finishFreeArrow(at: point)
            return
        }
        super.mouseUp(with: event)
    }

    public func addBox(id: UUID = UUID(), frame: NSRect, title: String = "", layerIndex: Int? = nil) -> LiquidGlassBoxView {
        let box = LiquidGlassBoxView(frame: frame)
        box.title = title
        box.delegate = self
        boxes[id] = box
        let layer = min(max(layerIndex ?? activeLayerIndex, 0), 9)
        boxLayers[id] = layer
        box.isHidden = !layerVisibility[layer]
        boxOrder.removeAll { $0 == id }
        boxOrder.append(id)
        boxIDs[ObjectIdentifier(box)] = id
        addSubview(box)
        applyLayerOrdering()
        setNeedsConnectionRedraw()
        notifyCanvasChanged()
        return box
    }

    public func removeBox(id: UUID) {
        if let box = boxes.removeValue(forKey: id) {
            boxIDs.removeValue(forKey: ObjectIdentifier(box))
            boxLayers.removeValue(forKey: id)
            box.removeFromSuperview()
        }
        boxOrder.removeAll { $0 == id }
        connections.removeAll { $0.sourceID == id || $0.destinationID == id }
        setNeedsConnectionRedraw()
        notifyCanvasChanged()
    }

    /// Convenience action for a simple toolbar: links the two most recently added cards.
    @discardableResult
    public func connectMostRecentBoxes(type: ConnectionType = .directional) -> Bool {
        guard boxOrder.count >= 2 else { return false }
        connect(boxOrder[boxOrder.count - 2], to: boxOrder[boxOrder.count - 1], type: type)
        return true
    }

    /// Call after a user selects a source anchor and then a destination anchor.
    public func connect(_ sourceID: UUID, to destinationID: UUID, type: ConnectionType) {
        guard sourceID != destinationID, boxes[sourceID] != nil, boxes[destinationID] != nil else { return }
        let connection = NoteConnection(sourceID: sourceID, destinationID: destinationID, type: type)
        connections.append(connection)
        if type == .directional { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        onConnectionCreated?(connection)
        notifyCanvasChanged()
    }

    public func beginConnection(from sourceID: UUID, type: ConnectionType = .simple) {
        guard boxes[sourceID] != nil else { return }
        pendingSourceID = sourceID
        connectionTypeForNewLinks = type
    }

    public func finishConnection(at destinationID: UUID) {
        guard let sourceID = pendingSourceID else { return }
        connect(sourceID, to: destinationID, type: connectionTypeForNewLinks)
        pendingSourceID = nil
    }

    /// Begin creating a free-floating arrow at the given canvas point.
    public func beginFreeArrow(at startPoint: CGPoint) {
        pendingFreeArrowStart = startPoint
        let connection = NoteConnection(
            sourceID: nil,
            destinationID: nil,
            type: .freeArrow,
            startPoint: CanvasPoint(x: startPoint.x, y: startPoint.y),
            endPoint: CanvasPoint(x: startPoint.x, y: startPoint.y)
        )
        connections.append(connection)
        pendingFreeArrowIndex = connections.count - 1
        needsDisplay = true
    }

    /// Finish creating a free-floating arrow at the given canvas point.
    public func finishFreeArrow(at endPoint: CGPoint) {
        guard let start = pendingFreeArrowStart,
              let index = pendingFreeArrowIndex,
              connections.indices.contains(index) else { return }
        var connection = connections[index]
        connection.endPoint = CanvasPoint(x: endPoint.x, y: endPoint.y)
        connections[index] = connection
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        pendingFreeArrowStart = nil
        pendingFreeArrowIndex = nil
        notifyCanvasChanged()
    }

    /// Cancel free arrow creation.
    public func cancelFreeArrow() {
        if let index = pendingFreeArrowIndex, connections.indices.contains(index) {
            connections.remove(at: index)
        }
        pendingFreeArrowStart = nil
        pendingFreeArrowIndex = nil
        needsDisplay = true
    }

    public func glassBox(_ box: LiquidGlassBoxView, didMoveTo origin: NSPoint, snapped: Bool) {
        setNeedsConnectionRedraw()
        notifyCanvasChanged()
    }

    public func glassBoxDidClickConnectionAnchor(_ box: LiquidGlassBoxView) {
        guard let id = boxIDs[ObjectIdentifier(box)] else { return }
        if pendingSourceID == nil {
            beginConnection(from: id, type: .directional)
        } else {
            finishConnection(at: id)
        }
    }

    public func glassBoxDidRequestDeletion(_ box: LiquidGlassBoxView) {
        guard let id = boxIDs.removeValue(forKey: ObjectIdentifier(box)) else { return }
        removeBox(id: id)
    }

    public func glassBoxDidChangeContent(_ box: LiquidGlassBoxView) { notifyCanvasChanged() }

    public func glassBox(_ box: LiquidGlassBoxView, moveToLayer index: Int) {
        guard let id = boxIDs[ObjectIdentifier(box)], (0..<10).contains(index) else { return }
        boxLayers[id] = index
        box.isHidden = !layerVisibility[index]
        applyLayerOrdering()
        needsDisplay = true
    }

    // Hit-test a free-floating arrow: returns index in connections array if hit.
    private func hitTestFreeArrow(at point: CGPoint, tolerance: CGFloat = 8) -> Int? {
        for (index, connection) in connections.enumerated() {
            guard connection.type == .freeArrow,
                  let start = connection.startPoint?.cgPoint,
                  let end = connection.endPoint?.cgPoint else { continue }
            // Distance from point to line segment
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSq = dx*dx + dy*dy
            guard lengthSq > 0 else { continue }
            let t = max(0, min(1, ((point.x - start.x)*dx + (point.y - start.y)*dy) / lengthSq))
            let closest = CGPoint(x: start.x + t*dx, y: start.y + t*dy)
            let dist = hypot(point.x - closest.x, point.y - closest.y)
            if dist <= tolerance { return index }
        }
        return nil
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)

        // Check if right-clicked on a free arrow
        if let arrowIndex = hitTestFreeArrow(at: point) {
            let menu = NSMenu()
            let deleteItem = NSMenuItem(title: "Delete Arrow", action: #selector(deleteFreeArrow(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.tag = arrowIndex
            menu.addItem(deleteItem)
            return menu
        }

        let menu = NSMenu(title: "Canvas Layers")
        let layers = NSMenu(title: "Create Notes On")
        for index in 0..<10 {
            let item = NSMenuItem(title: "Layer \(index + 1)", action: #selector(selectLayer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == activeLayerIndex ? .on : .off
            layers.addItem(item)
        }
        let parent = NSMenuItem(title: "Create Notes On", action: nil, keyEquivalent: "")
        menu.addItem(parent)
        menu.setSubmenu(layers, for: parent)

        let visibilityMenu = NSMenu(title: "Visible Layers")
        for index in 0..<10 {
            let item = NSMenuItem(title: "Layer \(index + 1)", action: #selector(toggleLayerVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = layerVisibility[index] ? .on : .off
            visibilityMenu.addItem(item)
        }
        let visibilityParent = NSMenuItem(title: "Visible Layers", action: nil, keyEquivalent: "")
        menu.addItem(visibilityParent)
        menu.setSubmenu(visibilityMenu, for: visibilityParent)
        return menu
    }

    @objc private func deleteFreeArrow(_ sender: NSMenuItem) {
        let index = sender.tag
        guard connections.indices.contains(index), connections[index].type == .freeArrow else { return }
        connections.remove(at: index)
        notifyCanvasChanged()
    }

    @objc private func selectLayer(_ sender: NSMenuItem) {
        guard (0..<10).contains(sender.tag) else { return }
        activeLayerIndex = sender.tag
        if !layerVisibility[sender.tag] { setLayerVisible(true, index: sender.tag) }
    }

    @objc private func toggleLayerVisibility(_ sender: NSMenuItem) {
        guard (0..<10).contains(sender.tag) else { return }
        setLayerVisible(!layerVisibility[sender.tag], index: sender.tag)
    }

    private func setLayerVisible(_ isVisible: Bool, index: Int) {
        layerVisibility[index] = isVisible
        for (id, box) in boxes where boxLayers[id] == index {
            box.isHidden = !isVisible
        }
        needsDisplay = true
    }

    /// Reinsert cards from lowest to highest so a larger layer number is
    /// visually and interactively above every lower layer.
    private func applyLayerOrdering() {
        let ordered = boxOrder.enumerated().compactMap { offset, id -> (Int, Int, LiquidGlassBoxView)? in
            guard let box = boxes[id] else { return nil }
            return (boxLayers[id, default: 0], offset, box)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        for (_, _, box) in ordered {
            addSubview(box, positioned: .above, relativeTo: nil)
        }
    }

    private func setNeedsConnectionRedraw() {
        needsDisplay = true
    }

    private func notifyCanvasChanged() { onCanvasChanged?() }

    public func exportBlocks() -> [NoteBlock] {
        cards.map { id, box in
            NoteBlock(id: id, text: box.title, body: box.noteBody, position: CanvasPoint(x: box.frame.minX, y: box.frame.minY),
                      size: CanvasSize(width: box.frame.width, height: box.frame.height), assetURL: box.assetURL, layerIndex: boxLayers[id, default: 0])
        }
    }

    public func restore(blocks: [NoteBlock], connections savedConnections: [NoteConnection]) {
        let priorCallback = onCanvasChanged
        onCanvasChanged = nil
        for id in boxOrder { removeBox(id: id) }
        for block in blocks {
            let box = addBox(id: block.id,
                             frame: NSRect(x: block.position.x, y: block.position.y, width: block.size.width, height: block.size.height),
                             title: block.text, layerIndex: block.layerIndex)
            box.noteBody = block.body
            if let url = block.assetURL, let image = NSImage(contentsOf: url) { box.displayImage(image, sourceURL: url) }
        }
        connections = savedConnections
        onCanvasChanged = priorCallback
        setNeedsConnectionRedraw()
    }

    /// Ray/axis-aligned-rectangle intersection from center toward target.
    private func boundaryPoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = rect.midPoint
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let tx = dx == 0 ? .infinity : (rect.width / 2) / abs(dx)
        let ty = dy == 0 ? .infinity : (rect.height / 2) / abs(dy)
        let scale = min(tx, ty)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}

private extension CGRect {
    var midPoint: CGPoint { CGPoint(x: midX, y: midY) }
}
