import Foundation
import CoreImage
import CoreML

struct SemanticAnalysis {
    let score: Double
    let label: String
    /// Best matching selected content type, even when a rejection prompt scored higher.
    let theme: HighlightTheme?
    let embedding: [Float]
}

final class MobileCLIPAnalyzer {
    static let modelName = "MobileCLIP-S2"

    private struct Prompt {
        let label: String
        let text: String
        let positive: Bool
        let embedding: [Float]
    }

    private let imageModel: MLModel
    private let prompts: [Prompt]
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(selectedThemes: Set<HighlightTheme>) throws {
        let imageModel = try Self.loadModel(named: "mobileclip_s2_image")
        let textModel = try Self.loadModel(named: "mobileclip_s2_text")
        let tokenizer = try CLIPTokenizer()
        self.imageModel = imageModel

        let selectedDefinitions = HighlightTheme.allCases.compactMap { theme in
            selectedThemes.contains(theme)
                ? (theme.rawValue, theme.mobileCLIPPrompt, true)
                : nil
        }
        let definitions: [(String, String, Bool)] = selectedDefinitions + [
            ("误拍废片", "an accidental blurry unusable video frame", false),
            ("遮挡镜头", "the camera lens is blocked by a hand, bag, or pocket", false),
            // Not "dark frame": night skies and aurora are dark but worth keeping.
            ("空白画面", "a boring empty wall, floor or ceiling, or a completely black frame with nothing visible", false),
            ("屏幕文件", "a screenshot, document, chart, or computer screen", false),
        ]

        prompts = try definitions.map { label, text, positive in
            let tokens = tokenizer.encode(text)
            let input = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (index, token) in tokens.enumerated() { input[index] = NSNumber(value: token) }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "text": MLFeatureValue(multiArray: input)
            ])
            let prediction = try textModel.prediction(from: provider)
            guard let output = prediction.featureValue(for: "final_emb_1")?.multiArrayValue else {
                throw TravelCutError.invalidArguments("MobileCLIP text output is unavailable")
            }
            return Prompt(label: label, text: text, positive: positive, embedding: Self.values(output))
        }
    }

    func analyze(_ image: CGImage) throws -> SemanticAnalysis {
        let buffer = try makePixelBuffer(image)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: buffer)
        ])
        let prediction = try imageModel.prediction(from: provider)
        guard let output = prediction.featureValue(for: "final_emb_1")?.multiArrayValue else {
            throw TravelCutError.invalidArguments("MobileCLIP image output is unavailable")
        }
        let imageEmbedding = Self.values(output)
        let scored = prompts.map { ($0, Self.cosine(imageEmbedding, $0.embedding)) }
        let bestPositive = scored.filter { $0.0.positive }.max { $0.1 < $1.1 }
        let bestNegative = scored.filter { !$0.0.positive }.max { $0.1 < $1.1 }
        let positiveScore = bestPositive?.1 ?? 0
        let negativeScore = bestNegative?.1 ?? 0
        let semanticScore = 1 / (1 + exp(-14 * Double(positiveScore - negativeScore)))
        let label = positiveScore >= negativeScore
            ? (bestPositive?.0.label ?? "旅行画面")
            : (bestNegative?.0.label ?? "低价值画面")
        return SemanticAnalysis(
            score: semanticScore,
            label: label,
            theme: bestPositive.flatMap { HighlightTheme(rawValue: $0.0.label) },
            embedding: imageEmbedding
        )
    }

    private func makePixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        let input = CIImage(cgImage: image)
        let side = min(input.extent.width, input.extent.height)
        let crop = CGRect(
            x: input.extent.midX - side / 2,
            y: input.extent.midY - side / 2,
            width: side,
            height: side
        )
        let cropped = input.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = 256 / side
        let resized = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            nil,
            256,
            256,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw TravelCutError.invalidArguments("无法创建 MobileCLIP 图像缓冲区")
        }
        ciContext.render(
            resized,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: 256, height: 256),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    private static func loadModel(named name: String) throws -> MLModel {
        guard let directory = ModelInstaller.installedDirectory(for: ModelInstaller.mobileCLIP) else {
            throw TravelCutError.modelUnavailable("无法访问 Application Support")
        }
        let packageURL = directory.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw TravelCutError.modelUnavailable("缺少本地模型：\(name)")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let manager = FileManager.default
        let cacheRoot = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TravelCut/MobileCLIP-S2-v1", isDirectory: true)
        let cachedURL = cacheRoot.appendingPathComponent("\(name).mlmodelc", isDirectory: true)

        if manager.fileExists(atPath: cachedURL.path),
           let cachedModel = try? MLModel(contentsOf: cachedURL, configuration: configuration) {
            return cachedModel
        }

        try manager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let temporaryCompiledURL = try MLModel.compileModel(at: packageURL)
        if manager.fileExists(atPath: cachedURL.path) {
            try manager.removeItem(at: cachedURL)
        }
        try manager.copyItem(at: temporaryCompiledURL, to: cachedURL)
        return try MLModel(contentsOf: cachedURL, configuration: configuration)
    }

    private static func values(_ array: MLMultiArray) -> [Float] {
        (0..<array.count).map { array[$0].floatValue }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        var leftMagnitude: Float = 0
        var rightMagnitude: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftMagnitude += lhs[index] * lhs[index]
            rightMagnitude += rhs[index] * rhs[index]
        }
        let denominator = sqrt(leftMagnitude) * sqrt(rightMagnitude)
        return denominator > 0 ? dot / denominator : -1
    }
}
