import SwiftUI
import UniformTypeIdentifiers
import JumpCore

extension UTType {
    static let jumpForgeBackup = UTType(exportedAs: "com.koquda.jumpforge.backup", conformingTo: .package)
}

private struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.jumpForgeBackup] }
    let source: URL
    init(source: URL) { self.source = source }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: source, options: [])
    }
}

struct BackupScreen: View {
    @ObservedObject var model: JumpForgeModel
    @ForgeState private var exporter = false
    @ForgeState private var importer = false
    @ForgeState private var document: BackupDocument?
    @ForgeState private var working = false
    @ForgeState private var status: String?
    @ForgeState private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Label("Keep your progress", systemImage: "externaldrive.badge.checkmark")
                    .font(.title2.bold())
                Text("A portable backup includes your athletes, sessions, analysis revisions, and original jump videos. Keep a copy somewhere you trust.")
                    .foregroundStyle(.secondary)
                Button { Task { await makeBackup() } } label: {
                    Label("Export full backup", systemImage: "square.and.arrow.up")
                }.buttonStyle(ForgePrimaryButtonStyle()).foregroundStyle(ForgeStyle.background)
                    .disabled(working || model.busy || !model.loaded)
                Divider()
                Text("Restore adds records without replacing existing ones. Repeated imports of the same backup are safe. Conflicting records need a separate library.")
                    .font(.callout).foregroundStyle(.secondary)
                Button { importer = true } label: {
                    Label("Restore backup", systemImage: "square.and.arrow.down")
                }.buttonStyle(.bordered).disabled(working || model.busy || !model.loaded)
                if working { ProgressView("Preparing your library…") }
                if let status { Label(status, systemImage: "checkmark.circle").foregroundStyle(ForgeStyle.lime) }
                if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Spacer(minLength: 0)
                Button("Done") { dismiss() }.frame(maxWidth: .infinity, alignment: .trailing).disabled(working)
            }.padding(28).frame(minWidth: 320, idealWidth: 520, minHeight: 420)
                .background(ForgeStyle.background)
                .navigationTitle("Library backup")
        }
        .preferredColorScheme(.dark).tint(ForgeStyle.lime)
        .interactiveDismissDisabled(working || model.busy)
        .fileExporter(isPresented: $exporter, document: document, contentType: .jumpForgeBackup, defaultFilename: "JumpForge-backup.jumpforgebackup") { result in
            switch result {
            case .success: status = "Backup exported with original media."
            case .failure(let error): failure = error.localizedDescription
            }
            clearSnapshot()
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.jumpForgeBackup, .package], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await restore(url) } }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .onDisappear { clearSnapshot() }
    }

    private func makeBackup() async {
        guard !working, !model.busy else { return }
        working = true
        model.busy = true
        status = nil
        failure = nil
        defer { working = false; model.busy = false }
        do {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jumpforgebackup", isDirectory: true)
            let source = try await model.store.writeBackup(to: path)
            document = BackupDocument(source: source)
            exporter = true
        } catch { failure = error.localizedDescription }
    }

    private func restore(_ url: URL) async {
        guard !working, !model.busy else { return }
        working = true
        model.busy = true
        status = nil
        failure = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            working = false
            model.busy = false
        }
        do {
            model.library = try await model.store.restoreBackup(from: url)
            model.selectedAthleteID = model.selectedAthleteID ?? model.library.athletes.first?.id
            model.selectedSessionID = model.athleteSessions.first?.id
            if let session = model.session { model.selectedProtocol = session.protocolType }
            status = "Backup restored. Existing records are preserved."
        } catch { failure = error.localizedDescription }
    }

    private func clearSnapshot() {
        if let source = document?.source { try? FileManager.default.removeItem(at: source) }
        document = nil
    }
}
