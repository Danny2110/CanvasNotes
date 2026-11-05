import AppKit
import Foundation

/// Codable document model for the freeform workspace. Coordinates are stored in
/// document points (before the scroll view's magnification is applied).
public struct NoteDocument: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var blocks: [NoteBlock]
    public var connections: [NoteConnection]

    public init(id: UUID = UUID(), title: String = "Untitled", blocks: [NoteBlock] = [], connections: [NoteConnection] = []) {
        self.id = id
        self.title = title
        self.blocks = blocks
        self.connections = connections
    }
}

public struct NoteBlock: Codable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var body: String
    public var position: CanvasPoint
    public var size: CanvasSize
    /// File URL is represented as a string so the schema remains portable.
    public var assetURL: URL?
    public var layerIndex: Int

    public init(id: UUID = UUID(), text: String = "", body: String = "", position: CanvasPoint, size: CanvasSize = .init(width: 280, height: 180), assetURL: URL? = nil, layerIndex: Int = 0) {
        self.id = id
        self.text = text
        self.body = body
        self.position = position
        self.size = size
        self.assetURL = assetURL
        self.layerIndex = layerIndex
    }

    private enum CodingKeys: String, CodingKey { case id, text, body, position, size, assetURL, layerIndex }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        position = try values.decode(CanvasPoint.self, forKey: .position)
        size = try values.decode(CanvasSize.self, forKey: .size)
        assetURL = try values.decodeIfPresent(URL.self, forKey: .assetURL)
        layerIndex = try values.decodeIfPresent(Int.self, forKey: .layerIndex) ?? 0
    }
}

public struct NoteConnection: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sourceID: UUID?
    public var destinationID: UUID?
    public var type: ConnectionType
    /// Free-floating arrow: stores its own start/end points when not attached to blocks
    public var startPoint: CanvasPoint?
    public var endPoint: CanvasPoint?

    public init(id: UUID = UUID(), sourceID: UUID?, destinationID: UUID?, type: ConnectionType,
                startPoint: CanvasPoint? = nil, endPoint: CanvasPoint? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.type = type
        self.startPoint = startPoint
        self.endPoint = endPoint
    }
}

public enum ConnectionType: String, Codable, Sendable { case simple, directional, freeArrow }

public struct CanvasPoint: Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public struct CanvasSize: Codable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}
