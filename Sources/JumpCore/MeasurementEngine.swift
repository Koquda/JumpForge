import Foundation

public enum JumpCoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidFrames(String)
    case invalidEvents
    case untrustedTiming
    case eventGapTooLarge
    case invalidLibrary(String)
    case invalidMediaFilename
    case unrecoverableLibrary
    public var errorDescription: String? {
        switch self {
        case .invalidFrames(let reason): "The video timestamps are invalid. \(reason)"
        case .invalidEvents: "Choose a first airborne frame after frame zero and a later first contact frame."
        case .untrustedTiming: "Confirm that this video preserves original capture timing before measuring. Retimed videos cannot be measured."
        case .eventGapTooLarge: "Frames are missing around a selected event. Choose a video with a gap no greater than 0.1 seconds at takeoff and landing."
        case .invalidLibrary(let reason): "The saved library is invalid. \(reason)"
        case .invalidMediaFilename: "The media filename must be a relative basename."
        case .unrecoverableLibrary: "The library and its prior snapshot cannot be read. The files have been preserved."
        }
    }
}

public enum MeasurementEngine {
    public static func measure(frames: [FrameStamp], takeoff: Int, landing: Int, timing: TimingProvenance) throws -> JumpMeasurement {
        guard timing.allowsMeasurement else { throw JumpCoreError.untrustedTiming }
        try validateFrames(frames)
        guard takeoff > 0, landing > takeoff, landing < frames.count else { throw JumpCoreError.invalidEvents }
        let takeoffBefore = frames[takeoff - 1]
        let takeoffAfter = frames[takeoff]
        let landingBefore = frames[landing - 1]
        let landingAfter = frames[landing]
        guard secondsBetween(takeoffAfter, takeoffBefore) <= 0.100_000_001,
              secondsBetween(landingAfter, landingBefore) <= 0.100_000_001 else { throw JumpCoreError.eventGapTooLarge }
        let flight = (secondsBetween(landingBefore, takeoffBefore) + secondsBetween(landingAfter, takeoffAfter)) / 2
        let lower = max(0, secondsBetween(landingBefore, takeoffAfter))
        let upper = secondsBetween(landingAfter, takeoffBefore)
        let height = heightCentimeters(flight)
        guard flight > 0, flight.isFinite, height.isFinite, heightCentimeters(upper).isFinite else {
            throw JumpCoreError.invalidEvents
        }
        return JumpMeasurement(flightTimeSeconds: flight, heightCentimeters: height,
                               lowerHeightCentimeters: heightCentimeters(lower), upperHeightCentimeters: heightCentimeters(upper))
    }

    static func validateFrames(_ frames: [FrameStamp]) throws {
        var previous: Decimal?
        for (position, frame) in frames.enumerated() {
            guard frame.id == position, frame.timescale > 0, frame.seconds.isFinite else {
                throw JumpCoreError.invalidFrames("Frame indices and timescales must be valid.")
            }
            if let previous, timestamp(frame) <= previous {
                throw JumpCoreError.invalidFrames("Timestamps must increase strictly.")
            }
            previous = timestamp(frame)
        }
    }

    private static func timestamp(_ frame: FrameStamp) -> Decimal {
        Decimal(frame.value) / Decimal(frame.timescale)
    }

    private static func secondsBetween(_ later: FrameStamp, _ earlier: FrameStamp) -> Double {
        NSDecimalNumber(decimal: timestamp(later) - timestamp(earlier)).doubleValue
    }

    private static func heightCentimeters(_ time: Double) -> Double { 9.80665 * time * time / 8 * 100 }
}
