import AVFoundation
import CoreImage
import Foundation
import Vision

final class VisionAnalyzer {
    private struct FrameResult {
        let score: Double
        let aesthetic: Double
        let technical: Double
        let brightness: Double
        let faceCount: Int
        let faceQuality: Double
        let isUtility: Bool
        let labels: [String]
        let semantic: SemanticAnalysis?
        let featurePrint: VNFeaturePrintObservation?
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let semanticAnalyzer: MobileCLIPAnalyzer?

    init(selectedThemes: Set<HighlightTheme>) {
        semanticAnalyzer = try? MobileCLIPAnalyzer(selectedThemes: selectedThemes)
    }

    var fastModelName: String? {
        semanticAnalyzer == nil ? nil : MobileCLIPAnalyzer.modelName
    }

    func analyze(plan: CandidatePlan, source: SourceVideo) throws -> HighlightCandidate {
        let asset = AVURLAsset(url: source.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 768, height: 768)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.20, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.20, preferredTimescale: 600)

        let offsets: [Double]
        if plan.duration < 2.0 {
            offsets = [0.5]
        } else if plan.duration < 6.0 {
            offsets = [0.25, 0.65]
        } else {
            offsets = [0.18, 0.5, 0.82]
        }

        var results: [FrameResult] = []
        for offset in offsets {
            let requested = plan.start + plan.duration * offset
            var actualTime = CMTime.zero
            guard let image = try? generator.copyCGImage(
                at: CMTime(seconds: requested, preferredTimescale: 600),
                actualTime: &actualTime
            ) else {
                continue
            }
            results.append(analyzeFrame(image))
        }
        guard !results.isEmpty else {
            throw TravelCutError.invalidArguments("无法读取视频画面：\(source.url.lastPathComponent)")
        }

        let representative = results.max { $0.score < $1.score } ?? results[0]
        let meanAesthetic = mean(results.map(\.aesthetic))
        let meanTechnical = mean(results.map(\.technical))
        let meanBrightness = mean(results.map(\.brightness))
        let meanSemantic = mean(results.map { $0.semantic?.score ?? 0.5 })
        let utilityRatio = Double(results.filter(\.isUtility).count) / Double(results.count)
        let faceCount = results.map(\.faceCount).max() ?? 0
        let faceQuality = results.map(\.faceQuality).max() ?? 0
        let faceBonus = faceCount == 0 ? 0 : min(1, 0.45 + faceQuality * 0.55)
        let labels = Array(Set(results.flatMap(\.labels))).prefix(8)
        let semanticLabel = results
            .compactMap(\.semantic)
            .max { $0.score < $1.score }?.label ?? "旅行画面"
        var score = meanAesthetic * 0.31
            + meanTechnical * 0.24
            + meanSemantic * 0.30
            + faceBonus * 0.10
            + semanticTravelBonus(Array(labels)) * 0.05
        if utilityRatio >= 0.5 { score -= 0.35 }
        if meanBrightness < 0.035 || meanBrightness > 0.965 { score -= 0.45 }

        return HighlightCandidate(
            source: source,
            sourceIndex: plan.sourceIndex,
            start: plan.start,
            duration: plan.duration,
            score: score,
            aestheticScore: meanAesthetic,
            technicalScore: meanTechnical,
            brightness: meanBrightness,
            faceCount: faceCount,
            faceQuality: faceQuality,
            isUtilityImage: utilityRatio >= 0.5,
            labels: Array(labels),
            semanticScore: meanSemantic,
            semanticLabel: semanticLabel,
            featurePrint: representative.featurePrint,
            semanticEmbedding: representative.semantic?.embedding
        )
    }

    private func analyzeFrame(_ image: CGImage) -> FrameResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let facesRequest = VNDetectFaceCaptureQualityRequest()
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        featureRequest.revision = VNGenerateImageFeaturePrintRequestRevision2
        let classifyRequest = VNClassifyImageRequest()
        var aesthetic = 0.5
        var isUtility = false

        perform([facesRequest], name: "人脸分析", with: handler)
        perform([featureRequest], name: "画面特征", with: handler)
        perform([classifyRequest], name: "画面分类", with: handler)
        if #available(macOS 15.0, *) {
            let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
            perform([aestheticsRequest], name: "审美分析", with: handler)
            if let observation = aestheticsRequest.results?.first {
                aesthetic = min(1, max(0, (Double(observation.overallScore) + 1) / 2))
                isUtility = observation.isUtility
            }
        }

        let faces = facesRequest.results ?? []
        let bestFaceQuality = faces.compactMap { $0.faceCaptureQuality.map(Double.init) }.max() ?? 0
        let labels = (classifyRequest.results ?? [])
            .filter { $0.confidence >= 0.12 }
            .prefix(6)
            .map(\.identifier)
        let brightness = averageBrightness(of: image)
        let sharpness = edgeSharpness(of: image)
        let exposure = min(1, max(0, 1 - abs(brightness - 0.52) / 0.52))
        let technical = 0.62 * sharpness + 0.38 * exposure
        let semantic = semanticAnalyzer.flatMap { try? $0.analyze(image) }
        let frameScore = aesthetic * 0.38
            + technical * 0.27
            + (semantic?.score ?? 0.5) * 0.35

        return FrameResult(
            score: frameScore,
            aesthetic: aesthetic,
            technical: technical,
            brightness: brightness,
            faceCount: faces.count,
            faceQuality: bestFaceQuality,
            isUtility: isUtility,
            labels: labels,
            semantic: semantic,
            featurePrint: featureRequest.results?.first
        )
    }

    private func averageBrightness(of image: CGImage) -> Double {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0.5 }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return 0.5 }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let red = Double(pixel[0]) / 255
        let green = Double(pixel[1]) / 255
        let blue = Double(pixel[2]) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func edgeSharpness(of image: CGImage) -> Double {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0.5
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        var total = 0.0
        var count = 0
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let center = Int(pixels[y * size + x]) * 4
                let neighbors = Int(pixels[(y - 1) * size + x])
                    + Int(pixels[(y + 1) * size + x])
                    + Int(pixels[y * size + x - 1])
                    + Int(pixels[y * size + x + 1])
                total += abs(Double(center - neighbors)) / 1020.0
                count += 1
            }
        }
        guard count > 0 else { return 0.5 }
        return min(1, (total / Double(count)) * 14)
    }

    private func semanticTravelBonus(_ labels: [String]) -> Double {
        let text = labels.joined(separator: " ").lowercased()
        let keywords = [
            "landscape", "mountain", "beach", "ocean", "lake", "river", "waterfall",
            "sunset", "sunrise", "sky", "architecture", "building", "street", "city",
            "food", "meal", "people", "person", "animal", "garden", "forest", "snow",
        ]
        return keywords.contains(where: text.contains) ? 1 : 0.35
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(1, values.count))
    }

    private func perform(_ requests: [VNRequest], name: String, with handler: VNImageRequestHandler) {
        do {
            try handler.perform(requests)
        } catch {
            for request in requests { request.usesCPUOnly = true }
            if (try? handler.perform(requests)) != nil { return }
            if ProcessInfo.processInfo.environment["TRAVELCUT_DEBUG"] == "1" {
                FileHandle.standardError.write(Data("Vision \(name) unavailable: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
