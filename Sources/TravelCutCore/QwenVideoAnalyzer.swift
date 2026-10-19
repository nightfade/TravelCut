import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor QwenVideoAnalyzer {
    static let modelName = "Qwen3-VL-4B-Instruct Q4_K_M"

    private struct Response: Decodable {
        let keep: Bool
        let highlightScore: Double
        let qualityScore: Double
        let completenessScore: Double
        let label: String
        let reason: String
        let theme: String?
        let start: Double?
        let end: Double?

        enum CodingKeys: String, CodingKey {
            case keep
            case highlightScore = "highlight_score"
            case qualityScore = "quality_score"
            case completenessScore = "completeness_score"
            case label
            case reason
            case theme
            case start
            case end
        }
    }

    private let modelFilename = "Qwen3VL-4B-Instruct-Q4_K_M.gguf"
    private let projectorFilename = "mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf"
    private var modelDirectory: URL?

    func load(progress: @Sendable @escaping (Double) -> Void) async throws {
        if modelDirectory != nil {
            progress(1)
            return
        }
        modelDirectory = try await ModelInstaller(ModelInstaller.qwen).install(progress: progress)
        _ = try runtimeExecutable()
    }

    func analyze(
        candidate: HighlightCandidate,
        frameCount: Int,
        selectedThemes: Set<HighlightTheme>
    ) async throws -> DeepAnalysisResult {
        guard let modelDirectory else {
            throw TravelCutError.modelUnavailable("模型尚未安装")
        }
        let temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TravelCut-Qwen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryFolder) }

        let frames = try makeFrameFiles(
            for: candidate,
            count: frameCount,
            folder: temporaryFolder
        )
        guard !frames.isEmpty else {
            throw TravelCutError.invalidArguments("无法读取候选片段的分析帧")
        }

        let timestamps = frames.enumerated().map { index, frame in
            "第\(index + 1)帧=\(formatted(frame.time))秒"
        }.joined(separator: "，")
        let orderedThemes = HighlightTheme.allCases.filter(selectedThemes.contains)
        let themeGuidance = orderedThemes
            .map(\.qwenGuidance)
            .joined(separator: "；")
        let prompt = """
        你是旅行视频高光剪辑师。以下图片按时间顺序取自同一候选视频，候选长度为 \(formatted(candidate.duration)) 秒。
        时间对应关系：\(timestamps)。同期现场声分类：\(candidate.audioLabels.isEmpty ? "没有可靠结果" : candidate.audioLabels.joined(separator: ", "))。
        用户主动选择了以下想保留的内容：\(themeGuidance)。只把与至少一种已选内容明显相关的片段作为候选高光。
        判断它是否值得作为独立片段交给剪映模板。重视旅途记录价值、事件或景观变化、情绪、动作完整性、画面质量和镜头稳定性。
        对清晰稳定且符合已选内容的片段应倾向保留，不要求罕见或戏剧化；尤其不得仅因沿途风景常见而拒绝它。
        明显误拍、遮挡、严重失焦、无有效内容或与已选内容无关时拒绝。起止时间围绕自然事件，不要求固定长度。
        label 必须是2到8个汉字，reason 必须使用中文且不超过30个汉字。
        theme 从这些内容类型中选一个最贴切的：\(orderedThemes.map(\.rawValue).joined(separator: "、"))。
        只输出 JSON。分数范围 0 到 1。start 和 end 是相对此候选片段的秒数；去掉举机、收机、明显晃动和事件结束后的空白，
        但保留动作、对话或景观变化的完整过程。整段都应保留时，start=0、end=\(formatted(candidate.duration))。
        """
        let imageArgument = frames.map(\.url.path).joined(separator: ",")
        let executable = try runtimeExecutable()
        let output = try await run(
            executable: executable,
            workingDirectory: executable.deletingLastPathComponent(),
            arguments: [
                "-m", modelDirectory.appendingPathComponent(modelFilename).path,
                "--mmproj", modelDirectory.appendingPathComponent(projectorFilename).path,
                "--image", imageArgument,
                "-p", prompt,
                "--json-schema", Self.responseSchema(themes: orderedThemes),
                "--temp", "0",
                "-n", "384",
                "-c", "8192",
                "--cache-type-k", "q8_0",
                "--cache-type-v", "q8_0",
                "--image-max-tokens", "384",
                "--gpu-layers", "all",
                "--fit", "on",
                "--fit-target", "2048",
                "--no-warmup",
                "--no-perf",
                "--log-verbosity", "1",
            ]
        )
        if TravelCutLog.isEnabled {
            TravelCutLog.write(Data("QWEN RAW:\n\(output)\n".utf8))
        }
        return try parse(output, duration: candidate.duration, allowedThemes: orderedThemes)
    }

    /// Picks the best of a few near-identical photos and judges whether the group is worth keeping.
    func judgePhotoGroup(
        images: [URL],
        selectedThemes: Set<HighlightTheme>,
        place: String? = nil
    ) async throws -> PhotoGroupJudgement {
        guard let modelDirectory else {
            throw TravelCutError.modelUnavailable("模型尚未安装")
        }
        let orderedThemes = HighlightTheme.allCases.filter(selectedThemes.contains)
        let count = images.count
        let prompt = """
        你是旅行摄影的选片编辑。以下 \(count) 张照片按顺序编号为 1 到 \(count)，是同一场景连拍或接连拍下的。\(place.map { "拍摄地点在\($0)，label 里如果能认出具体的地标或场所，请用它的名字。" } ?? "")
        用户想保留的内容：\(orderedThemes.map(\.qwenGuidance).joined(separator: "；"))。
        best 填最值得保留的那一张的编号：优先主体清晰对焦、人物没有闭眼且表情自然、构图完整、曝光可用。
        keep 判断这组照片是否值得作为这次旅行的照片保留；清晰且有记录价值的日常旅途画面也应保留，只有明显无内容、
        误拍或与已选内容无关时才为 false。highlight_score 是这组最佳照片的出彩程度，0 到 1，普通但可用约 0.5，
        让人眼前一亮的约 0.85 以上。theme 从这些内容类型中选一个最贴切的：\(orderedThemes.map(\.rawValue).joined(separator: "、"))。
        label 必须是2到8个汉字，reason 必须使用中文且不超过30个汉字。只输出 JSON。
        """
        let executable = try runtimeExecutable()
        let output = try await run(
            executable: executable,
            workingDirectory: executable.deletingLastPathComponent(),
            arguments: [
                "-m", modelDirectory.appendingPathComponent(modelFilename).path,
                "--mmproj", modelDirectory.appendingPathComponent(projectorFilename).path,
                "--image", images.map(\.path).joined(separator: ","),
                "-p", prompt,
                "--json-schema", Self.photoSchema(count: count, themes: orderedThemes),
                "--temp", "0",
                "-n", "256",
                "-c", "8192",
                "--cache-type-k", "q8_0",
                "--cache-type-v", "q8_0",
                "--image-max-tokens", "384",
                "--gpu-layers", "all",
                "--fit", "on",
                "--fit-target", "2048",
                "--no-warmup",
                "--no-perf",
                "--log-verbosity", "1",
            ],
            timeout: 180
        )
        if TravelCutLog.isEnabled {
            TravelCutLog.write(Data("QWEN PHOTO RAW:\n\(output)\n".utf8))
        }
        guard let first = output.firstIndex(of: "{"), let last = output.lastIndex(of: "}"), first <= last,
              let data = String(output[first...last]).data(using: .utf8),
              let response = try? JSONDecoder().decode(PhotoResponse.self, from: data)
        else { throw TravelCutError.modelResponseInvalid }
        let best = (1...count).contains(response.best) ? response.best - 1 : nil
        return PhotoGroupJudgement(
            bestMember: best,
            keep: response.keep,
            highlightScore: min(1, max(0, response.highlightScore)),
            theme: HighlightTheme(rawValue: response.theme).flatMap { orderedThemes.contains($0) ? $0 : nil },
            label: sanitizeLabel(response.label),
            reason: response.reason
        )
    }

    private struct PhotoResponse: Decodable {
        let keep: Bool
        let best: Int
        let highlightScore: Double
        let theme: String
        let label: String
        let reason: String

        enum CodingKeys: String, CodingKey {
            case keep, best, theme, label, reason
            case highlightScore = "highlight_score"
        }
    }

    static func photoSchema(count: Int, themes: [HighlightTheme]) -> String {
        let names = (themes.isEmpty ? HighlightTheme.allCases : themes).map { "\"\($0.rawValue)\"" }
        let indices = (1...max(1, count)).map(String.init).joined(separator: ",")
        return """
        {"type":"object","properties":{"keep":{"type":"boolean"},"best":{"type":"integer","enum":[\(indices)]},\
        "highlight_score":{"type":"number"},"theme":{"type":"string","enum":[\(names.joined(separator: ","))]},\
        "label":{"type":"string","maxLength":12},"reason":{"type":"string","maxLength":48}},\
        "required":["keep","best","highlight_score","theme","label","reason"],"additionalProperties":false}
        """
    }

    private func makeFrameFiles(
        for candidate: HighlightCandidate,
        count requestedCount: Int,
        folder: URL
    ) throws -> [(url: URL, time: TimeInterval)] {
        let count = max(2, min(16, requestedCount))
        let asset = AVURLAsset(url: candidate.source.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        var frames: [(URL, TimeInterval)] = []
        for index in 0..<count {
            let ratio = count == 1 ? 0.5 : Double(index) / Double(count - 1)
            let relativeTime = min(
                max(0, candidate.duration - 0.05),
                max(0, 0.05 + (candidate.duration - 0.10) * ratio)
            )
            var actualTime = CMTime.zero
            guard let image = try? generator.copyCGImage(
                at: CMTime(
                    seconds: candidate.start + relativeTime,
                    preferredTimescale: 600
                ),
                actualTime: &actualTime
            ) else {
                continue
            }
            let url = folder.appendingPathComponent(
                String(format: "frame-%02d-%06.2fs.jpg", index + 1, relativeTime)
            )
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                continue
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
            )
            if CGImageDestinationFinalize(destination) {
                frames.append((url, relativeTime))
            }
        }
        return frames
    }

    private func runtimeExecutable() throws -> URL {
        let manager = FileManager.default
        var directories: [URL] = []
        if let override = ProcessInfo.processInfo.environment["TRAVELCUT_LLAMA_DIR"] {
            directories.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        directories.append(
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama", isDirectory: true)
        )
        directories.append(
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("llama", isDirectory: true)
        )
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        directories.append(sourceRoot.appendingPathComponent("Resources/llama", isDirectory: true))

        for directory in directories {
            let executable = directory.appendingPathComponent("llama-mtmd-cli")
            if manager.isExecutableFile(atPath: executable.path) { return executable }
        }
        throw TravelCutError.modelUnavailable("应用中缺少 llama.cpp 推理组件")
    }

    private func run(
        executable: URL,
        workingDirectory: URL,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = workingDirectory
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    if let timeout {
                        // A stuck inference (e.g. under memory pressure) must not stall the whole batch.
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                            if process.isRunning { process.terminate() }
                        }
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errors = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard status == 0 else {
            let message = String(data: errors, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TravelCutError.modelUnavailable(
                message?.isEmpty == false ? message! : "本地推理失败"
            )
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    private func parse(
        _ raw: String,
        duration: TimeInterval,
        allowedThemes: [HighlightTheme]
    ) throws -> DeepAnalysisResult {
        guard let first = raw.firstIndex(of: "{"),
              let last = raw.lastIndex(of: "}"),
              first <= last
        else {
            throw TravelCutError.modelResponseInvalid
        }
        let json = String(raw[first...last])
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else {
            throw TravelCutError.modelResponseInvalid
        }

        let start = response.start.map { min(duration, max(0, $0)) }
        let end = response.end.map { min(duration, max(0, $0)) }
        let validRange = start != nil && end != nil && end! - start! >= 0.1
        return DeepAnalysisResult(
            keep: response.keep,
            highlightScore: response.highlightScore,
            qualityScore: response.qualityScore,
            completenessScore: response.completenessScore,
            label: sanitizeLabel(response.label),
            reason: response.reason,
            suggestedStart: validRange ? start : nil,
            suggestedEnd: validRange ? end : nil,
            theme: response.theme
                .flatMap(HighlightTheme.init(rawValue:))
                .flatMap { allowedThemes.contains($0) ? $0 : nil }
        )
    }

    private func sanitizeLabel(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "旅行高光" : cleaned).prefix(24))
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// The theme enum is built per run so the model can only answer with a selected content type.
    static func responseSchema(themes: [HighlightTheme]) -> String {
        let names = (themes.isEmpty ? HighlightTheme.allCases : themes).map { "\"\($0.rawValue)\"" }
        return """
        {"type":"object","properties":{"keep":{"type":"boolean"},"highlight_score":{"type":"number"},\
        "quality_score":{"type":"number"},"completeness_score":{"type":"number"},\
        "label":{"type":"string","maxLength":12},"reason":{"type":"string","maxLength":48},\
        "theme":{"type":"string","enum":[\(names.joined(separator: ","))]},\
        "start":{"type":"number"},"end":{"type":"number"}},\
        "required":["keep","highlight_score","quality_score","completeness_score","label","reason","theme","start","end"],\
        "additionalProperties":false}
        """
    }
}
