import SwiftUI
import JumpCore
import JumpMedia

struct ReviewScreen: View {
    @ObservedObject var model: JumpForgeModel
    @ForgeState private var review: ReviewDraft
    @ForgeState private var cursor = 0
    @ForgeState private var displayedFrame = 0
    @ForgeState private var takeoffReviewed = false
    @ForgeState private var landingReviewed = false
    @ForgeState private var frameLoading = false
    @ForgeState private var frameError: String?
    @ForgeState private var seekingSuggestions = false
    @ForgeState private var suggestionTask: Task<Void, Never>?
    @ForgeState private var suggestionError: String?
    @ForgeState private var frameEntry = "1"
    @ForgeState private var zoom = 1.0
    @ForgeState private var pan = CGSize.zero
    @ForgeState private var panOrigin = CGSize.zero
    @ForgeState private var calculated: JumpMeasurement?
    @ForgeState private var calculationError: String?
    @ForgeState private var calculatedKey: CalculationKey?
    @Environment(\.dismiss) private var dismiss

    init(model: JumpForgeModel, initial: ReviewDraft) {
        self.model = model
        _review = State(initialValue: initial)
    }

    private var currentFrame: FrameStamp { review.indexed.frames[cursor] }
    private var readyFrame: Bool { displayedFrame == cursor && !frameLoading && frameError == nil }
    private var calculationKey: CalculationKey {
        CalculationKey(takeoff: review.takeoff, landing: review.landing, timing: review.timing.rawValue,
                       takeoffReviewed: takeoffReviewed, landingReviewed: landingReviewed)
    }
    private var measurement: JumpMeasurement? { calculatedKey == calculationKey ? calculated : nil }
    private var validationMessage: String? {
        calculatedKey == calculationKey ? calculationError : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    videoFrame
                    timeline
                    markerControls
                    timingConfirmation
                    if let validationMessage { Label(validationMessage, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    if let measurement { resultCard(measurement) }
                    else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Review before measuring").font(.headline)
                            Text("Mark the first airborne frame and the first frame of landing contact. Both events need your review. Confirm the clip’s original timing to unlock a result.")
                                .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                        }.forgeCard()
                    }
                    TextField("Optional analysis note", text: $review.note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                    HStack {
                        Button("Cancel") { model.discardReview(); dismiss() }.disabled(model.busy)
                        Spacer()
                        Button(review.existingAttemptID == nil ? "Save attempt" : "Save new revision") {
                            if let measurement { Task { await model.saveReview(review, measurement: measurement) } }
                        }.buttonStyle(ForgePrimaryButtonStyle()).controlSize(.large).foregroundStyle(ForgeStyle.background)
                            .disabled(measurement == nil || model.busy)
                    }
                }.padding(28).frame(maxWidth: 1050).frame(maxWidth: .infinity)
            }.background(ForgeStyle.background)
                .navigationTitle("Review jump")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        .preferredColorScheme(.dark).tint(ForgeStyle.lime)
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 720)
        #endif
        .interactiveDismissDisabled(model.busy)
        .task(id: cursor) { await showFrame(cursor) }
        .task(id: calculationKey) { await calculate() }
        .onChange(of: cursor) { _, new in frameEntry = String(new + 1) }
        .onDisappear {
            suggestionTask?.cancel()
            if review.existingAttemptID == nil { try? FileManager.default.removeItem(at: review.url) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.existingAttemptID == nil ? "FRAME-BY-FRAME REVIEW" : "NEW ANALYSIS REVISION").eyebrow()
            Text(review.originalFilename).font(.title2.bold()).lineLimit(2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { sourceInfo }
                VStack(alignment: .leading, spacing: 7) { sourceInfo }
            }.font(.caption).foregroundStyle(.secondary)
            if review.indexed.nominalFrameRate < 100 {
                Label("Lower frame-rate footage produces a wider timing range. Original 120 or 240 fps footage is preferable when available.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if review.existingAttemptID != nil {
                Text("Saving creates a new revision. Earlier analyses stay in your library.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var sourceInfo: some View {
        Label(String(format: "%.2f nominal fps", review.indexed.nominalFrameRate), systemImage: "speedometer")
        Label("\(review.indexed.frames.count) timestamped frames", systemImage: "film.stack")
        Text("\(review.indexed.pixelWidth) × \(review.indexed.pixelHeight)")
        Text(String(format: "%.2f sec", review.indexed.durationSeconds))
    }

    private var videoFrame: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Image(decorative: review.image, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(zoom)
                .offset(pan)
                .gesture(DragGesture().onChanged { value in
                    guard zoom > 1 else { return }
                    pan = CGSize(width: panOrigin.width + value.translation.width, height: panOrigin.height + value.translation.height)
                }.onEnded { _ in panOrigin = pan })
                .opacity(frameLoading ? 0.45 : 1)
            HStack {
                Text(String(format: "FRAME %05d", displayedFrame + 1)).font(.system(.caption, design: .monospaced).weight(.bold))
                Spacer()
                if frameLoading { ProgressView().controlSize(.small) }
                else if displayedFrame == review.takeoff && takeoffReviewed { Label("TAKEOFF", systemImage: "arrow.up").font(.caption.bold()) }
                else if displayedFrame == review.landing && landingReviewed { Label("LANDING", systemImage: "arrow.down").font(.caption.bold()) }
            }.foregroundStyle(ForgeStyle.lime).padding(16).background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
            if let frameError {
                VStack(spacing: 10) {
                    Text(frameError).multilineTextAlignment(.center)
                    Button("Retry frame") { Task { await showFrame(cursor) } }.buttonStyle(.bordered)
                }.font(.callout).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.7))
            }
        }.frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ForgeStyle.border))
            .accessibilityLabel("Video preview, frame \(displayedFrame + 1) of \(review.indexed.frames.count)")
    }

    private var timeline: some View {
        VStack(spacing: 16) {
            HStack {
                TextField("Frame", text: $frameEntry)
                    .textFieldStyle(.roundedBorder).frame(width: 76)
                    .accessibilityLabel("Go to frame")
                    .onSubmit { goToFrame() }
                Button("Go") { goToFrame() }.buttonStyle(.bordered)
                Spacer()
                Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
                Slider(value: $zoom, in: 1...4).frame(maxWidth: 130).accessibilityLabel("Video magnification")
                Button("Reset view") { zoom = 1; pan = .zero; panOrigin = .zero }.buttonStyle(.bordered)
            }
            Slider(value: Binding(get: { Double(cursor) }, set: { cursor = Int($0.rounded()) }), in: 0...Double(max(1, review.indexed.frames.count - 1)), step: 1)
                .disabled(review.indexed.frames.count < 2)
                .accessibilityLabel("Video frame").accessibilityValue("\(cursor + 1) of \(review.indexed.frames.count)")
            HStack(spacing: 18) {
                Button { step(-1) } label: { Image(systemName: "backward.frame.fill").frame(width: 32, height: 30) }
                    .buttonStyle(.bordered).disabled(cursor == 0).accessibilityLabel("Previous frame")
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Text(String(format: "%.4f s", currentFrame.seconds - review.indexed.frames[0].seconds))
                    .font(.system(.subheadline, design: .monospaced)).monospacedDigit().frame(minWidth: 100)
                Button { step(1) } label: { Image(systemName: "forward.frame.fill").frame(width: 32, height: 30) }
                    .buttonStyle(.bordered).disabled(cursor >= review.indexed.frames.count - 1).accessibilityLabel("Next frame")
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                Text("\(cursor + 1) / \(review.indexed.frames.count)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if takeoffReviewed || review.existingAttemptID != nil { Button("Takeoff · \(review.takeoff + 1)") { cursor = review.takeoff }.buttonStyle(.bordered) }
                if landingReviewed || review.existingAttemptID != nil { Button("Landing · \(review.landing + 1)") { cursor = review.landing }.buttonStyle(.bordered) }
                Spacer(minLength: 0)
            }.font(.caption)
        }
    }

    private var markerControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                marker(title: "01 / TAKEOFF", detail: "First frame with both feet off the ground.", confirmed: takeoffReviewed, symbol: "arrow.up") {
                    review.takeoff = cursor
                    takeoffReviewed = true
                }
                marker(title: "02 / LANDING", detail: "First frame with a foot touching the ground.", confirmed: landingReviewed, symbol: "arrow.down") {
                    review.landing = cursor
                    landingReviewed = true
                }
            }
            Text("Step back one frame at each boundary to verify the transition. Keep the feet visible and use the same posture at takeoff and landing.")
                .font(.caption).foregroundStyle(.secondary)
            if let suggestion = review.suggestion {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("Assisted suggestions · review required", systemImage: "sparkle").font(.subheadline.weight(.semibold))
                    Text(suggestion.explanation).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if let index = suggestion.takeoffIndex, review.indexed.frames.indices.contains(index) {
                            Button("Inspect suggested takeoff") { cursor = index }.buttonStyle(.bordered)
                        }
                        if let index = suggestion.landingIndex, review.indexed.frames.indices.contains(index) {
                            Button("Inspect suggested landing") { cursor = index }.buttonStyle(.bordered)
                        }
                    }.font(.caption)
                }
            } else {
                Divider()
                HStack {
                    Button {
                        if seekingSuggestions { suggestionTask?.cancel(); seekingSuggestions = false }
                        else { findSuggestions() }
                    } label: {
                        Label(seekingSuggestions ? "Cancel assisted analysis" : "Find assisted suggestions", systemImage: seekingSuggestions ? "xmark.circle" : "sparkle")
                    }.buttonStyle(.bordered).disabled(review.timing == .retimed)
                    if seekingSuggestions { ProgressView().controlSize(.small) }
                }
                Text("Optional pose-based suggestions can help locate events. They never confirm frames for you.")
                    .font(.caption).foregroundStyle(.secondary)
                if let suggestionError { Text(suggestionError).font(.caption).foregroundStyle(.orange) }
            }
        }.forgeCard()
    }

    private func marker(title: String, detail: String, confirmed: Bool, symbol: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrow()
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Label(confirmed ? "Update reviewed frame" : "Mark reviewed frame", systemImage: confirmed ? "checkmark.circle.fill" : symbol)
                    .font(.caption.weight(.semibold))
            }.buttonStyle(.bordered).disabled(!readyFrame || (symbol == "arrow.up" && cursor == 0))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timingConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Source timing", systemImage: "clock.badge.checkmark").font(.headline)
            if review.timing == .retimed {
                Text("This clip contains retiming. Measurement is blocked. Import original real-time footage with the original frame timestamps.")
                    .font(.callout).foregroundStyle(.orange)
            } else if review.timing == .captured {
                Text("Captured in JumpForge. The measurement uses the recorded presentation timestamps.").font(.callout).foregroundStyle(.secondary)
            } else {
                Toggle("This is original real-time footage", isOn: Binding(get: { review.timing == .confirmedOriginal }, set: { review.timing = $0 ? .confirmedOriginal : .unverified }))
                    .font(.callout)
                Text("Confirm that the clip has not been slowed down, sped up, or exported with altered timing. A reported frame rate alone cannot establish original timing. If you are unsure, leave this off and use a new original recording.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
        }.forgeCard()
    }

    private func resultCard(_ result: JumpMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("REVIEWED FLIGHT-TIME ESTIMATE").eyebrow(); Spacer(); Image(systemName: "checkmark.seal").foregroundStyle(ForgeStyle.lime) }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%.1f", result.heightCentimeters)).font(.system(size: 62, weight: .bold, design: .rounded)).tracking(-2).foregroundStyle(ForgeStyle.lime).monospacedDigit()
                Text("cm").font(.title2).foregroundStyle(.secondary)
                Spacer()
            }
            Text(String(format: "Frame range %.1f–%.1f cm · flight time %.3f s", result.lowerHeightCentimeters, result.upperHeightCentimeters, result.flightTimeSeconds))
                .font(.subheadline).monospacedDigit()
            Text("The range accounts for the interval between adjacent frames at each event. It does not include posture, camera, or other sources of error. Similar takeoff and landing body positions are essential.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(ForgeStyle.lime.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(ForgeStyle.lime.opacity(0.25)))
    }

    private func step(_ value: Int) { cursor = min(max(0, cursor + value), review.indexed.frames.count - 1) }

    private func goToFrame() {
        if let number = Int(frameEntry) {
            cursor = min(max(0, number - 1), review.indexed.frames.count - 1)
        }
        frameEntry = String(cursor + 1)
    }

    private func calculate() async {
        let key = calculationKey
        calculated = nil
        calculationError = nil
        calculatedKey = nil
        guard key.takeoffReviewed, key.landingReviewed, review.timing.allowsMeasurement else { return }
        let frames = review.indexed.frames
        let timing = review.timing
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                return CalculationOutcome(measurement: try MeasurementEngine.measure(frames: frames, takeoff: key.takeoff, landing: key.landing, timing: timing), error: nil)
            } catch { return CalculationOutcome(measurement: nil, error: error.localizedDescription) }
        }.value
        guard !Task.isCancelled, key == calculationKey else { return }
        calculated = outcome.measurement
        calculationError = outcome.error
        calculatedKey = key
    }

    private func findSuggestions() {
        seekingSuggestions = true
        suggestionError = nil
        let url = review.url
        let indexed = review.indexed
        suggestionTask = Task {
            do {
                let suggestion = try await VideoService().suggest(url: url, indexed: indexed)
                guard !Task.isCancelled else { return }
                review.suggestion = suggestion
            } catch {
                guard !Task.isCancelled else { return }
                suggestionError = error.localizedDescription
            }
            seekingSuggestions = false
        }
    }

    private func showFrame(_ index: Int) async {
        guard review.indexed.frames.indices.contains(index) else { return }
        frameLoading = true
        frameError = nil
        do {
            let image = try await model.video.image(url: review.url, frame: review.indexed.frames[index])
            guard !Task.isCancelled, index == cursor else { return }
            review.image = image
            displayedFrame = index
            frameLoading = false
        } catch {
            guard !Task.isCancelled, index == cursor else { return }
            frameError = error.localizedDescription
            frameLoading = false
        }
    }
}

private struct CalculationKey: Hashable, Sendable {
    let takeoff: Int
    let landing: Int
    let timing: String
    let takeoffReviewed: Bool
    let landingReviewed: Bool
}

private struct CalculationOutcome: Sendable {
    let measurement: JumpMeasurement?
    let error: String?
}
