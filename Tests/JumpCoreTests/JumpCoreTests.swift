import Foundation
import Testing
@testable import JumpCore

struct JumpCoreTests {
    private func frames(_ times: [Int64], scale: Int32 = 1000) -> [FrameStamp] {
        times.enumerated().map { FrameStamp(index: $0.offset, value: $0.element, timescale: scale) }
    }

    private var regularFrames: [FrameStamp] { (0...90).map { FrameStamp(index: $0, value: Int64($0), timescale: 120) } }

    private func attempt(landing: Int = 61, name: String = "clip.mov") throws -> JumpAttempt {
        let measurement = try MeasurementEngine.measure(frames: regularFrames, takeoff: 1, landing: landing, timing: .confirmedOriginal)
        let revision = AnalysisRevision(takeoffIndex: 1, landingIndex: landing, measurement: measurement)
        return JumpAttempt(mediaFilename: "safe.mov", originalFilename: name, frames: regularFrames, timing: .confirmedOriginal, revisions: [revision])
    }

    private func library(name: String = "Athlete", attempts: [JumpAttempt]) -> JumpLibrary {
        let athlete = Athlete(name: name)
        return JumpLibrary(athletes: [athlete], sessions: [JumpSession(athleteID: athlete.id, protocolType: .cmj, attempts: attempts)])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JumpForgeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func halfSecondFlightAndBounds() throws {
        let result = try MeasurementEngine.measure(frames: regularFrames, takeoff: 1, landing: 61, timing: .captured)
        #expect(abs(result.flightTimeSeconds - 0.5) < 1e-12)
        #expect(abs(result.heightCentimeters - 30.64578125) < 1e-10)
        #expect(result.lowerHeightCentimeters < result.heightCentimeters)
        #expect(result.upperHeightCentimeters > result.heightCentimeters)
        #expect(abs(result.lowerHeightCentimeters - 29.63276792534722) < 1e-8)
    }

    @Test func largeTimestampOriginsPreserveSubframeIntervals() throws {
        let origin: Int64 = 9_000_000_000_000_000_000
        let stamps = (0...90).map { FrameStamp(index: $0, value: origin + Int64($0), timescale: 120) }
        let result = try MeasurementEngine.measure(frames: stamps, takeoff: 1, landing: 61, timing: .captured)
        #expect(abs(result.flightTimeSeconds - 0.5) < 1e-12)
        #expect(abs(result.heightCentimeters - 30.64578125) < 1e-10)
    }

    @Test func varyingPresentationTimesUseEventMidpoints() throws {
        let result = try MeasurementEngine.measure(frames: frames([0, 9, 22, 40, 72]), takeoff: 1, landing: 4, timing: .confirmedOriginal)
        #expect(abs(result.flightTimeSeconds - 0.0515) < 1e-12)
        #expect(abs(result.lowerHeightCentimeters - (9.80665 * 0.031 * 0.031 / 8 * 100)) < 1e-10)
        #expect(abs(result.upperHeightCentimeters - (9.80665 * 0.072 * 0.072 / 8 * 100)) < 1e-10)
    }

    @Test func rejectsInvalidEventsAndUntrustedTiming() {
        for timing in [TimingProvenance.retimed, .unverified] {
            #expect(throws: JumpCoreError.untrustedTiming) {
                try MeasurementEngine.measure(frames: regularFrames, takeoff: 1, landing: 61, timing: timing)
            }
        }
        for pair in [(0, 61), (61, 1), (2, 2), (1, 100), (-1, 2)] {
            #expect(throws: JumpCoreError.invalidEvents) {
                try MeasurementEngine.measure(frames: regularFrames, takeoff: pair.0, landing: pair.1, timing: .captured)
            }
        }
    }

    @Test func rejectsInvalidTimestampOrderingAndTimescale() {
        for invalid in [frames([0, 9, 9, 20]), frames([0, 9, 8, 20]), frames([0, 9, 12, 20], scale: 0), frames([0, 9, 12, 20], scale: -1)] {
            #expect(throws: (any Error).self) {
                try MeasurementEngine.measure(frames: invalid, takeoff: 1, landing: 3, timing: .captured)
            }
        }
        var wrongIndex = regularFrames
        wrongIndex[90].id = 400
        #expect(throws: (any Error).self) {
            try MeasurementEngine.measure(frames: wrongIndex, takeoff: 1, landing: 61, timing: .captured)
        }
    }

    @Test func acceptsThirtyFPSAndRejectsMissingEventFrames() throws {
        let lowRate = (0...30).map { FrameStamp(index: $0, value: Int64($0), timescale: 30) }
        let result = try MeasurementEngine.measure(frames: lowRate, takeoff: 1, landing: 16, timing: .captured)
        #expect(abs(result.flightTimeSeconds - 0.5) < 1e-12)
        #expect(result.upperHeightCentimeters - result.lowerHeightCentimeters > 8)
        #expect(throws: JumpCoreError.eventGapTooLarge) {
            try MeasurementEngine.measure(frames: frames([0, 101, 120, 140]), takeoff: 1, landing: 3, timing: .captured)
        }
        #expect(throws: JumpCoreError.eventGapTooLarge) {
            try MeasurementEngine.measure(frames: frames([0, 20, 40, 141]), takeoff: 1, landing: 3, timing: .captured)
        }
    }

    @Test func summaryUsesLatestRevisionPerAttempt() throws {
        var first = try attempt(landing: 31)
        first.revisions.append(try attempt(landing: 61).revisions[0])
        let second = try attempt(landing: 31)
        let unanalysed = JumpAttempt(mediaFilename: "pending.mov", originalFilename: "pending.mov", frames: [])
        let summary = SessionSummary(attempts: [first, second, unanalysed])
        #expect(summary.count == 2)
        #expect(abs((summary.bestCentimeters ?? 0) - 30.64578125) < 1e-10)
        #expect(abs((summary.medianCentimeters ?? 0) - 19.15361328125) < 1e-10)
        #expect(abs((summary.coefficientOfVariation ?? 0) - 0.6) < 1e-10)
        #expect(SessionSummary(attempts: []).medianCentimeters == nil)
        #expect(SessionSummary(attempts: [second]).coefficientOfVariation == nil)
    }

    @Test func persistenceRoundTripAndRecoveryPreservesCorruption() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        #expect(try await store.load() == JumpLibrary())
        let original = library(attempts: [try attempt()])
        try await store.save(original)
        #expect(try await LibraryStore(directory: directory).load() == original)
        var updated = original
        updated.athletes[0].name = "Updated"
        try await store.save(updated)
        let corrupted = Data("not json".utf8)
        try corrupted.write(to: directory.appendingPathComponent("library.json"))
        #expect(try await store.load() == original)
        #expect(await store.recoveryNotice != nil)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("library.corrupt-") }
        #expect(preserved.count == 1)
        #expect(try Data(contentsOf: preserved[0]) == corrupted)
        try await store.save(original)
        #expect(try await LibraryStore(directory: directory).load() == original)
    }

    @Test func unrecoverableLibraryNeverBecomesEmpty() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = Data("{broken".utf8)
        let primary = directory.appendingPathComponent("library.json")
        try corrupt.write(to: primary)
        let store = LibraryStore(directory: directory)
        await #expect(throws: JumpCoreError.unrecoverableLibrary) { try await store.load() }
        await #expect(throws: JumpCoreError.unrecoverableLibrary) { try await store.save(JumpLibrary()) }
        #expect(try Data(contentsOf: primary) == corrupt)
    }

    @Test func rejectsTamperedDecodedMeasurementsAndReferences() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var tampered = library(attempts: [try attempt()])
        tampered.sessions[0].attempts[0].revisions[0].measurement.heightCentimeters = 999
        try JSONEncoder().encode(tampered).write(to: directory.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: directory)
        await #expect(throws: JumpCoreError.unrecoverableLibrary) { try await store.load() }
        var badReference = library(attempts: [])
        badReference.sessions[0].athleteID = UUID()
        await #expect(throws: (any Error).self) { try await store.save(badReference) }
        var traversal = library(attempts: [try attempt()])
        traversal.sessions[0].attempts[0].mediaFilename = "../outside.mov"
        await #expect(throws: JumpCoreError.invalidMediaFilename) { try await store.save(traversal) }
        var duplicate = library(attempts: [])
        duplicate.athletes.append(duplicate.athletes[0])
        await #expect(throws: (any Error).self) { try await store.save(duplicate) }
    }

    @Test func mediaImportCopiesAndRejectsTraversal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.MOV")
        let content = Data([1, 2, 3, 4])
        try content.write(to: source)
        let store = LibraryStore(directory: directory.appendingPathComponent("library"))
        let first = try await store.importMedia(from: source)
        let second = try await store.importMedia(from: source)
        #expect(first != second)
        #expect(first.hasSuffix(".mov"))
        #expect(try Data(contentsOf: await store.mediaURL(filename: first)) == content)
        #expect(try Data(contentsOf: source) == content)
        for name in ["../escape", "/absolute", "x/y", "x\\y", ".", "", "foo:bar"] {
            await #expect(throws: JumpCoreError.invalidMediaFilename) { try await store.mediaURL(filename: name) }
        }
        let escape = directory.appendingPathComponent("library/media/link.mov")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: source)
        await #expect(throws: JumpCoreError.invalidMediaFilename) { try await store.mediaURL(filename: "link.mov") }
    }

    @Test func csvEscapesTextAndKeepsHistoryAndUnits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var jump = try attempt(name: "quoted,\"clip\"\n.mov")
        jump.revisions.append(try attempt(landing: 31).revisions[0])
        jump.revisions[1].note = "  =HYPERLINK(\"bad\")"
        let data = library(name: "=SUM(1,1)", attempts: [jump])
        let csv = try await LibraryStore(directory: directory).exportCSV(data)
        #expect(csv.contains("\"'=SUM(1,1)\""))
        #expect(csv.contains("\"'  =HYPERLINK(\"\"bad\"\")\""))
        #expect(csv.contains("\"quoted,\"\"clip\"\"\n.mov\""))
        #expect(csv.contains("\"height_cm\""))
        #expect(csv.contains("\"confirmedOriginal\""))
        #expect(csv.contains(jump.revisions[0].id.uuidString))
        #expect(csv.contains(jump.revisions[1].id.uuidString))
        #expect(csv.contains("\"9.80665\""))
        #expect(csv.hasSuffix("\r\n"))
    }
}
