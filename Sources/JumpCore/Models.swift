import Foundation

public enum JumpProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case cmj, sj
    public var id: String { rawValue }
    public var displayName: String { self == .cmj ? "Countermovement jump" : "Squat jump" }
}

public enum TimingProvenance: String, Codable, CaseIterable, Identifiable, Sendable {
    case captured, confirmedOriginal, unverified, retimed
    public var id: String { rawValue }
    public var allowsMeasurement: Bool { self == .captured || self == .confirmedOriginal }
    public var displayName: String {
        switch self {
        case .captured: "Captured in JumpForge"
        case .confirmedOriginal: "Original timing confirmed"
        case .unverified: "Timing unverified"
        case .retimed: "Retimed video"
        }
    }
}

public struct FrameStamp: Codable, Identifiable, Sendable, Equatable {
    public var id: Int
    public var value: Int64
    public var timescale: Int32
    public var seconds: Double { Double(value) / Double(timescale) }
    public init(index: Int, value: Int64, timescale: Int32) {
        self.id = index; self.value = value; self.timescale = timescale
    }
}

public struct JumpMeasurement: Codable, Sendable, Equatable {
    public var flightTimeSeconds: Double
    public var heightCentimeters: Double
    public var lowerHeightCentimeters: Double
    public var upperHeightCentimeters: Double
    public init(flightTimeSeconds: Double, heightCentimeters: Double, lowerHeightCentimeters: Double, upperHeightCentimeters: Double) {
        self.flightTimeSeconds = flightTimeSeconds
        self.heightCentimeters = heightCentimeters
        self.lowerHeightCentimeters = lowerHeightCentimeters
        self.upperHeightCentimeters = upperHeightCentimeters
    }
}

public struct Athlete: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

public struct AnalysisRevision: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var takeoffIndex: Int
    public var landingIndex: Int
    public var measurement: JumpMeasurement
    public var detector: String
    public var note: String
    public init(id: UUID = UUID(), createdAt: Date = Date(), takeoffIndex: Int, landingIndex: Int, measurement: JumpMeasurement, detector: String = "manual", note: String = "") {
        self.id = id; self.createdAt = createdAt
        self.takeoffIndex = takeoffIndex; self.landingIndex = landingIndex
        self.measurement = measurement; self.detector = detector; self.note = note
    }
}

public struct JumpAttempt: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var mediaFilename: String
    public var originalFilename: String
    public var frames: [FrameStamp]
    public var timing: TimingProvenance
    public var revisions: [AnalysisRevision]
    public init(id: UUID = UUID(), createdAt: Date = Date(), mediaFilename: String, originalFilename: String, frames: [FrameStamp], timing: TimingProvenance = .unverified, revisions: [AnalysisRevision] = []) {
        self.id = id; self.createdAt = createdAt
        self.mediaFilename = mediaFilename; self.originalFilename = originalFilename
        self.frames = frames; self.timing = timing; self.revisions = revisions
    }
}

public struct JumpSession: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var athleteID: UUID
    public var protocolType: JumpProtocol
    public var createdAt: Date
    public var attempts: [JumpAttempt]
    public var note: String
    public init(id: UUID = UUID(), athleteID: UUID, protocolType: JumpProtocol, createdAt: Date = Date(), attempts: [JumpAttempt] = [], note: String = "") {
        self.id = id; self.athleteID = athleteID; self.protocolType = protocolType
        self.createdAt = createdAt; self.attempts = attempts; self.note = note
    }
}

public struct JumpLibrary: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var athletes: [Athlete]
    public var sessions: [JumpSession]
    public init(schemaVersion: Int = 1, athletes: [Athlete] = [], sessions: [JumpSession] = []) {
        self.schemaVersion = schemaVersion; self.athletes = athletes; self.sessions = sessions
    }
}

public struct SessionSummary: Sendable {
    public let count: Int
    public let bestCentimeters: Double?
    public let medianCentimeters: Double?
    public let coefficientOfVariation: Double?
    public init(attempts: [JumpAttempt]) {
        let heights = attempts.compactMap { $0.revisions.last?.measurement.heightCentimeters }.sorted()
        count = heights.count
        bestCentimeters = heights.last
        guard !heights.isEmpty else {
            medianCentimeters = nil; coefficientOfVariation = nil; return
        }
        let middle = heights.count / 2
        medianCentimeters = heights.count.isMultiple(of: 2) ? (heights[middle - 1] + heights[middle]) / 2 : heights[middle]
        let mean = heights.reduce(0, +) / Double(heights.count)
        coefficientOfVariation = heights.count > 1 && mean > 0
            ? sqrt(heights.reduce(0) { $0 + pow($1 - mean, 2) } / Double(heights.count)) / mean
            : nil
    }
}
