import Foundation

public struct InkColor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let hex: String
    public init(id: String, hex: String) { self.id = id; self.hex = hex }
    public static let palette: [InkColor] = [
        .init(id: "red", hex: "#FF0000"), .init(id: "orange", hex: "#FFA500"),
        .init(id: "yellow", hex: "#FFFF00"), .init(id: "green", hex: "#00FF00"),
        .init(id: "blue", hex: "#0000FF"), .init(id: "violet", hex: "#800080")
    ]
    public static let legacyPalette: [InkColor] = [
        .init(id: "red", hex: "#db4035"), .init(id: "orange", hex: "#e8782e"),
        .init(id: "yellow", hex: "#edb91f"), .init(id: "green", hex: "#3d9860"),
        .init(id: "blue", hex: "#2867ad"), .init(id: "violet", hex: "#775095")
    ]
    public static let researchLine = InkColor(id: "graphite", hex: "#24312b")
    public static let pigmentPalette: [InkColor] = [
        .init(id: "red", hex: "#e53166"), .init(id: "yellow", hex: "#fcd200"), .init(id: "blue", hex: "#3375da")
    ]
}

public struct BrushStyle: Codable, Equatable, Sendable {
    public var color: InkColor
    public var size: Double
    public var pigmentLoadID: UUID?
    public init(color: InkColor = InkColor.palette[4], size: Double = 28, pigmentLoadID: UUID? = nil) {
        self.color = color
        self.size = min(96, max(4, size))
        self.pigmentLoadID = pigmentLoadID
    }
    public static let sizeRange: ClosedRange<Double> = 4...96
    public static let presets: [Double] = [6, 24, 52, 96]
}

public enum InputKind: String, Codable, Sendable { case pencil, finger, indirect }
public enum SamplePhase: String, Codable, Sendable, Hashable { case began, moved, stationary, ended, cancelled }
public enum SampleSource: String, Codable, Sendable { case direct, coalesced, estimatedUpdate }
public enum StrokeEndReason: String, Codable, Sendable { case lifted, cancelled, backgrounded, layoutChanged, recovered, export, navigation }

public struct CanvasTransform: Codable, Equatable, Sendable {
    public let viewWidth: Double
    public let viewHeight: Double
    public let paperWidth: Double
    public let paperHeight: Double
    public init(viewWidth: Double, viewHeight: Double, paperWidth: Double, paperHeight: Double) {
        self.viewWidth = viewWidth; self.viewHeight = viewHeight
        self.paperWidth = paperWidth; self.paperHeight = paperHeight
    }
}

public struct TouchSample: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var uptime: Double
    public var receivedAt: Date
    public var x: Double
    public var y: Double
    public var viewX: Double
    public var viewY: Double
    public var force: Double?
    public var maximumPossibleForce: Double?
    public var altitude: Double?
    public var azimuth: Double?
    public var input: InputKind
    public var phase: SamplePhase
    public var source: SampleSource
    public var estimationIndex: Int64?
    public var estimatedProperties: UInt64
    public var propertiesExpectingUpdates: UInt64

    public init(id: UUID = UUID(), uptime: Double, receivedAt: Date = Date(), x: Double, y: Double,
                viewX: Double? = nil, viewY: Double? = nil, force: Double? = nil,
                maximumPossibleForce: Double? = nil, altitude: Double? = nil, azimuth: Double? = nil,
                input: InputKind = .pencil, phase: SamplePhase = .moved, source: SampleSource = .direct,
                estimationIndex: Int64? = nil, estimatedProperties: UInt64 = 0,
                propertiesExpectingUpdates: UInt64 = 0) {
        self.id = id; self.uptime = uptime; self.receivedAt = DrawingJSON.wallTime(receivedAt); self.x = x; self.y = y
        self.viewX = viewX ?? x; self.viewY = viewY ?? y; self.force = force
        self.maximumPossibleForce = maximumPossibleForce; self.altitude = altitude; self.azimuth = azimuth
        self.input = input; self.phase = phase; self.source = source; self.estimationIndex = estimationIndex
        self.estimatedProperties = estimatedProperties; self.propertiesExpectingUpdates = propertiesExpectingUpdates
    }

    public var normalizedForce: Double? {
        guard input == .pencil, let force, let maximumPossibleForce,
              force.isFinite, maximumPossibleForce.isFinite, maximumPossibleForce > 0, force >= 0 else { return nil }
        return force / maximumPossibleForce
    }
}

public enum PressureMapping {
    public static let version = "width-v1"
    public static let formula = "diameter = brushSize * (0.12 + 0.88 * pow(clamp((force / maximumPossibleForce) / 0.6, 0, 1), 0.85)); missing force uses display-only normalized force 0.35"
    public static func diameter(style: BrushStyle, normalizedForce: Double?) -> Double {
        let pressure = normalizedForce.flatMap { $0.isFinite ? $0 : nil } ?? 0.35
        return style.size * (0.12 + 0.88 * pow(min(1, max(0, pressure / 0.6)), 0.85))
    }
}

public struct DocumentMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let title: String
    public let paperWidth: Double
    public let paperHeight: Double
    public let deviceModel: String
    public let osVersion: String
    public let appVersion: String
    public let purpose: String
    public let schemaVersion: Int
    public let pressureMappingVersion: String
    public let context: DrawingContext?
    public let background: DrawingBackground?
    public let neutralRendering: Bool?
    public let colorPaletteVersion: String?

    public init(id: UUID = UUID(), createdAt: Date = Date(), title: String,
                paperWidth: Double = 1200, paperHeight: Double = 850,
                deviceModel: String = "unspecified", osVersion: String = "unspecified", appVersion: String = "0.1.0",
                context: DrawingContext? = nil, background: DrawingBackground? = nil, neutralRendering: Bool? = nil,
                colorPaletteVersion: String? = StandardPalette.version) {
        self.id = id; self.createdAt = DrawingJSON.wallTime(createdAt); self.title = title
        self.paperWidth = paperWidth; self.paperHeight = paperHeight
        self.deviceModel = deviceModel; self.osVersion = osVersion; self.appVersion = appVersion
        self.purpose = context.map { "native-research-" + $0.purpose.rawValue } ?? "native-prototype"
        self.schemaVersion = PaletteMixing.supports(background?.pigmentModel) ? 2 : 1
        self.pressureMappingVersion = background?.kind == "pigment" ? PigmentSurface.pressureVersion : PressureMapping.version
        self.context = context; self.background = background; self.neutralRendering = neutralRendering
        self.colorPaletteVersion = background?.kind == "pigment" && background?.pigmentModel != StandardPalette.mixingVersion ? nil : colorPaletteVersion
    }
}

public enum EventPayload: Codable, Equatable, Sendable {
    case strokeBegan(strokeID: UUID, style: BrushStyle, transform: CanvasTransform, samples: [TouchSample])
    case samplesAppended(strokeID: UUID, samples: [TouchSample])
    case samplesRevised(strokeID: UUID, samples: [TouchSample])
    case strokeEnded(strokeID: UUID, reason: StrokeEndReason)
    case undone(strokeID: UUID)
    case redone(strokeID: UUID)
    case brushChanged(style: BrushStyle)
    case fingerInputChanged(enabled: Bool)
}

public struct DrawingEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let documentID: UUID
    public let sequence: Int
    public let recordedAt: Date
    public let payload: EventPayload
    public init(id: UUID = UUID(), documentID: UUID, sequence: Int, recordedAt: Date = Date(), payload: EventPayload) {
        self.id = id; self.documentID = documentID; self.sequence = sequence
        self.recordedAt = DrawingJSON.wallTime(recordedAt); self.payload = payload
    }
}

public struct InkStroke: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let style: BrushStyle
    public let transform: CanvasTransform
    public var samples: [TouchSample]
    public var endReason: StrokeEndReason?
}

public enum DrawingError: Error, LocalizedError, Equatable {
    case invalidEvent(String)
    case persistence(String)
    public var errorDescription: String? {
        switch self {
        case .invalidEvent(let message): return "Invalid drawing event: \(message)"
        case .persistence(let message): return "Local storage: \(message)"
        }
    }
}

public enum DrawingJSON {
    public static func wallTime(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder
    }
}
