import Foundation

public final class HighlightEngine: @unchecked Sendable {
    public init() {}

    public func run(
        configuration: JobConfiguration,
        progress: @Sendable @escaping (ProgressUpdate) -> Void = { _ in }
    ) async throws -> JobSummary {
        guard !configuration.selectedThemes.isEmpty else {
            throw TravelCutError.invalidArguments("请至少选择一种想保留的内容")
        }
        if let checkpoint = SelectionCheckpointStore.loadValid(for: configuration) {
            progress(ProgressUpdate(
                fraction: 0.84,
                message: "发现上次保存的筛选结果，正在继续导出…"
            ))
            return try await completeExport(
                checkpoint: checkpoint,
                configuration: configuration,
                progress: progress
            )
        }
        if SelectionCheckpointStore.exists(in: configuration.outputFolder) {
            throw TravelCutError.invalidArguments(
                "已有筛选检查点，但素材或标签已经变化。请选择新的输出文件夹重新分析。"
            )
        }
        progress(ProgressUpdate(fraction: 0.01, message: "正在查找视频…"))
        let urls = try MediaDiscovery.discoverVideos(
            in: configuration.inputFolder,
            excludingFolders: [configuration.outputFolder]
        )
        guard !urls.isEmpty else { throw TravelCutError.noVideos }

        progress(ProgressUpdate(fraction: 0.03, message: "正在读取 \(urls.count) 个文件及原始规格…"))
        let sources = await MediaDiscovery.probe(urls)
        guard !sources.isEmpty else { throw TravelCutError.noUsableVideos }

        progress(ProgressUpdate(fraction: 0.06, message: "正在识别镜头和自然事件边界…"))
        let plans = await EventSegmenter.segment(sources: sources) { completed, total in
            let fraction = 0.06 + 0.12 * Double(completed) / Double(max(1, total))
            progress(ProgressUpdate(
                fraction: fraction,
                message: "正在划分事件 \(completed)/\(total)…"
            ))
        }
        guard !plans.isEmpty else { throw TravelCutError.noCandidates }

        progress(ProgressUpdate(fraction: 0.18, message: "正在准备 MobileCLIP 本地模型…"))
        _ = try await ModelInstaller(ModelInstaller.mobileCLIP).install { modelProgress in
            progress(ProgressUpdate(
                fraction: 0.18,
                message: modelProgress < 1
                    ? "首次使用正在下载 MobileCLIP 模型 \(Int(modelProgress * 100))%…"
                    : "MobileCLIP 已就绪"
            ))
        }

        let fastAnalyzer = VisionAnalyzer(selectedThemes: configuration.selectedThemes)
        var fastCandidates: [HighlightCandidate] = []
        for (index, plan) in plans.enumerated() {
            try Task.checkCancellation()
            let source = sources[plan.sourceIndex]
            if let candidate = autoreleasepool(invoking: { try? fastAnalyzer.analyze(plan: plan, source: source) }) {
                fastCandidates.append(candidate)
                if ProcessInfo.processInfo.environment["TRAVELCUT_DEBUG"] == "1" {
                    let detail = String(
                        format: "FAST %@ %.2f-%.2f score=%.3f technical=%.3f semantic=%.3f label=%@ utility=%@\n",
                        source.url.lastPathComponent,
                        candidate.start,
                        candidate.end,
                        candidate.score,
                        candidate.technicalScore,
                        candidate.semanticScore,
                        candidate.semanticLabel,
                        candidate.isUtilityImage ? "yes" : "no"
                    )
                    FileHandle.standardError.write(Data(detail.utf8))
                }
            }
            let fraction = 0.18 + 0.30 * Double(index + 1) / Double(max(1, plans.count))
            progress(ProgressUpdate(
                fraction: fraction,
                message: "正在快速筛选事件 \(index + 1)/\(plans.count)…"
            ))
        }
        guard !fastCandidates.isEmpty else { throw TravelCutError.noCandidates }

        let audioAnalyzer = AudioEventAnalyzer()
        var audioEvents: [URL: [AudioEvent]] = [:]
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            audioEvents[source.url] = audioAnalyzer.analyze(source: source)
            let fraction = 0.48 + 0.05 * Double(index + 1) / Double(max(1, sources.count))
            progress(ProgressUpdate(
                fraction: fraction,
                message: "正在分析现场声 \(index + 1)/\(sources.count)…"
            ))
        }
        fastCandidates = fastCandidates.map { candidate in
            candidate.applying(audioAnalyzer.summary(
                for: candidate,
                events: audioEvents[candidate.source.url] ?? []
            ))
        }

        let analyzedCandidates: [HighlightCandidate]
        let advancedModel: String?
        if configuration.useDeepAnalysis {
            let candidates = HighlightSelector.candidatesForDeepAnalysis(
                from: fastCandidates,
                fraction: configuration.deepCandidateFraction
            )
            guard !candidates.isEmpty else { throw TravelCutError.noCandidates }

            let qwen = QwenVideoAnalyzer()
            progress(ProgressUpdate(fraction: 0.54, message: "正在准备 Qwen3-VL-4B 本地模型…"))
            try await qwen.load { modelProgress in
                progress(ProgressUpdate(
                    fraction: 0.54 + modelProgress * 0.06,
                    message: modelProgress < 1
                        ? "首次使用正在下载本地模型 \(Int(modelProgress * 100))%…"
                        : "Qwen3-VL-4B 已就绪"
                ))
            }

            var deepCandidates: [HighlightCandidate] = []
            var successfulAnalyses = 0
            var lastAnalysisError: Error?
            for (index, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                do {
                    let result = try await qwen.analyze(
                        candidate: candidate,
                        frameCount: configuration.deepFrameCount,
                        selectedThemes: configuration.selectedThemes
                    )
                    deepCandidates.append(applySuggestedRange(result, to: candidate))
                    successfulAnalyses += 1
                } catch {
                    lastAnalysisError = error
                }
                let fraction = 0.60 + 0.24 * Double(index + 1) / Double(max(1, candidates.count))
                progress(ProgressUpdate(
                    fraction: fraction,
                    message: "正在深度判断高光 \(index + 1)/\(candidates.count)…"
                ))
            }
            if successfulAnalyses == 0, let lastAnalysisError { throw lastAnalysisError }
            analyzedCandidates = deepCandidates
            advancedModel = QwenVideoAnalyzer.modelName
        } else {
            analyzedCandidates = fastCandidates
            advancedModel = fastAnalyzer.fastModelName
        }

        progress(ProgressUpdate(fraction: 0.85, message: "正在整批比较、去重并按时间排序…"))
        let selected = HighlightSelector.select(
            from: analyzedCandidates,
            requiresDeepAnalysis: configuration.useDeepAnalysis
        )
        guard !selected.isEmpty else { throw TravelCutError.noHighlights }

        let checkpoint = SelectionCheckpointStore.create(
            configuration: configuration,
            sourceURLs: urls,
            inputVideoCount: sources.count,
            analyzedCandidateCount: fastCandidates.count,
            advancedModel: advancedModel,
            selectedCandidates: selected
        )
        try SelectionCheckpointStore.save(checkpoint, to: configuration.outputFolder)
        progress(ProgressUpdate(fraction: 0.86, message: "筛选结果已保存，正在检查输出空间…"))
        return try await completeExport(
            checkpoint: checkpoint,
            configuration: configuration,
            progress: progress
        )
    }

    private func completeExport(
        checkpoint initialCheckpoint: SelectionCheckpoint,
        configuration: JobConfiguration,
        progress: @Sendable @escaping (ProgressUpdate) -> Void
    ) async throws -> JobSummary {
        var checkpoint = initialCheckpoint
        let candidates = checkpoint.candidates
        try SelectionCheckpointStore.ensureOutputSpace(
            candidates: candidates,
            previouslyExported: checkpoint.exportedClips,
            outputFolder: configuration.outputFolder
        )
        let exported = try await ClipExporter.export(
            candidates: candidates,
            configuration: configuration,
            previouslyExported: checkpoint.exportedClips
        ) { completed, total, currentExports in
            checkpoint.exportedClips = currentExports
            try SelectionCheckpointStore.save(checkpoint, to: configuration.outputFolder)
            let fraction = 0.87 + 0.12 * Double(completed) / Double(max(1, total))
            progress(ProgressUpdate(
                fraction: fraction,
                message: "正在按原始规格裁剪 \(completed)/\(total)…"
            ))
        }
        let reportURL = try writeReport(
            clips: exported,
            sourceCount: checkpoint.inputVideoCount,
            analyzedCount: checkpoint.analyzedCandidateCount,
            modelName: checkpoint.advancedModel,
            configuration: configuration
        )
        SelectionCheckpointStore.remove(from: configuration.outputFolder)
        progress(ProgressUpdate(fraction: 1, message: "完成"))
        return JobSummary(
            outputFolder: configuration.outputFolder,
            reportFile: reportURL,
            exportedFiles: exported.map { URL(fileURLWithPath: $0.outputFile) },
            inputVideoCount: checkpoint.inputVideoCount,
            analyzedCandidateCount: checkpoint.analyzedCandidateCount,
            selectedClipCount: exported.count,
            totalOutputDuration: exported.reduce(0) { $0 + $1.durationSeconds },
            advancedModelUsed: checkpoint.advancedModel
        )
    }

    private func applySuggestedRange(
        _ result: DeepAnalysisResult,
        to candidate: HighlightCandidate
    ) -> HighlightCandidate {
        guard let suggestedStart = result.suggestedStart,
              let suggestedEnd = result.suggestedEnd,
              suggestedEnd - suggestedStart >= 0.1
        else {
            return candidate.applying(result, start: candidate.start, duration: candidate.duration)
        }

        let padding = 0.15
        let relativeStart = max(0, suggestedStart - padding)
        let relativeEnd = min(candidate.duration, suggestedEnd + padding)
        return candidate.applying(
            result,
            start: candidate.start + relativeStart,
            duration: relativeEnd - relativeStart
        )
    }

    private func writeReport(
        clips: [ExportedClip],
        sourceCount: Int,
        analyzedCount: Int,
        modelName: String?,
        configuration: JobConfiguration
    ) throws -> URL {
        let report = SelectionReport(
            generatedAt: Date(),
            inputFolder: configuration.inputFolder.path,
            outputFolder: configuration.outputFolder.path,
            analyzedVideos: sourceCount,
            analyzedCandidates: analyzedCount,
            advancedModel: modelName,
            selectedThemes: HighlightTheme.allCases
                .filter(configuration.selectedThemes.contains)
                .map(\.rawValue),
            totalOutputDurationSeconds: clips.reduce(0) { $0 + $1.durationSeconds },
            exportedClips: clips
        )
        let reportURL = configuration.outputFolder.appendingPathComponent("selection.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        return reportURL
    }
}
