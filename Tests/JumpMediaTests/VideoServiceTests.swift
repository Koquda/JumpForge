@preconcurrency import AVFoundation
import CoreVideo
import JumpCore
import Testing
@testable import JumpMedia

@MainActor struct VideoServiceTests {
    @Test func testActual120FPSTimestampsAndExactDecodedImage() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let service = VideoService()
        let indexed = try await service.index(url: url)
        #expect(indexed.frames.count == 12)
        #expect(indexed.pixelWidth == 64)
        #expect(indexed.pixelHeight == 64)
        #expect(!indexed.isRetimed)
        for (offset, frame) in indexed.frames.enumerated() {
            #expect(abs(frame.seconds - Double(offset) / 120) < 0.000_001)
            #expect(frame.timescale > 0)
        }
        let first = try await service.image(url: url, frame: indexed.frames[0])
        let last = try await service.image(url: url, frame: indexed.frames[11])
        #expect(first.width == 64)
        #expect(last.height == 64)
        #expect(try brightness(first) < brightness(last))
        do {
            _ = try await service.image(url: url, frame: FrameStamp(index: 0, value: 1, timescale: 999))
            Issue.record("A nearby timestamp must never substitute for an exact frame.")
        } catch VideoError.frameMissing {}
    }

    @Test func testTrackRotationIsAppliedToIndexAndDecodedImage() async throws {
        let url = try await makeVideo(height: 32, rotated: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = VideoService()
        let indexed = try await service.index(url: url)
        #expect(indexed.pixelWidth == 32)
        #expect(indexed.pixelHeight == 64)
        let image = try await service.image(url: url, frame: indexed.frames[5])
        #expect(image.width == 32)
        #expect(image.height == 64)
        let repeated = try await service.image(url: url, frame: indexed.frames[5])
        #expect(repeated === image)
    }

    @Test func testCorruptVideoIsRejected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("This is not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await VideoService().index(url: url)
            Issue.record("A corrupt video must fail.")
        } catch {}
    }

    @Test func testPoseHintIsBoundedAndRequiresReview() {
        let result = PoseSignalDetector.suggestion(signals())
        #expect(result.takeoffIndex == 4)
        #expect(result.landingIndex == 12)
        #expect(result.explanation.localizedCaseInsensitiveContains("manual review"))
    }

    @Test func testPoseAbstainsForGroundedOrMovingAthlete() {
        let grounded = signals().map { PoseSignal(frameIndex: $0.frameIndex, seconds: $0.seconds, footY: 0.1, centerX: 0.5, bodyHeight: 0.6) }
        #expect(PoseSignalDetector.suggestion(grounded).takeoffIndex == nil)
        let moving = signals().map { PoseSignal(frameIndex: $0.frameIndex, seconds: $0.seconds, footY: $0.footY, centerX: Double($0.frameIndex) / 20, bodyHeight: 0.6) }
        #expect(PoseSignalDetector.suggestion(moving).takeoffIndex == nil)
        #expect(PoseSignalDetector.suggestion(Array(signals().prefix(10))).takeoffIndex == nil)
    }

    private func signals() -> [PoseSignal] {
        (0..<20).map { index in
            PoseSignal(frameIndex: index, seconds: Double(index) / 30,
                       footY: (5..<12).contains(index) ? 0.24 : 0.1,
                       centerX: 0.5, bodyHeight: 0.6)
        }
    }

    private func brightness(_ image: CGImage) throws -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VideoError.unreadable
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel[0])
    }

    private func makeVideo(height: Int = 64, rotated: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 120, AVVideoMaxKeyFrameIntervalKey: 1]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: height
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoError.unreadable }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            var attempts = 0
            while !input.isReadyForMoreMediaData {
                attempts += 1
                guard attempts < 5000, writer.status == .writing else { throw writer.error ?? VideoError.unreadable }
                try await Task.sleep(for: .milliseconds(1))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, height, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw VideoError.unreadable }
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<64 {
                    let offset = y * stride + x * 4
                    bytes[offset] = 255
                    bytes[offset + 1] = UInt8(index * 20)
                    bytes[offset + 2] = UInt8(index * 20)
                    bytes[offset + 3] = UInt8(index * 20)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 120)) else { throw writer.error ?? VideoError.unreadable }
        }
        writer.endSession(atSourceTime: CMTime(value: 12, timescale: 120))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoError.unreadable }
        return url
    }
}
