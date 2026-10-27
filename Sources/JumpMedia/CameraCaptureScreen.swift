#if os(iOS)
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

public struct CameraCaptureScreen: View {
    @StateObject private var model = CameraModel()
    private let onCapture: (URL) -> Void
    private let onCancel: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    public init(onCapture: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text("Record a jump").font(.title.bold())
            CameraPreview(session: model.engine.session)
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Text(model.message).multilineTextAlignment(.center)
            Text("Keep the camera still and the athlete’s full body and both feet visible. Maximum 120 seconds.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.engine.stop(discard: true); onCancel() }
                Spacer()
                Button(model.recording ? "Stop recording" : "Record") { model.toggle() }
                    .buttonStyle(.borderedProminent).disabled(!model.ready)
            }
        }
        .padding()
        .task { model.start(onCapture: onCapture) }
        .onDisappear { model.engine.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.engine.stop() } }
    }
}

@MainActor private final class CameraModel: ObservableObject {
    let engine = CameraEngine()
    @Published var message = "Preparing camera…"
    @Published var recording = false
    @Published var ready = false

    func start(onCapture: @escaping (URL) -> Void) {
        engine.onStatus = { [weak self] message, ready, recording in
            self?.message = message
            self?.ready = ready
            self?.recording = recording
        }
        engine.onCapture = onCapture
        engine.prepare()
    }

    func toggle() { engine.toggle() }
}

private final class CameraEngine: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "JumpForge.camera")
    private let output = AVCaptureMovieFileOutput()
    private var configured = false
    private var stopped = false
    private var recordingRequested = false
    private var discardRecording = false
    private var rate = 0
    @MainActor var onStatus: ((String, Bool, Bool) -> Void)?
    @MainActor var onCapture: ((URL) -> Void)?

    func prepare() {
        queue.async { self.stopped = false }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else { self.status("Camera access is disabled. Enable it in Settings to record.", false, false); return }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        guard !stopped else { return }
        guard !configured else { if !session.isRunning { session.startRunning() }; return }
        do {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                status("A rear camera is unavailable.", false, false); return
            }
            let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, Int32, Int32)? in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.width <= 1920, dimensions.height <= 1920 else { return nil }
                let fps: Int32? = [Int32(240), Int32(120)].first { desired in
                    format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(desired) && $0.maxFrameRate >= Double(desired) }
                }
                guard let fps else { return nil }
                return (format, fps, dimensions.width)
            }.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.2 > rhs.2 : lhs.1 > rhs.1 }
            guard let selection = candidates.first else {
                status("This device has no supported 120 or 240 fps camera format.", false, false); return
            }
            session.beginConfiguration()
            var configurationOpen = true
            defer { if configurationOpen { session.commitConfiguration() } }
            session.sessionPreset = .inputPriority
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                status("Camera recording is unavailable.", false, false); return
            }
            session.addInput(input)
            session.addOutput(output)
            try device.lockForConfiguration()
            device.activeFormat = selection.0
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: selection.1)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: selection.1)
            device.unlockForConfiguration()
            output.maxRecordedDuration = CMTime(seconds: 120, preferredTimescale: 600)
            output.minFreeDiskSpaceLimit = 100 * 1024 * 1024
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            rate = Int(selection.1)
            session.commitConfiguration()
            configurationOpen = false
            configured = true
            session.startRunning()
            status("Ready at \(rate) fps. Use good lighting.", true, false)
        } catch {
            if session.isRunning { session.stopRunning() }
            status("The camera could not start. \(error.localizedDescription)", false, false)
        }
    }

    func toggle() {
        queue.async {
            guard self.configured, !self.stopped else { return }
            guard !self.recordingRequested || self.output.isRecording else { return }
            if self.output.isRecording { self.output.stopRecording() }
            else {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("JumpForge-\(UUID().uuidString).mov")
                self.discardRecording = false
                self.recordingRequested = true
                self.output.startRecording(to: url, recordingDelegate: self)
                self.status("Recording at \(self.rate) fps…", true, true)
            }
        }
    }

    func stop(discard: Bool = false) {
        queue.async {
            self.stopped = true
            if discard { self.discardRecording = true }
            if self.output.isRecording { self.output.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            self.status("Camera stopped.", false, false)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: (any Error)?) {
        let nsError = error as NSError?
        let completed = error == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        queue.async {
            self.recordingRequested = false
            if completed && !self.discardRecording {
                self.status("Recording saved. Review the frames before measuring.", self.session.isRunning, false)
                Task { @MainActor in self.onCapture?(outputFileURL) }
            } else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.status(self.discardRecording ? "Recording cancelled." : "Recording failed. \(error?.localizedDescription ?? "Try again.")", self.session.isRunning, false)
            }
        }
    }

    private func status(_ message: String, _ ready: Bool, _ recording: Bool) {
        Task { @MainActor in self.onStatus?(message, ready, recording) }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerView.session = session
        view.layerView.videoGravity = .resizeAspect
        if let connection = view.layerView.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
#endif
