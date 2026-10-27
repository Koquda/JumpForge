import AVFoundation
import CoreGraphics
import CoreText
import Foundation

@main
struct GenerateFixture {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/JumpForge-timing-fixture.mov")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "JumpForge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a new output path."])
        }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 480,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 120, AVVideoAllowFrameReorderingKey: false]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 480,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<240 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32ARGB, nil, &buffer)
            guard result == kCVReturnSuccess, let buffer else { throw NSError(domain: "Fixture", code: 2) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 480, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            context.setFillColor(CGColor(gray: 0.22, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 65))
            let airborne = index >= 60 && index < 120
            let phase = Double(index - 59) / 61
            let rise = airborne ? 125 * sin(.pi * phase) : 0
            context.setStrokeColor(CGColor(red: 0.78, green: 0.98, blue: 0.3, alpha: 1))
            context.setLineWidth(12)
            context.setLineCap(.round)
            let ankle = 71 + rise
            context.move(to: CGPoint(x: 300, y: ankle)); context.addLine(to: CGPoint(x: 310, y: ankle + 65))
            context.addLine(to: CGPoint(x: 320, y: ankle + 135)); context.addLine(to: CGPoint(x: 330, y: ankle + 65)); context.addLine(to: CGPoint(x: 340, y: ankle))
            context.move(to: CGPoint(x: 320, y: ankle + 135)); context.addLine(to: CGPoint(x: 320, y: ankle + 215))
            context.move(to: CGPoint(x: 270, y: ankle + 165)); context.addLine(to: CGPoint(x: 320, y: ankle + 190)); context.addLine(to: CGPoint(x: 370, y: ankle + 165))
            context.strokePath()
            context.strokeEllipse(in: CGRect(x: 303, y: ankle + 219, width: 34, height: 34))
            let font = CTFontCreateWithName("Menlo" as CFString, 16, nil)
            let text = "SYNTHETIC TIMING FIXTURE | Frame \(index) | 120 fps"
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)]
            context.textPosition = CGPoint(x: 16, y: 445)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 120)) else { throw writer.error! }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        print("Created \(output.path). Synthetic first airborne sample 60; first contact sample 120. This tests timing, not real-athlete accuracy.")
    }
}
