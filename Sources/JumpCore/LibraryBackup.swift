import Foundation

public enum LibraryBackupError: Error, LocalizedError, Sendable, Equatable {
    case invalidPackage(String)
    case destinationExists
    case conflictingRecord(String)
    case conflictingMedia(String)
    case limitsExceeded
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPackage(let reason): "The backup cannot be used. \(reason)"
        case .destinationExists: "A file or folder already exists at the backup destination. Choose a new name."
        case .conflictingRecord(let identifier): "The backup contains a changed record with an existing identifier (\(identifier)). Existing records have been preserved."
        case .conflictingMedia(let filename): "The backup media named \(filename) differs from the existing file. Existing media has been preserved."
        case .limitsExceeded: "The backup exceeds the limit of 10,000 files, 50 MB per metadata file, or 4 GB total."
        case .rollbackFailed: "Restore failed and could not fully restore its metadata snapshot. The previous library snapshot has been preserved for recovery."
        }
    }
}

private struct BackupFile: Codable, Equatable {
    var byteCount: Int64
    var checksumFNV1a: String
}

private struct BackupManifest: Codable {
    var formatVersion: Int
    var library: BackupFile
    var media: [String: BackupFile]
}

extension LibraryStore {
    public func writeBackup(to destination: URL) throws -> URL {
        let manager = FileManager.default
        guard !Self.backupEntryExists(destination) else { throw LibraryBackupError.destinationExists }
        let library = try load()
        try Self.validate(library)
        let metadata = try Self.backupLibraryData(library)
        let names = Self.backupMediaNames(library)
        guard names.count + 2 <= 10_000 else { throw LibraryBackupError.limitsExceeded }
        let destinationParent = destination.deletingLastPathComponent()
        try Self.requireBackupDirectory(destinationParent)
        let sourceRoot = directory.appendingPathComponent("media", isDirectory: true)
        if !names.isEmpty { try Self.requireBackupDirectory(sourceRoot) }
        let stage = destinationParent.appendingPathComponent(".jumpforge-backup-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        let stagedMedia = stage.appendingPathComponent("media", isDirectory: true)
        try manager.createDirectory(at: stagedMedia, withIntermediateDirectories: false)
        let stagedLibrary = stage.appendingPathComponent("library.json")
        try metadata.write(to: stagedLibrary, options: .atomic)
        var manifest = BackupManifest(formatVersion: 1, library: try Self.inspectBackupFile(stagedLibrary), media: [:])
        var total = Int64(metadata.count)
        for name in names.sorted() {
            let source = try mediaURL(filename: name)
            let expected = try Self.inspectBackupFile(source)
            try Self.addBackupBytes(expected.byteCount, to: &total)
            let copied = stagedMedia.appendingPathComponent(name)
            try manager.copyItem(at: source, to: copied)
            guard try Self.inspectBackupFile(copied) == expected else {
                throw LibraryBackupError.invalidPackage("A media file changed while the backup was being copied.")
            }
            manifest.media[name] = expected
        }
        let manifestData = try JSONEncoder().encode(manifest)
        guard manifestData.count < Self.backupMetadataLimit else { throw LibraryBackupError.limitsExceeded }
        try Self.addBackupBytes(Int64(manifestData.count), to: &total)
        try manifestData.write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try Self.readBackupPackage(stage)
        guard !Self.backupEntryExists(destination) else { throw LibraryBackupError.destinationExists }
        try manager.moveItem(at: stage, to: destination)
        return destination
    }

    public func restoreBackup(from source: URL) throws -> JumpLibrary {
        let manager = FileManager.default
        let package = try Self.readBackupPackage(source)
        let incoming = package.library
        let current = try load()
        try Self.validate(current)
        var merged = current
        for athlete in incoming.athletes {
            if let existing = merged.athletes.first(where: { $0.id == athlete.id }) {
                guard existing == athlete else { throw LibraryBackupError.conflictingRecord(athlete.id.uuidString) }
            } else {
                merged.athletes.append(athlete)
            }
        }
        for session in incoming.sessions {
            if let existing = merged.sessions.first(where: { $0.id == session.id }) {
                guard existing == session else { throw LibraryBackupError.conflictingRecord(session.id.uuidString) }
            } else {
                merged.sessions.append(session)
            }
        }
        try Self.validate(merged)
        let mergedData = try Self.backupLibraryData(merged)
        let incomingNames = Self.backupMediaNames(incoming)
        let allNames = Self.backupMediaNames(merged)
        guard allNames.count + 2 <= 10_000 else { throw LibraryBackupError.limitsExceeded }
        let mediaRoot = directory.appendingPathComponent("media", isDirectory: true)
        if Self.backupEntryExists(mediaRoot) { try Self.requireBackupDirectory(mediaRoot) }
        var copies: [(source: URL, destination: URL)] = []
        var total = Int64(mergedData.count)
        for name in allNames.sorted() {
            let destination = try mediaURL(filename: name)
            let incomingFile = source.appendingPathComponent("media", isDirectory: true).appendingPathComponent(name)
            if Self.backupEntryExists(destination) {
                let existing = try Self.inspectBackupFile(destination)
                try Self.addBackupBytes(existing.byteCount, to: &total)
                if incomingNames.contains(name) {
                    let backup = try Self.inspectBackupFile(incomingFile)
                    guard package.media[name] == backup else {
                        throw LibraryBackupError.invalidPackage("A backup media file changed after validation.")
                    }
                    guard existing == backup, manager.contentsEqual(atPath: destination.path, andPath: incomingFile.path) else {
                        throw LibraryBackupError.conflictingMedia(name)
                    }
                }
            } else {
                guard incomingNames.contains(name) else {
                    throw LibraryBackupError.invalidPackage("Existing library media is missing: \(name).")
                }
                let backup = try Self.inspectBackupFile(incomingFile)
                guard package.media[name] == backup else {
                    throw LibraryBackupError.invalidPackage("A backup media file changed after validation.")
                }
                try Self.addBackupBytes(backup.byteCount, to: &total)
                copies.append((incomingFile, destination))
            }
        }
        if merged == current, copies.isEmpty { return current }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stage = directory.appendingPathComponent(".jumpforge-restore-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        for copy in copies {
            let staged = stage.appendingPathComponent(copy.destination.lastPathComponent)
            guard let expected = package.media[copy.destination.lastPathComponent] else {
                throw LibraryBackupError.invalidPackage("A media manifest entry is missing.")
            }
            try manager.copyItem(at: copy.source, to: staged)
            guard try Self.inspectBackupFile(staged) == expected else {
                throw LibraryBackupError.invalidPackage("A media file changed while restore was being staged.")
            }
        }
        let primary = directory.appendingPathComponent("library.json")
        let previous = directory.appendingPathComponent("library.previous.json")
        let oldPrimary = try Self.backupMetadataSnapshot(primary)
        let oldPrevious = try Self.backupMetadataSnapshot(previous)
        var installed: [URL] = []
        do {
            try manager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
            for copy in copies {
                guard !Self.backupEntryExists(copy.destination) else {
                    throw LibraryBackupError.conflictingMedia(copy.destination.lastPathComponent)
                }
                try manager.moveItem(at: stage.appendingPathComponent(copy.destination.lastPathComponent), to: copy.destination)
                installed.append(copy.destination)
            }
            try save(merged)
        } catch {
            for url in installed { try? manager.removeItem(at: url) }
            do {
                try Self.restoreBackupMetadata(oldPrimary, at: primary)
                try Self.restoreBackupMetadata(oldPrevious, at: previous)
            } catch { throw LibraryBackupError.rollbackFailed }
            throw error
        }
        return merged
    }

    private static var backupMetadataLimit: Int { 50_000_000 }
    private static var backupTotalLimit: Int64 { 4_000_000_000 }

    private static func backupMediaNames(_ library: JumpLibrary) -> Set<String> {
        Set(library.sessions.flatMap(\.attempts).map(\.mediaFilename))
    }

    private static func backupLibraryData(_ library: JumpLibrary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        guard data.count < backupMetadataLimit else { throw LibraryBackupError.limitsExceeded }
        return data
    }

    private static func backupEntryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func requireBackupDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw LibraryBackupError.invalidPackage("A folder is missing or is a symbolic link.")
        }
    }

    private static func inspectBackupFile(_ url: URL, metadata: Bool = false) throws -> BackupFile {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw LibraryBackupError.invalidPackage("A file is missing, is not a regular file, or is a symbolic link.")
        }
        guard Int64(size) < backupTotalLimit, !metadata || size < backupMetadataLimit else {
            throw LibraryBackupError.limitsExceeded
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var checksum: UInt64 = 14_695_981_039_346_656_037
        var counted: Int64 = 0
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try addBackupBytes(Int64(data.count), to: &counted)
            updateBackupChecksum(&checksum, with: data)
        }
        guard counted == Int64(size) else { throw LibraryBackupError.invalidPackage("A file changed during validation.") }
        return BackupFile(byteCount: counted, checksumFNV1a: String(checksum, radix: 16))
    }

    private static func updateBackupChecksum(_ checksum: inout UInt64, with data: Data) {
        for byte in data { checksum = (checksum ^ UInt64(byte)) &* 1_099_511_628_211 }
    }

    private static func readBackupMetadata(_ url: URL, matching expected: BackupFile) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        var checksum: UInt64 = 14_695_981_039_346_656_037
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count < backupMetadataLimit else { throw LibraryBackupError.limitsExceeded }
            data.append(chunk)
            updateBackupChecksum(&checksum, with: chunk)
        }
        guard BackupFile(byteCount: Int64(data.count), checksumFNV1a: String(checksum, radix: 16)) == expected else {
            throw LibraryBackupError.invalidPackage("A metadata file changed after validation.")
        }
        return data
    }

    private static func addBackupBytes(_ bytes: Int64, to total: inout Int64) throws {
        guard bytes >= 0, bytes < backupTotalLimit - total else { throw LibraryBackupError.limitsExceeded }
        total += bytes
    }

    private static func readBackupPackage(_ source: URL) throws -> (library: JumpLibrary, media: [String: BackupFile]) {
        try requireBackupDirectory(source)
        let manager = FileManager.default
        let rootEntries = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        guard Set(rootEntries.map(\.lastPathComponent)) == Set(["library.json", "manifest.json", "media"]) else {
            throw LibraryBackupError.invalidPackage("The package must contain library.json, manifest.json, and media only.")
        }
        let libraryURL = source.appendingPathComponent("library.json")
        let manifestURL = source.appendingPathComponent("manifest.json")
        let libraryInfo = try inspectBackupFile(libraryURL, metadata: true)
        let manifestInfo = try inspectBackupFile(manifestURL, metadata: true)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: readBackupMetadata(manifestURL, matching: manifestInfo))
        guard manifest.formatVersion == 1, manifest.library == libraryInfo else {
            throw LibraryBackupError.invalidPackage("The metadata checksum or backup version does not match.")
        }
        let library = try JSONDecoder().decode(JumpLibrary.self, from: readBackupMetadata(libraryURL, matching: libraryInfo))
        try validate(library)
        let mediaRoot = source.appendingPathComponent("media", isDirectory: true)
        try requireBackupDirectory(mediaRoot)
        let names = backupMediaNames(library)
        let entries = try manager.contentsOfDirectory(at: mediaRoot, includingPropertiesForKeys: nil)
        guard entries.count + 2 <= 10_000 else { throw LibraryBackupError.limitsExceeded }
        guard Set(entries.map(\.lastPathComponent)) == names, Set(manifest.media.keys) == names else {
            throw LibraryBackupError.invalidPackage("Media files are missing or unrecognized.")
        }
        var total = libraryInfo.byteCount
        try addBackupBytes(manifestInfo.byteCount, to: &total)
        for entry in entries {
            let actual = try inspectBackupFile(entry)
            try addBackupBytes(actual.byteCount, to: &total)
            guard manifest.media[entry.lastPathComponent] == actual else {
                throw LibraryBackupError.invalidPackage("A media checksum does not match: \(entry.lastPathComponent).")
            }
        }
        return (library, manifest.media)
    }

    private static func backupMetadataSnapshot(_ url: URL) throws -> Data? {
        guard backupEntryExists(url) else { return nil }
        let expected = try inspectBackupFile(url, metadata: true)
        return try readBackupMetadata(url, matching: expected)
    }

    private static func restoreBackupMetadata(_ data: Data?, at url: URL) throws {
        if let data { try data.write(to: url, options: .atomic) }
        else if backupEntryExists(url) { try FileManager.default.removeItem(at: url) }
    }
}
