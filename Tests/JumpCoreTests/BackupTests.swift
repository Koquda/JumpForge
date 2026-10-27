import Foundation
import Testing
@testable import JumpCore

struct BackupTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JumpForgeBackupTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func populatedStore(at directory: URL, name: String = "Athlete") async throws -> (LibraryStore, JumpLibrary, Data) {
        let store = LibraryStore(directory: directory)
        let source = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        let content = Data("original video bytes".utf8)
        try content.write(to: source)
        let filename = try await store.importMedia(from: source)
        let athlete = Athlete(name: name)
        let jump = JumpAttempt(mediaFilename: filename, originalFilename: "original.mov", frames: [], timing: .unverified)
        let library = JumpLibrary(athletes: [athlete], sessions: [JumpSession(athleteID: athlete.id, protocolType: .cmj, attempts: [jump])])
        try await store.save(library)
        return (store, library, content)
    }

    @Test func portableBackupRestoresMediaIntoAnEmptyLibraryAndRepeatsIdempotently() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, library, content) = try await populatedStore(at: root.appendingPathComponent("source"))
        let backup = try await source.writeBackup(to: root.appendingPathComponent("Portable.jumpforgebackup"))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: backup.path)) == Set(["library.json", "manifest.json", "media"]))
        let target = LibraryStore(directory: root.appendingPathComponent("target"))
        let restored = try await target.restoreBackup(from: backup)
        #expect(restored == library)
        #expect(try await target.load() == library)
        let filename = library.sessions[0].attempts[0].mediaFilename
        #expect(try Data(contentsOf: await target.mediaURL(filename: filename)) == content)
        let primary = target.directory.appendingPathComponent("library.json")
        let before = try Data(contentsOf: primary)
        #expect(try await target.restoreBackup(from: backup) == library)
        #expect(try Data(contentsOf: primary) == before)
        #expect(try await target.load().sessions.count == 1)
        await #expect(throws: LibraryBackupError.destinationExists) { try await source.writeBackup(to: backup) }
    }

    @Test func restoreMergesSeparateLibrariesWithoutRemovingExistingRecords() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, imported, _) = try await populatedStore(at: root.appendingPathComponent("source"), name: "Imported")
        let (target, existing, _) = try await populatedStore(at: root.appendingPathComponent("target"), name: "Existing")
        let backup = try await source.writeBackup(to: root.appendingPathComponent("backup"))
        let merged = try await target.restoreBackup(from: backup)
        #expect(merged.athletes == existing.athletes + imported.athletes)
        #expect(merged.sessions == existing.sessions + imported.sessions)
        for session in merged.sessions {
            #expect(FileManager.default.fileExists(atPath: try await target.mediaURL(filename: session.attempts[0].mediaFilename).path))
        }
        #expect(try await target.restoreBackup(from: backup) == merged)
    }

    @Test func conflictingRecordIDsLeaveCurrentLibraryAndMediaUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, content) = try await populatedStore(at: root.appendingPathComponent("store"))
        let backup = try await store.writeBackup(to: root.appendingPathComponent("backup"))
        var changed = original
        changed.athletes[0].name = "Changed name"
        try await store.save(changed)
        let primary = store.directory.appendingPathComponent("library.json")
        let before = try Data(contentsOf: primary)
        await #expect(throws: LibraryBackupError.conflictingRecord(original.athletes[0].id.uuidString)) {
            try await store.restoreBackup(from: backup)
        }
        #expect(try Data(contentsOf: primary) == before)
        #expect(try await store.load() == changed)
        #expect(try Data(contentsOf: await store.mediaURL(filename: original.sessions[0].attempts[0].mediaFilename)) == content)
    }

    @Test func conflictingMediaDoesNotReplaceExistingBytesOrMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, original, _) = try await populatedStore(at: root.appendingPathComponent("source"))
        let backup = try await source.writeBackup(to: root.appendingPathComponent("backup"))
        let target = LibraryStore(directory: root.appendingPathComponent("target"))
        try await target.save(JumpLibrary())
        let filename = original.sessions[0].attempts[0].mediaFilename
        let mediaRoot = target.directory.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let existing = mediaRoot.appendingPathComponent(filename)
        let other = Data("different media".utf8)
        try other.write(to: existing)
        await #expect(throws: LibraryBackupError.conflictingMedia(filename)) { try await target.restoreBackup(from: backup) }
        #expect(try Data(contentsOf: existing) == other)
        #expect(try await target.load() == JumpLibrary())
    }

    @Test func missingOrCorruptedBackupMediaIsRejectedBeforeImport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, original, _) = try await populatedStore(at: root.appendingPathComponent("source"))
        let missing = try await source.writeBackup(to: root.appendingPathComponent("missing"))
        let corrupted = try await source.writeBackup(to: root.appendingPathComponent("corrupted"))
        let filename = original.sessions[0].attempts[0].mediaFilename
        try FileManager.default.removeItem(at: missing.appendingPathComponent("media/" + filename))
        try Data("bad".utf8).write(to: corrupted.appendingPathComponent("media/" + filename))
        let target = LibraryStore(directory: root.appendingPathComponent("target"))
        for package in [missing, corrupted] {
            await #expect(throws: (any Error).self) { try await target.restoreBackup(from: package) }
            #expect(try await target.load() == JumpLibrary())
            #expect(!FileManager.default.fileExists(atPath: target.directory.path))
        }
    }

    @Test func symlinkFilesAndFoldersAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, original, _) = try await populatedStore(at: root.appendingPathComponent("source"))
        let filePackage = try await source.writeBackup(to: root.appendingPathComponent("file-link"))
        let folderPackage = try await source.writeBackup(to: root.appendingPathComponent("folder-link"))
        let filename = original.sessions[0].attempts[0].mediaFilename
        let file = filePackage.appendingPathComponent("media/" + filename)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: await source.mediaURL(filename: filename))
        let folder = folderPackage.appendingPathComponent("media")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: source.directory.appendingPathComponent("media"))
        let rootLink = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: filePackage)
        let target = LibraryStore(directory: root.appendingPathComponent("target"))
        for package in [filePackage, folderPackage, rootLink] {
            await #expect(throws: (any Error).self) { try await target.restoreBackup(from: package) }
            #expect(try await target.load() == JumpLibrary())
        }
    }

    @Test func metadataAndMediaSizeLimitsRejectWithoutReadingHugeFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, original, _) = try await populatedStore(at: root.appendingPathComponent("source"))
        let metadataPackage = try await source.writeBackup(to: root.appendingPathComponent("metadata-large"))
        let mediaPackage = try await source.writeBackup(to: root.appendingPathComponent("media-large"))
        let metadata = try FileHandle(forWritingTo: metadataPackage.appendingPathComponent("manifest.json"))
        try metadata.truncate(atOffset: 50 * 1024 * 1024)
        try metadata.close()
        let filename = original.sessions[0].attempts[0].mediaFilename
        let media = try FileHandle(forWritingTo: mediaPackage.appendingPathComponent("media/" + filename))
        try media.truncate(atOffset: 4 * 1024 * 1024 * 1024)
        try media.close()
        let target = LibraryStore(directory: root.appendingPathComponent("target"))
        for package in [metadataPackage, mediaPackage] {
            await #expect(throws: LibraryBackupError.limitsExceeded) { try await target.restoreBackup(from: package) }
            #expect(try await target.load() == JumpLibrary())
        }
    }

    @Test func failedExportLeavesNoPackageOrStagingFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await populatedStore(at: root.appendingPathComponent("source"))
        let missing = try await store.mediaURL(filename: original.sessions[0].attempts[0].mediaFilename)
        try FileManager.default.removeItem(at: missing)
        let destination = root.appendingPathComponent("backup")
        await #expect(throws: (any Error).self) { try await store.writeBackup(to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".jumpforge-backup-") })
    }
}
