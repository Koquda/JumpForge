import Foundation

public actor LibraryStore {
    public nonisolated let directory: URL
    public private(set) var recoveryNotice: String?
    private let manager = FileManager.default
    private var primaryURL: URL { directory.appendingPathComponent("library.json") }
    private var backupURL: URL { directory.appendingPathComponent("library.previous.json") }
    private var mediaDirectory: URL { directory.appendingPathComponent("media", isDirectory: true) }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> JumpLibrary {
        recoveryNotice = nil
        if manager.fileExists(atPath: primaryURL.path) {
            do { return try decode(Data(contentsOf: primaryURL)) }
            catch {
                guard let backupData = try? Data(contentsOf: backupURL),
                      let recovered = try? decode(backupData) else { throw JumpCoreError.unrecoverableLibrary }
                try preserveCorruptPrimary()
                recoveryNotice = "Recovered the prior valid snapshot. The unreadable library has been preserved. Recent changes may need to be repeated."
                return recovered
            }
        }
        if manager.fileExists(atPath: backupURL.path) {
            guard let recovered = try? decode(Data(contentsOf: backupURL)) else { throw JumpCoreError.unrecoverableLibrary }
            recoveryNotice = "Recovered the prior valid snapshot because the primary library is missing."
            return recovered
        }
        return JumpLibrary()
    }

    public func save(_ library: JumpLibrary) throws {
        try Self.validate(library)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: primaryURL.path) {
            let previous = try Data(contentsOf: primaryURL)
            if (try? decode(previous)) != nil {
                try previous.write(to: backupURL, options: .atomic)
            } else {
                guard let backup = try? Data(contentsOf: backupURL), (try? decode(backup)) != nil else {
                    throw JumpCoreError.unrecoverableLibrary
                }
                try preserveCorruptPrimary()
            }
        }
        if !manager.fileExists(atPath: primaryURL.path), manager.fileExists(atPath: backupURL.path) {
            guard let previous = try? Data(contentsOf: backupURL), (try? decode(previous)) != nil else {
                throw JumpCoreError.unrecoverableLibrary
            }
        }
        try data.write(to: primaryURL, options: .atomic)
    }

    public func importMedia(from source: URL) throws -> String {
        try manager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let sourceExtension = source.pathExtension.lowercased()
        let safeExtension = sourceExtension.count <= 12 && sourceExtension.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            ? sourceExtension : ""
        let filename = UUID().uuidString + (safeExtension.isEmpty ? "" : "." + safeExtension)
        let destination = try mediaURL(filename: filename)
        let temporary = mediaDirectory.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        let resolvedSource = source.resolvingSymlinksInPath()
        guard try resolvedSource.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw JumpCoreError.invalidLibrary("The selected media is not a regular file.")
        }
        try manager.copyItem(at: resolvedSource, to: temporary)
        try manager.moveItem(at: temporary, to: destination)
        return filename
    }

    public func mediaURL(filename: String) throws -> URL {
        try Self.validateFilename(filename)
        let candidate = mediaDirectory.appendingPathComponent(filename)
        let resolvedParent = mediaDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidateParent = candidate.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
        guard resolvedCandidateParent == resolvedParent else { throw JumpCoreError.invalidMediaFilename }
        return candidate
    }

    public func exportCSV(_ library: JumpLibrary) throws -> String {
        try Self.validate(library)
        let header = ["schema_version", "athlete_id", "athlete_name", "session_id", "protocol", "session_created_at", "session_note", "attempt_id", "attempt_created_at", "original_filename", "media_filename", "timing_provenance", "revision_id", "revision_created_at", "takeoff_first_airborne_index", "landing_first_contact_index", "takeoff_sample_seconds", "landing_sample_seconds", "takeoff_sample_value", "takeoff_sample_timescale", "landing_sample_value", "landing_sample_timescale", "flight_time_seconds", "height_cm", "lower_height_cm", "upper_height_cm", "detector", "revision_note", "gravity_m_per_s2", "method"]
        let names = Dictionary(uniqueKeysWithValues: library.athletes.map { ($0.id, $0.name) })
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rows = [header]
        for session in library.sessions {
            for attempt in session.attempts {
                let base = [String(library.schemaVersion), session.athleteID.uuidString, names[session.athleteID] ?? "", session.id.uuidString, session.protocolType.rawValue, dates.string(from: session.createdAt), session.note, attempt.id.uuidString, dates.string(from: attempt.createdAt), attempt.originalFilename, attempt.mediaFilename, attempt.timing.rawValue]
                if attempt.revisions.isEmpty {
                    rows.append(base + Array(repeating: "", count: header.count - base.count))
                } else {
                    for revision in attempt.revisions {
                        let measurement = revision.measurement
                        rows.append(base + [revision.id.uuidString, dates.string(from: revision.createdAt), String(revision.takeoffIndex), String(revision.landingIndex), String(attempt.frames[revision.takeoffIndex].seconds), String(attempt.frames[revision.landingIndex].seconds), String(attempt.frames[revision.takeoffIndex].value), String(attempt.frames[revision.takeoffIndex].timescale), String(attempt.frames[revision.landingIndex].value), String(attempt.frames[revision.landingIndex].timescale), String(measurement.flightTimeSeconds), String(measurement.heightCentimeters), String(measurement.lowerHeightCentimeters), String(measurement.upperHeightCentimeters), revision.detector, revision.note, "9.80665", "flight_time_midpoint_g_t_squared_over_8"])
                    }
                }
            }
        }
        return rows.map { $0.map(Self.csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private func decode(_ data: Data) throws -> JumpLibrary {
        let library = try JSONDecoder().decode(JumpLibrary.self, from: data)
        try Self.validate(library)
        return library
    }

    private func preserveCorruptPrimary() throws {
        let preserved = directory.appendingPathComponent("library.corrupt-" + UUID().uuidString + ".json")
        try manager.copyItem(at: primaryURL, to: preserved)
    }

    private static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
              !filename.contains("\\"), !filename.contains(":"), !filename.contains("\0"),
              filename.utf8.count <= 255 else { throw JumpCoreError.invalidMediaFilename }
    }

    static func validate(_ library: JumpLibrary) throws {
        guard library.schemaVersion == 1 else { throw JumpCoreError.invalidLibrary("Unsupported schema version.") }
        var identifiers = Set<UUID>()
        func check(_ id: UUID, _ date: Date) throws {
            guard identifiers.insert(id).inserted, date.timeIntervalSince1970.isFinite else {
                throw JumpCoreError.invalidLibrary("Duplicate identifiers or invalid dates.")
            }
        }
        let athleteIDs = Set(library.athletes.map(\.id))
        for athlete in library.athletes {
            try check(athlete.id, athlete.createdAt)
            guard !athlete.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw JumpCoreError.invalidLibrary("An athlete name is empty.")
            }
        }
        for session in library.sessions {
            try check(session.id, session.createdAt)
            guard athleteIDs.contains(session.athleteID) else { throw JumpCoreError.invalidLibrary("A session references an unknown athlete.") }
            for attempt in session.attempts {
                try check(attempt.id, attempt.createdAt)
                try validateFilename(attempt.mediaFilename)
                try MeasurementEngine.validateFrames(attempt.frames)
                for revision in attempt.revisions {
                    try check(revision.id, revision.createdAt)
                    let expected = try MeasurementEngine.measure(frames: attempt.frames, takeoff: revision.takeoffIndex, landing: revision.landingIndex, timing: attempt.timing)
                    let stored = revision.measurement
                    let pairs = [(expected.flightTimeSeconds, stored.flightTimeSeconds), (expected.heightCentimeters, stored.heightCentimeters), (expected.lowerHeightCentimeters, stored.lowerHeightCentimeters), (expected.upperHeightCentimeters, stored.upperHeightCentimeters)]
                    guard pairs.allSatisfy({ $0.1.isFinite && abs($0.0 - $0.1) <= max(1e-9, abs($0.0) * 1e-10) }) else {
                        throw JumpCoreError.invalidLibrary("A measurement does not match its recorded events.")
                    }
                }
            }
        }
    }

    private static func csvCell(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsafe = trimmed.first.map { "=+-@".contains($0) } ?? false
        let protected = unsafe || raw.first == "\t" || raw.first == "\r" || raw.first == "\n" ? "'" + raw : raw
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
