import AVFoundation
import CoreGraphics
import Foundation

public enum EventSegmenter {
    private struct FrameSignature {
        let time: TimeInterval
        let histogram: [Double]
    }

    public static func segment(
        sources: [SourceVideo],
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> [CandidatePlan] {
        var result: [CandidatePlan] = []
        for (index, source) in sources.enumerated() {
            if Task.isCancelled { break }
            let boundaries = detectSceneBoundaries(in: source)
            result.append(contentsOf: plans(
                sourceIndex: index,
                duration: source.duration,
                sceneBoundaries: boundaries
            ))
            progress(index + 1, sources.count)
        }
        return result
    }

    public static func plans(
        sourceIndex: Int,
        duration: TimeInterval,
        sceneBoundaries: [TimeInterval]
    ) -> [CandidatePlan] {
        guard duration >= 0.1 else { return [] }
        let minimumEventDuration = 0.25
        let analysisChunkDuration = 45.0
        let overlap = 3.0

        let validBoundaries = sceneBoundaries
            .filter { $0 >= minimumEventDuration && $0 <= duration - minimumEventDuration }
            .sorted()
        let uniqueBoundaries = validBoundaries.reduce(into: [TimeInterval]()) { values, boundary in
            if let last = values.last, boundary - last < minimumEventDuration {
                return
            }
            values.append(boundary)
        }

        var naturalRanges: [(TimeInterval, TimeInterval)] = []
        var start: TimeInterval = 0
        for boundary in uniqueBoundaries {
            naturalRanges.append((start, boundary))
            start = boundary
        }
        naturalRanges.append((start, duration))

        var plans: [CandidatePlan] = []
        for (rangeStart, rangeEnd) in naturalRanges {
            let rangeDuration = rangeEnd - rangeStart
            guard rangeDuration >= 0.1 else { continue }
            if rangeDuration <= analysisChunkDuration {
                plans.append(CandidatePlan(
                    sourceIndex: sourceIndex,
                    start: rangeStart,
                    duration: rangeDuration
                ))
                continue
            }

            var chunkStart = rangeStart
            while chunkStart < rangeEnd - 0.1 {
                let chunkEnd = min(rangeEnd, chunkStart + analysisChunkDuration)
                plans.append(CandidatePlan(
                    sourceIndex: sourceIndex,
                    start: chunkStart,
                    duration: chunkEnd - chunkStart
                ))
                if chunkEnd >= rangeEnd { break }
                chunkStart = max(chunkStart + 1, chunkEnd - overlap)
            }
        }
        return plans
    }

    private static func detectSceneBoundaries(in source: SourceVideo) -> [TimeInterval] {
        guard source.duration > 2 else { return [] }
        let asset = AVURLAsset(url: source.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)

        let interval = max(0.5, min(2.5, source.duration / 180.0))
        var signatures: [FrameSignature] = []
        var time = min(0.25, source.duration / 2)
        while time < source.duration - 0.1 {
            if Task.isCancelled { break }
            var actual = CMTime.zero
            if let image = try? generator.copyCGImage(
                at: CMTime(seconds: time, preferredTimescale: 600),
                actualTime: &actual
            ), let histogram = histogram(for: image) {
                signatures.append(FrameSignature(time: actual.seconds, histogram: histogram))
            }
            time += interval
        }

        guard signatures.count >= 2 else { return [] }
        var boundaries: [TimeInterval] = []
        for index in 1..<signatures.count {
            let previous = signatures[index - 1]
            let current = signatures[index]
            if histogramDistance(previous.histogram, current.histogram) >= 0.34 {
                boundaries.append((previous.time + current.time) / 2)
            }
        }
        return boundaries
    }

    private static func histogram(for image: CGImage) -> [Double]? {
        let width = 24
        let height = 24
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bins = 16
        var histogram = [Double](repeating: 0, count: bins * 3)
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            histogram[Int(pixels[offset]) * bins / 256] += 1
            histogram[bins + Int(pixels[offset + 1]) * bins / 256] += 1
            histogram[bins * 2 + Int(pixels[offset + 2]) * bins / 256] += 1
        }
        let scale = Double(width * height)
        return histogram.map { $0 / scale }
    }

    private static func histogramDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        return zip(lhs, rhs).reduce(0) { $0 + abs($1.0 - $1.1) } / 6.0
    }
}
