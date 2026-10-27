@preconcurrency import AVFoundation
@preconcurrency import Vision
import CoreImage
import CoreGraphics
import Foundation
import JumpCore

public struct IndexedVideo: Sendable {
    public let frames: [FrameStamp]
    public let nominalFrameRate: Double
    public let durationSeconds: Double
    public let isRetimed: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(frames: [FrameStamp], nominalFrameRate: Double, durationSeconds: Double,
                isRetimed: Bool, pixelWidth: Int, pixelHeight: Int) {
        self.frames = frames
        self.nominalFrameRate = nominalFrameRate
        self.durationSeconds = durationSeconds
        self.isRetimed = isRetimed
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct JumpSuggestion: Sendable {
    public let takeoffIndex: Int?
    public let landingIndex: Int?
    public let explanation: String

    public init(takeoffIndex: Int?, landingIndex: Int?, explanation: String) {
        self.takeoffIndex = takeoffIndex
        self.landingIndex = landingIndex
        self.explanation = explanation
    }
}

public enum VideoError: LocalizedError {
    case missingVideo, unreadable, excessiveDuration, excessiveSamples, invalidTiming, frameMissing
    public var errorDescription: String? {
        switch self {
        case .missingVideo: "The file does not contain a readable video track."
        case .unreadable: "The video could not be decoded. Try an original camera recording."
        case .excessiveDuration: "Choose a clip that is at most 120 seconds long."
        case .excessiveSamples: "The clip contains more than 30,000 frames. Trim it first."
        case .invalidTiming: "The video has invalid or ambiguous frame timestamps."
        case .frameMissing: "That exact frame is no longer available in this video."
        }
    }
}

public actor VideoService {
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var imageCache: [(ImageKey, CGImage)] = []
    private var imageCacheBytes = 0
    private var decodeStream: DecodeStream?
    public init() {}

    public func index(url: URL) async throws -> IndexedVideo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw VideoError.invalidTiming }
        guard duration.seconds <= 120.001 else { throw VideoError.excessiveDuration }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.missingVideo
        }
        let nominal = try await track.load(.nominalFrameRate)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let segments = try await track.load(.segments)
        let retimed = segments.contains { segment in
            let mapping = segment.timeMapping
            guard !segment.isEmpty, mapping.source.duration.isNumeric,
                  mapping.target.duration.isNumeric else { return false }
            return CMTimeCompare(mapping.source.duration, mapping.target.duration) != 0
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw VideoError.unreadable }
        defer { reader.cancelReading() }
        var frames: [FrameStamp] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard frames.count < 30_000 else { throw VideoError.excessiveSamples }
            // Compressed samples can contain multiple timing entries. Keep every presentation timestamp.
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            for offset in 0..<count {
                var timing = CMSampleTimingInfo()
                let status = CMSampleBufferGetSampleTimingInfo(sample, at: offset, timingInfoOut: &timing)
                guard status == noErr, timing.presentationTimeStamp.isNumeric,
                      timing.presentationTimeStamp.timescale > 0 else { throw VideoError.invalidTiming }
                guard frames.count < 30_000 else { throw VideoError.excessiveSamples }
                let time = timing.presentationTimeStamp
                frames.append(FrameStamp(index: frames.count, value: time.value, timescale: time.timescale))
            }
        }
        guard reader.status == .completed, !frames.isEmpty else { throw VideoError.unreadable }
        frames.sort { CMTimeCompare(Self.time($0), Self.time($1)) < 0 }
        frames = frames.enumerated().map { FrameStamp(index: $0.offset, value: $0.element.value, timescale: $0.element.timescale) }
        for index in 1..<frames.count {
            guard CMTimeCompare(Self.time(frames[index - 1]), Self.time(frames[index])) < 0 else {
                throw VideoError.invalidTiming
            }
        }
        guard let first = frames.first, let last = frames.last,
              last.seconds - first.seconds <= 120.001 else { throw VideoError.excessiveDuration }
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        return IndexedVideo(frames: frames, nominalFrameRate: Double(nominal),
                            durationSeconds: duration.seconds, isRetimed: retimed,
                            pixelWidth: Int(abs(oriented.width).rounded()),
                            pixelHeight: Int(abs(oriented.height).rounded()))
    }

    public func image(url: URL, frame: FrameStamp) async throws -> CGImage {
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let source = ImageSource(url: url, modified: attributes.contentModificationDate, size: attributes.fileSize)
        let key = ImageKey(source: source, value: frame.value, timescale: frame.timescale)
        if let index = imageCache.firstIndex(where: { $0.0 == key }) {
            let entry = imageCache.remove(at: index)
            imageCache.append(entry)
            return entry.1
        }
        let requested = Self.time(frame)
        let stream: DecodeStream
        if let existing = decodeStream, existing.source == source,
           let previous = existing.lastTime, CMTimeCompare(previous, requested) < 0,
           existing.reader.status == .reading {
            stream = existing
        } else {
            decodeStream?.reader.cancelReading()
            decodeStream = nil
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else { throw VideoError.invalidTiming }
            guard duration.seconds <= 120.001 else { throw VideoError.excessiveDuration }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.missingVideo }
            let transform = try await track.load(.preferredTransform)
            let (reader, output) = try Self.decodedReader(asset: asset, track: track)
            stream = DecodeStream(source: source, reader: reader, output: output, transform: transform)
            decodeStream = stream
        }
        do {
            while let sample = stream.output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                stream.count += 1
                guard stream.count <= 30_000 else { throw VideoError.excessiveSamples }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                stream.lastTime = pts
                if CMTimeCompare(pts, requested) == 0, let buffer = CMSampleBufferGetImageBuffer(sample) {
                    let oriented = CIImage(cvPixelBuffer: buffer).transformed(by: stream.transform)
                    guard let result = imageContext.createCGImage(oriented, from: oriented.extent) else { throw VideoError.unreadable }
                    cache(result, key: key)
                    return result
                }
            }
            guard stream.reader.status == .completed else { throw VideoError.unreadable }
            throw VideoError.frameMissing
        } catch {
            stream.reader.cancelReading()
            if decodeStream === stream { decodeStream = nil }
            throw error
        }
    }

    private func cache(_ image: CGImage, key: ImageKey) {
        let bytes = image.bytesPerRow * image.height
        let limit = 64 * 1024 * 1024
        guard bytes <= limit else { return }
        while !imageCache.isEmpty && (imageCache.count >= 6 || imageCacheBytes + bytes > limit) {
            let removed = imageCache.removeFirst().1
            imageCacheBytes -= removed.bytesPerRow * removed.height
        }
        imageCache.append((key, image))
        imageCacheBytes += bytes
    }

    public func suggest(url: URL, indexed: IndexedVideo) async throws -> JumpSuggestion {
        guard !indexed.isRetimed else { return Self.abstain("The clip has source-to-playback retiming. Use an original recording.") }
        guard indexed.durationSeconds <= 120, indexed.frames.count <= 30_000, !indexed.frames.isEmpty else {
            return Self.abstain("The clip is outside the analysis limits.")
        }
        let asset = AVURLAsset(url: url)
        let actualDuration = try await asset.load(.duration)
        guard actualDuration.isNumeric, actualDuration.seconds > 0 else { throw VideoError.invalidTiming }
        guard actualDuration.seconds <= 120.001 else { throw VideoError.excessiveDuration }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.missingVideo }
        let transform = try await track.load(.preferredTransform)
        let (reader, output) = try Self.decodedReader(asset: asset, track: track)
        defer { reader.cancelReading() }
        let context = imageContext
        var points: [PoseSignal] = []
        var nextTime = -Double.infinity
        var count = 0
        var missing = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            count += 1
            guard count <= 30_000 else { throw VideoError.excessiveSamples }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric else { throw VideoError.invalidTiming }
            guard pts.seconds >= nextTime else { continue }
            nextTime = pts.seconds + 1.0 / 30.0
            guard let frameIndex = Self.frameIndex(at: pts, frames: indexed.frames),
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.invalidTiming }
            let signal: PoseSignal? = try autoreleasepool {
                let oriented = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                guard let image = context.createCGImage(oriented, from: oriented.extent) else { throw VideoError.unreadable }
                let request = VNDetectHumanBodyPoseRequest()
                try VNImageRequestHandler(cgImage: image).perform([request])
                guard let observations = request.results, observations.count == 1 else { return nil }
                return Self.signal(observations[0], frame: frameIndex, seconds: pts.seconds)
            }
            guard let signal else { missing += 1; continue }
            points.append(signal)
        }
        guard reader.status == .completed else { throw VideoError.unreadable }
        guard missing <= 2, points.count >= 10 else {
            return Self.abstain("A single athlete with both feet fully visible could not be tracked consistently.")
        }
        return PoseSignalDetector.suggestion(points)
    }

    private static func signal(_ pose: VNHumanBodyPoseObservation, frame: Int, seconds: Double) -> PoseSignal? {
        guard let points = try? pose.recognizedPoints(.all) else { return nil }
        let names: [VNHumanBodyPoseObservation.JointName] = [.leftAnkle, .rightAnkle, .leftHip, .rightHip, .leftShoulder, .rightShoulder]
        guard names.allSatisfy({ name in
            guard let point = points[name] else { return false }
            return point.confidence >= 0.6 && point.x > 0.025 && point.x < 0.975 && point.y > 0.04 && point.y < 0.98
        }) else { return nil }
        let left = points[.leftAnkle]!, right = points[.rightAnkle]!
        let shoulderY = (points[.leftShoulder]!.y + points[.rightShoulder]!.y) / 2
        let ankleY = (left.y + right.y) / 2
        let height = shoulderY - ankleY
        guard height > 0.2, abs(left.y - right.y) < height * 0.16 else { return nil }
        return PoseSignal(frameIndex: frame, seconds: seconds, footY: ankleY,
                          centerX: (left.x + right.x) / 2, bodyHeight: height)
    }

    private static func abstain(_ reason: String) -> JumpSuggestion {
        JumpSuggestion(takeoffIndex: nil, landingIndex: nil,
                       explanation: reason + " Select takeoff and landing manually. Pose hints are experimental and require manual review.")
    }

    private static func frameIndex(at time: CMTime, frames: [FrameStamp]) -> Int? {
        var lower = 0
        var upper = frames.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let comparison = CMTimeCompare(Self.time(frames[middle]), time)
            if comparison == 0 { return middle }
            if comparison < 0 { lower = middle + 1 } else { upper = middle }
        }
        return nil
    }

    private static func time(_ frame: FrameStamp) -> CMTime { CMTime(value: frame.value, timescale: frame.timescale) }

    private static func decodedReader(asset: AVAsset, track: AVAssetTrack) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw VideoError.unreadable }
        return (reader, output)
    }
}

private struct ImageSource: Hashable {
    let url: URL
    let modified: Date?
    let size: Int?
}

private struct ImageKey: Hashable {
    let source: ImageSource
    let value: Int64
    let timescale: Int32
}

private final class DecodeStream {
    let source: ImageSource
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let transform: CGAffineTransform
    var lastTime: CMTime?
    var count = 0

    init(source: ImageSource, reader: AVAssetReader, output: AVAssetReaderTrackOutput, transform: CGAffineTransform) {
        self.source = source
        self.reader = reader
        self.output = output
        self.transform = transform
    }

    deinit { reader.cancelReading() }
}
