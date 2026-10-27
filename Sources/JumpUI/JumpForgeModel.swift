import SwiftUI
import JumpCore
import JumpMedia
import UniformTypeIdentifiers

@MainActor
final class JumpForgeModel: ObservableObject {
    @Published var library = JumpLibrary()
    @Published var loaded = false
    @Published var error: String?
    @Published var recoveryNotice: String?
    @Published var loadFailure: String?
    @Published var selectedAthleteID: UUID?
    @Published var selectedSessionID: UUID?
    @Published var selectedProtocol: JumpProtocol = .cmj
    @Published var busy = false
    @Published var draft: ReviewDraft?
    let store: LibraryStore
    let video = VideoService()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let override = ProcessInfo.processInfo.environment["JUMPFORGE_DATA_DIR"]
        store = LibraryStore(directory: override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? base.appendingPathComponent("JumpForge", isDirectory: true))
    }

    var athlete: Athlete? { library.athletes.first { $0.id == selectedAthleteID } }
    var session: JumpSession? { library.sessions.first { $0.id == selectedSessionID } }
    var athleteSessions: [JumpSession] {
        library.sessions.filter { $0.athleteID == selectedAthleteID }.sorted { $0.createdAt > $1.createdAt }
    }
    var comparableSessions: [JumpSession] { athleteSessions.filter { $0.protocolType == selectedProtocol } }

    func load() async {
        guard !loaded else { return }
        loadFailure = nil
        do {
            library = try await store.load()
            recoveryNotice = await store.recoveryNotice
            selectedAthleteID = library.athletes.first?.id
            selectedSessionID = athleteSessions.first?.id
            if let session { selectedProtocol = session.protocolType }
            loaded = true
        } catch {
            loadFailure = "Your library could not be opened. \(error.localizedDescription)"
            self.error = loadFailure
        }
    }

    func addAthlete(name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !busy, !clean.isEmpty else { return }
        busy = true
        defer { busy = false }
        var updated = library
        let athlete = Athlete(name: clean)
        updated.athletes.append(athlete)
        do {
            try await store.save(updated)
            library = updated
            selectedAthleteID = athlete.id
            selectedSessionID = nil
        } catch { self.error = error.localizedDescription }
    }

    func startSession() async {
        guard loaded, !busy else { return }
        busy = true
        defer { busy = false }
        await createSession()
    }

    private func createSession() async {
        guard loaded, let id = selectedAthleteID else { return }
        var updated = library
        let session = JumpSession(athleteID: id, protocolType: selectedProtocol)
        updated.sessions.append(session)
        do {
            try await store.save(updated)
            library = updated
            selectedSessionID = session.id
        } catch { self.error = error.localizedDescription }
    }

    func selectAthlete(_ id: UUID?) {
        guard !busy else { return }
        selectedAthleteID = id
        selectedSessionID = athleteSessions.first?.id
        if let session { selectedProtocol = session.protocolType }
    }

    func openVideo(_ url: URL, captured: Bool = false) async {
        guard loaded, !busy, selectedAthleteID != nil else { return }
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        defer { if captured { try? FileManager.default.removeItem(at: url) } }
        do {
            let indexed = try await video.index(url: url)
            guard !indexed.frames.isEmpty else { throw ReviewError.emptyVideo }
            let first = try await video.image(url: url, frame: indexed.frames[0])
            // Hold the source access through review by staging it in the app temporary directory.
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: url, to: staged)
            }.value
            if session == nil { await createSession() }
            guard let targetSession = session else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            draft = ReviewDraft(url: staged, originalFilename: url.lastPathComponent, indexed: indexed, image: first, suggestion: nil, sessionID: targetSession.id, captured: captured)
        } catch { self.error = error.localizedDescription }
    }

    func reanalyze(_ attempt: JumpAttempt, session: JumpSession) async {
        guard loaded, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let url = try await store.mediaURL(filename: attempt.mediaFilename)
            let indexed = try await video.index(url: url)
            guard indexed.frames == attempt.frames, !indexed.frames.isEmpty, !indexed.isRetimed else { throw ReviewError.changedVideo }
            let first = try await video.image(url: url, frame: indexed.frames[0])
            var review = ReviewDraft(url: url, originalFilename: attempt.originalFilename, indexed: indexed, image: first, suggestion: nil, sessionID: session.id, captured: attempt.timing == .captured)
            review.existingAttemptID = attempt.id
            review.timing = attempt.timing
            if let revision = attempt.revisions.last {
                review.takeoff = min(revision.takeoffIndex, indexed.frames.count - 1)
                review.landing = min(revision.landingIndex, indexed.frames.count - 1)
            }
            draft = review
        } catch { self.error = error.localizedDescription }
    }

    func discardReview() {
        if let draft, draft.existingAttemptID == nil { try? FileManager.default.removeItem(at: draft.url) }
        draft = nil
    }

    func saveReview(_ review: ReviewDraft, measurement: JumpMeasurement) async {
        guard loaded, !busy, let sessionIndex = library.sessions.firstIndex(where: { $0.id == review.sessionID }) else { return }
        busy = true
        defer { busy = false }
        do {
            var updated = library
            let revision = AnalysisRevision(takeoffIndex: review.takeoff, landingIndex: review.landing, measurement: measurement, detector: "Manual frame review", note: review.note)
            if let existingID = review.existingAttemptID,
               let index = updated.sessions[sessionIndex].attempts.firstIndex(where: { $0.id == existingID }) {
                updated.sessions[sessionIndex].attempts[index].revisions.append(revision)
            } else {
                let filename = try await store.importMedia(from: review.url)
                let attempt = JumpAttempt(mediaFilename: filename, originalFilename: review.originalFilename, frames: review.indexed.frames, timing: review.timing, revisions: [revision])
                updated.sessions[sessionIndex].attempts.append(attempt)
            }
            try await store.save(updated)
            library = updated
            selectedSessionID = review.sessionID
            discardReview()
        } catch { self.error = error.localizedDescription }
    }
}

enum ReviewError: LocalizedError {
    case emptyVideo, changedVideo
    var errorDescription: String? {
        switch self {
        case .emptyVideo: "This video has no readable frames."
        case .changedVideo: "The stored video timestamps no longer match the original analysis. The earlier results have been preserved."
        }
    }
}

struct ReviewDraft: Identifiable {
    let id = UUID()
    let url: URL
    let originalFilename: String
    let indexed: IndexedVideo
    var image: CGImage
    var suggestion: JumpSuggestion?
    let sessionID: UUID
    var existingAttemptID: UUID?
    var takeoff = 0
    var landing = 0
    var timing: TimingProvenance
    var note = ""

    init(url: URL, originalFilename: String, indexed: IndexedVideo, image: CGImage, suggestion: JumpSuggestion?, sessionID: UUID, captured: Bool) {
        self.url = url
        self.originalFilename = originalFilename
        self.indexed = indexed
        self.image = image
        self.suggestion = suggestion
        self.sessionID = sessionID
        timing = indexed.isRetimed ? .retimed : (captured ? .captured : .unverified)
    }
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
