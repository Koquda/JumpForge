import Foundation

struct PoseSignal: Sendable {
    let frameIndex: Int
    let seconds: Double
    let footY: Double
    let centerX: Double
    let bodyHeight: Double
}

enum PoseSignalDetector {
    static func suggestion(_ points: [PoseSignal]) -> JumpSuggestion {
        func abstain(_ reason: String) -> JumpSuggestion {
            JumpSuggestion(takeoffIndex: nil, landingIndex: nil,
                           explanation: reason + " Select the frames manually. Experimental pose hints always require manual review.")
        }
        guard points.count >= 10, points.allSatisfy({ $0.seconds.isFinite && $0.footY.isFinite && $0.centerX.isFinite && $0.bodyHeight > 0 }) else {
            return abstain("There is not enough reliable pose information.")
        }
        for index in 1..<points.count {
            let gap = points[index].seconds - points[index - 1].seconds
            guard gap > 0, gap < 0.12 else { return abstain("Tracking has gaps around the movement.") }
        }
        let heights = points.map(\.bodyHeight).sorted()
        let height = heights[heights.count / 2]
        let xs = points.map(\.centerX)
        guard (xs.max()! - xs.min()!) < 0.15,
              heights.last! / heights.first! < 1.6 else {
            return abstain("Camera motion, athlete movement, or body scale is too unstable.")
        }
        let feet = points.map(\.footY).sorted()
        let baseline = feet[max(0, feet.count / 5)]
        let threshold = height * 0.075
        let elevated = points.map { $0.footY > baseline + threshold }
        var ranges: [Range<Int>] = []
        var start: Int?
        for index in points.indices {
            if elevated[index], start == nil { start = index }
            if !elevated[index], let began = start {
                ranges.append(began..<index)
                start = nil
            }
        }
        if let start { ranges.append(start..<points.count) }
        let candidates = ranges.filter { range in
            guard range.lowerBound >= 3, range.upperBound + 2 < points.count else { return false }
            let length = points[range.upperBound].seconds - points[range.lowerBound - 1].seconds
            let priorGround = points[(range.lowerBound - 3)..<range.lowerBound].allSatisfy { abs($0.footY - baseline) < threshold }
            let afterGround = points[range.upperBound..<(range.upperBound + 3)].allSatisfy { abs($0.footY - baseline) < threshold }
            return length >= 0.10 && length <= 1.5 && priorGround && afterGround
        }
        guard candidates.count == 1, let range = candidates.first else {
            return abstain("One clear jump with grounded frames on both sides could not be isolated.")
        }
        return JumpSuggestion(takeoffIndex: points[range.lowerBound - 1].frameIndex,
                              landingIndex: points[range.upperBound].frameIndex,
                              explanation: "Experimental pose hint from a coarse ankle-rise signal. Manual review is required. These are approximate review positions, not contact detections. Check both feet frame by frame and correct takeoff and landing before using any result. This method is not clinically validated.")
    }
}
