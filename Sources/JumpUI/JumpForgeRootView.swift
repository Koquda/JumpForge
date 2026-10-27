import SwiftUI
import Charts
import JumpCore
import JumpMedia

private enum WorkspaceTab: String, CaseIterable {
    case overview = "Overview", athletes = "Athletes", progress = "Progress"
    var symbol: String {
        switch self { case .overview: "square.grid.2x2"; case .athletes: "person.2"; case .progress: "chart.xyaxis.line" }
    }
}

enum ForgeStyle {
    static let lime = Color(red: 0.77, green: 0.98, blue: 0.26)
    static let background = Color(red: 0.055, green: 0.065, blue: 0.075)
    static let surface = Color(red: 0.095, green: 0.108, blue: 0.12)
    static let border = Color.white.opacity(0.09)
}

public struct JumpForgeRootView: View {
    @StateObject private var model = JumpForgeModel()
    @ForgeState private var tab: WorkspaceTab = .overview
    @ForgeState private var importer = false
    @ForgeState private var athleteSheet = false
    @ForgeState private var athleteName = ""
    @ForgeState private var exportDocument = CSVDocument(text: "")
    @ForgeState private var exporter = false
    @ForgeState private var capture = false
    @ForgeState private var backup = false

    public init() {}

    public var body: some View {
        Group {
            #if os(macOS)
            desktop
            #else
            TabView(selection: $tab) {
                ForEach(WorkspaceTab.allCases, id: \.self) { item in
                    NavigationStack { content(for: item) }
                        .tabItem { Label(item.rawValue, systemImage: item.symbol) }.tag(item)
                }
            }
            #endif
        }
        .background(ForgeStyle.background)
        .preferredColorScheme(.dark)
        .tint(ForgeStyle.lime)
        .task { await model.load() }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.movie], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await model.openVideo(url) } }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporter, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "JumpForge-results") { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
        .sheet(isPresented: $athleteSheet) { athleteForm }
        .sheet(isPresented: $backup) { BackupScreen(model: model) }
        .sheet(item: $model.draft, onDismiss: { model.discardReview() }) { draft in
            ReviewScreen(model: model, initial: draft)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $capture) {
            CameraCaptureScreen(onCapture: { url in
                capture = false
                Task { await model.openVideo(url, captured: true) }
            }, onCancel: { capture = false })
        }
        #endif
        .alert("Something needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    #if os(macOS)
    private var desktop: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 30) {
                brand
                VStack(spacing: 6) {
                    ForEach(WorkspaceTab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .foregroundStyle(tab == item ? ForgeStyle.lime : .secondary)
                                .background(tab == item ? ForgeStyle.lime.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label("ON-DEVICE ANALYSIS", systemImage: "lock.shield")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(ForgeStyle.lime)
                    Text("Your footage. Your athletes.\nStored on this device.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }
            }.padding(24).frame(width: 224).background(ForgeStyle.surface.opacity(0.5))
            Rectangle().fill(ForgeStyle.border).frame(width: 1)
            content(for: tab)
        }.frame(minWidth: 960, minHeight: 700)
    }
    #endif

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.right").font(.system(size: 21, weight: .black))
                .foregroundStyle(ForgeStyle.background).frame(width: 35, height: 40)
                .background(ForgeStyle.lime, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("JUMPFORGE").font(.system(size: 17, weight: .heavy)).tracking(-0.7)
                Text("MAKE EVERY REP COUNT").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.8).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private func content(for item: WorkspaceTab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(item)
                if !model.loaded {
                    loading
                } else {
                    switch item {
                    case .overview: overview
                    case .athletes: athletes
                    case .progress: progress
                    }
                }
            }.padding(28).frame(maxWidth: 1260, alignment: .leading).frame(maxWidth: .infinity)
        }.background(ForgeStyle.background)
    }

    private func header(_ item: WorkspaceTab) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(iOS)
            brand
            #endif
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item == .overview ? "THE NEXT LEVEL STARTS HERE" : "YOUR TRAINING, IN FOCUS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.7).foregroundStyle(ForgeStyle.lime)
                    Text(item == .overview ? "Jump lab" : item.rawValue)
                        .font(.system(size: 36, weight: .bold)).tracking(-1.3)
                }
                Spacer(minLength: 12)
                Button { backup = true } label: { Image(systemName: "externaldrive") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Library backup and restore")
                    .disabled(!model.loaded || model.busy)
                if item == .athletes {
                    Button { athleteSheet = true } label: { Label("Add athlete", systemImage: "plus") }.buttonStyle(.bordered)
                        .disabled(!model.loaded || model.busy)
                }
            }
            if item != .athletes, !model.library.athletes.isEmpty { athletePicker }
        }
    }

    private var athletePicker: some View {
        HStack {
            Picker("Athlete", selection: Binding(get: { model.selectedAthleteID }, set: { model.selectAthlete($0) })) {
                ForEach(model.library.athletes) { athlete in Text(athlete.name).tag(Optional(athlete.id)) }
            }.pickerStyle(.menu).frame(maxWidth: 280, alignment: .leading).disabled(model.busy)
            Spacer()
            Text(Date.now, format: .dateTime.day().month(.abbreviated).year())
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.loadFailure == nil { ProgressView("Opening your library…") }
            else {
                Label("Library unavailable", systemImage: "externaldrive.badge.exclamationmark").font(.headline)
                Text(model.loadFailure ?? "Your saved data has not been replaced.").foregroundStyle(.secondary)
                Text("Your saved data has not been replaced. Try opening the library again.").font(.caption).foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load() } }.buttonStyle(ForgePrimaryButtonStyle())
            }
        }.forgeCard()
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let notice = model.recoveryNotice {
                Label(notice, systemImage: "externaldrive.badge.checkmark")
                    .font(.callout).foregroundStyle(.orange).forgeCard()
            }
            if model.library.athletes.isEmpty { welcome }
            else {
                sessionSetup
                summaryCards
                if let session = model.session { sessionHistory(session) }
                else { emptyState("Ready when you are", subtitle: "Start a session, then import a jump clip for frame-by-frame review.", symbol: "figure.jumprope") }
                methodNote
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("01 / BUILD YOUR BASELINE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.3).foregroundStyle(ForgeStyle.lime)
                Spacer()
                Image(systemName: "figure.track.and.field").font(.system(size: 56, weight: .light)).foregroundStyle(ForgeStyle.lime)
            }
            Text("A clearer view\nof your vertical.").font(.system(size: 44, weight: .bold)).tracking(-1.6)
            Text("Turn a jump video into a reviewed flight-time estimate. Keep every attempt, build a session history, and track like-for-like progress.")
                .font(.body).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading).lineSpacing(5)
            Button { athleteSheet = true } label: { Label("Create your first athlete", systemImage: "plus") }
                .buttonStyle(ForgePrimaryButtonStyle()).controlSize(.large).foregroundStyle(ForgeStyle.background)
            HStack(spacing: 20) {
                Label("Frame review", systemImage: "film.stack")
                Label("Local storage", systemImage: "lock")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [ForgeStyle.surface, ForgeStyle.lime.opacity(0.065)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(ForgeStyle.border))
    }

    private var sessionSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("SESSION WORKSPACE").eyebrow()
                    Text(model.athlete?.name ?? "Select an athlete").font(.title2.bold())
                }
                Spacer()
                Label(model.session == nil ? "Ready to start" : "Session open", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(ForgeStyle.lime)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 20) { protocolControl; sessionControl; Spacer(); importButtons }
                VStack(alignment: .leading, spacing: 16) { protocolControl; sessionControl; importButtons }
            }
            Text(model.selectedProtocol == .cmj ? "Countermovement jump. Keep the hands and landing posture consistent between attempts." : "Squat jump. Hold a steady squat before takeoff; avoid a countermovement.")
                .font(.caption).foregroundStyle(.secondary)
        }.forgeCard()
    }

    private var protocolControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROTOCOL").eyebrow()
            Picker("Protocol", selection: $model.selectedProtocol) {
                ForEach(JumpProtocol.allCases) { item in Text(item.rawValue.uppercased()).tag(item) }
            }.pickerStyle(.segmented).frame(width: 170).disabled(model.busy)
                .onChange(of: model.selectedProtocol) { _, new in
                    if model.session?.protocolType != new { model.selectedSessionID = nil }
                }
        }
    }

    private var sessionControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVE SESSION").eyebrow()
            HStack {
                Picker("Session", selection: $model.selectedSessionID) {
                    Text("New session").tag(Optional<UUID>.none)
                    ForEach(model.comparableSessions) { session in
                        Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).tag(Optional(session.id))
                    }
                }.labelsHidden().frame(maxWidth: 260).disabled(model.busy)
                Button { Task { await model.startSession() } } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Start new session").help("Start a new session").disabled(model.busy)
            }
        }
    }

    private var importButtons: some View {
        HStack(spacing: 10) {
            #if os(iOS)
            Button { capture = true } label: { Image(systemName: "video") }.buttonStyle(.bordered).accessibilityLabel("Record jump")
            #endif
            Button { importer = true } label: {
                if model.busy { ProgressView().controlSize(.small) }
                else { Label("Import jump", systemImage: "plus") }
            }.buttonStyle(ForgePrimaryButtonStyle()).controlSize(.large).foregroundStyle(ForgeStyle.background)
                .disabled(model.busy || !model.loaded || model.selectedAthleteID == nil)
        }
    }

    private var summaryCards: some View {
        let summary = SessionSummary(attempts: model.session?.attempts ?? [])
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
            metric("BEST JUMP", value: summary.bestCentimeters.map { String(format: "%.1f", $0) } ?? "—", unit: "cm", symbol: "arrow.up.right")
            metric("MEDIAN", value: summary.medianCentimeters.map { String(format: "%.1f", $0) } ?? "—", unit: "cm", symbol: "chart.bar")
            metric("CONSISTENCY / CV", value: summary.coefficientOfVariation.map { String(format: "%.1f", $0 * 100) } ?? "—", unit: "%", symbol: "waveform.path")
            metric("REVIEWED ATTEMPTS", value: "\(summary.count)", unit: "jumps", symbol: "checkmark.seal")
        }
    }

    private func metric(_ title: String, value: String, unit: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text(title).eyebrow(); Spacer(); Image(systemName: symbol).foregroundStyle(ForgeStyle.lime).font(.caption) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }.forgeCard(padding: 20).accessibilityElement(children: .combine)
    }

    private func sessionHistory(_ session: JumpSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Session attempts").font(.title3.bold()); Spacer(); Text(session.protocolType.displayName).font(.caption).foregroundStyle(.secondary) }
            if session.attempts.isEmpty {
                Text("No reviewed attempts yet. Import a clip to find takeoff and landing.").foregroundStyle(.secondary).padding(.vertical, 18)
            } else {
                ForEach(Array(session.attempts.enumerated()), id: \.element.id) { index, attempt in
                    attemptRow(attempt, index: index, session: session)
                    DisclosureGroup("Analysis history · \(attempt.revisions.count)") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(attempt.revisions.enumerated()), id: \.element.id) { revisionIndex, revision in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("Revision \(revisionIndex + 1)").font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(String(format: "%.1f cm", revision.measurement.heightCentimeters)).font(.caption.weight(.semibold)).monospacedDigit()
                                    }
                                    Text("\(revision.createdAt.formatted(date: .abbreviated, time: .shortened)) · takeoff frame \(revision.takeoffIndex + 1) · landing frame \(revision.landingIndex + 1)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if !revision.note.isEmpty { Text(revision.note).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }.padding(.top, 12)
                    }.font(.caption).foregroundStyle(.secondary)
                    if index < session.attempts.count - 1 { Divider().overlay(ForgeStyle.border) }
                }
            }
        }.forgeCard()
    }

    private func attemptRow(_ attempt: JumpAttempt, index: Int, session: JumpSession) -> some View {
        HStack(spacing: 16) {
            Text(String(format: "%02d", index + 1)).font(.system(.headline, design: .monospaced)).foregroundStyle(ForgeStyle.lime)
                .frame(width: 44, height: 44).background(ForgeStyle.lime.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(attempt.originalFilename).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(attempt.createdAt.formatted(date: .omitted, time: .shortened)) · \(attempt.revisions.count) analysis \(attempt.revisions.count == 1 ? "revision" : "revisions")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let result = attempt.revisions.last?.measurement {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.1f cm", result.heightCentimeters)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(String(format: "%.1f–%.1f cm", result.lowerHeightCentimeters, result.upperHeightCentimeters)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button { Task { await model.reanalyze(attempt, session: session) } } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(.borderless).accessibilityLabel("Review attempt \(index + 1)")
                .disabled(model.busy)
        }
    }

    private var athletes: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.library.athletes.isEmpty { welcome }
            ForEach(model.library.athletes) { athlete in
                Button {
                    model.selectAthlete(athlete.id)
                    tab = .overview
                } label: {
                    HStack(spacing: 18) {
                        Text(String(athlete.name.prefix(2)).uppercased()).font(.title3.bold()).foregroundStyle(ForgeStyle.lime)
                            .frame(width: 56, height: 56).background(ForgeStyle.lime.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(athlete.name).font(.headline)
                            Text("\(model.library.sessions.filter { $0.athleteID == athlete.id }.count) sessions").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.forgeCard()
                }.buttonStyle(.plain)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 24) {
            if model.library.athletes.isEmpty { welcome }
            else {
                HStack {
                    protocolControl
                    Spacer()
                    Button { Task { await exportCSV() } } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text("Session best").font(.title3.bold())
                    Text("Only \(model.selectedProtocol.displayName) sessions are compared.").font(.caption).foregroundStyle(.secondary)
                    if chartPoints.isEmpty {
                        emptyState("Your history starts with one jump", subtitle: "Save a reviewed attempt to see progress here.", symbol: "chart.xyaxis.line")
                    } else {
                        Chart(chartPoints) { point in
                            LineMark(x: .value("Session", point.date), y: .value("Height (cm)", point.height)).foregroundStyle(ForgeStyle.lime)
                            PointMark(x: .value("Session", point.date), y: .value("Height (cm)", point.height)).foregroundStyle(ForgeStyle.lime).symbolSize(55)
                        }.chartYAxisLabel("Height (cm)").chartYScale(domain: .automatic(includesZero: true)).frame(height: 260)
                        .accessibilityLabel("Session best jump heights for \(model.selectedProtocol.displayName)")
                    }
                }.forgeCard()
                ForEach(model.comparableSessions) { session in sessionHistory(session) }
                methodNote
            }
        }
    }

    private var chartPoints: [SessionPoint] {
        model.comparableSessions.reversed().compactMap { session in
            SessionSummary(attempts: session.attempts).bestCentimeters.map { SessionPoint(id: session.id, date: session.createdAt, height: $0) }
        }
    }

    private var methodNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(ForgeStyle.lime)
            VStack(alignment: .leading, spacing: 5) {
                Text("An estimate with context").font(.subheadline.weight(.semibold))
                Text("Height is estimated from flight time using h = g × t² / 8. The range reflects one-frame uncertainty at each boundary, not total measurement error. Takeoff and landing posture, camera angle, and video timing can affect results. This is a training tool.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }
        }.padding(20).background(ForgeStyle.lime.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private func emptyState(_ title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(ForgeStyle.lime)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    private var athleteForm: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Every athlete starts somewhere.").font(.title2.bold())
                Text("Add a name to keep sessions and progress together.").foregroundStyle(.secondary)
                TextField("Athlete name", text: $athleteName).textFieldStyle(.roundedBorder)
                    .onSubmit { saveAthlete() }
                Spacer(minLength: 0)
                HStack {
                    Button("Cancel") { athleteSheet = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Create athlete") { saveAthlete() }.buttonStyle(ForgePrimaryButtonStyle())
                        .foregroundStyle(ForgeStyle.background).disabled(model.busy || athleteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(28).frame(minWidth: 320, idealWidth: 440, minHeight: 280)
                .background(ForgeStyle.background).navigationTitle("New athlete")
        }.preferredColorScheme(.dark)
    }

    private func saveAthlete() {
        let name = athleteName
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            await model.addAthlete(name: name)
            if model.error == nil { athleteSheet = false; athleteName = ""; tab = .overview }
        }
    }

    private func exportCSV() async {
        do { exportDocument = CSVDocument(text: try await model.store.exportCSV(model.library)); exporter = true }
        catch { model.error = error.localizedDescription }
    }
}

private struct SessionPoint: Identifiable { let id: UUID; let date: Date; let height: Double }

extension View {
    func forgeCard(padding: CGFloat = 24) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(ForgeStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(ForgeStyle.border))
    }
    func eyebrow() -> some View {
        self.font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.1).foregroundStyle(.secondary)
    }
}
