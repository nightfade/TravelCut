import Foundation

struct SourceSignature: Codable, Hashable, Sendable {
    let path: String
    let fileSize: Int64
    let modifiedAt: Date

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ]) else {
            return nil
        }
        path = url.standardizedFileURL.path
        fileSize = Int64(values.fileSize ?? 0)
        modifiedAt = values.contentModificationDate ?? .distantPast
    }

    func matches(_ other: SourceSignature) -> Bool {
        path == other.path
            && fileSize == other.fileSize
            && abs(modifiedAt.timeIntervalSince(other.modifiedAt)) < 2
    }
}

struct SavedCandidate: Codable, Sendable {
    let source: SourceVideo
    let sourceIndex: Int
    let start: TimeInterval
    let duration: TimeInterval
    let score: Double
    let semanticLabel: String
    let audioLabels: [String]
    let deepAnalysis: DeepAnalysisResult?

    init(_ candidate: HighlightCandidate) {
        source = candidate.source
        sourceIndex = candidate.sourceIndex
        start = candidate.start
        duration = candidate.duration
        score = candidate.score
        semanticLabel = candidate.semanticLabel
        audioLabels = candidate.audioLabels
        deepAnalysis = candidate.deepAnalysis
    }

    func restored() -> HighlightCandidate {
        HighlightCandidate(
            source: source,
            sourceIndex: sourceIndex,
            start: start,
            duration: duration,
            score: score,
            aestheticScore: 0.5,
            technicalScore: 1,
            brightness: 0.5,
            faceCount: 0,
            faceQuality: 0,
            isUtilityImage: false,
            labels: [],
            semanticScore: 0.5,
            semanticLabel: semanticLabel,
            audioScore: 0.5,
            audioLabels: audioLabels,
            deepAnalysis: deepAnalysis,
            featurePrint: nil,
            semanticEmbedding: nil
        )
    }
}

struct SelectionCheckpoint: Codable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let savedAt: Date
    let inputFolder: String
    let outputFolder: String
    let useDeepAnalysis: Bool
    let deepCandidateFraction: Double
    let deepFrameCount: Int
    let selectedThemes: [HighlightTheme]
    let sourceSignatures: [SourceSignature]
    let inputVideoCount: Int
    let analyzedCandidateCount: Int
    let advancedModel: String?
    let selectedCandidates: [SavedCandidate]
    var exportedClips: [ExportedClip]

    init(
        configuration: JobConfiguration,
        sourceURLs: [URL],
        inputVideoCount: Int,
        analyzedCandidateCount: Int,
        advancedModel: String?,
        selectedCandidates: [HighlightCandidate],
        exportedClips: [ExportedClip] = []
    ) {
        schema = Self.schemaVersion
        savedAt = Date()
        inputFolder = configuration.inputFolder.standardizedFileURL.path
        outputFolder = configuration.outputFolder.standardizedFileURL.path
        useDeepAnalysis = configuration.useDeepAnalysis
        deepCandidateFraction = configuration.deepCandidateFraction
        deepFrameCount = configuration.deepFrameCount
        selectedThemes = HighlightTheme.allCases.filter(configuration.selectedThemes.contains)
        sourceSignatures = sourceURLs.compactMap(SourceSignature.init)
            .sorted { $0.path < $1.path }
        self.inputVideoCount = inputVideoCount
        self.analyzedCandidateCount = analyzedCandidateCount
        self.advancedModel = advancedModel
        self.selectedCandidates = selectedCandidates.map(SavedCandidate.init)
        self.exportedClips = exportedClips
    }

    var candidates: [HighlightCandidate] {
        selectedCandidates.map { $0.restored() }
    }
}

enum SelectionCheckpointStore {
    static let filename = ".travelcut-selection-checkpoint.json"

    static func exists(in outputFolder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: outputFolder.appendingPathComponent(filename).path
        )
    }

    static func create(
        configuration: JobConfiguration,
        sourceURLs: [URL],
        inputVideoCount: Int,
        analyzedCandidateCount: Int,
        advancedModel: String?,
        selectedCandidates: [HighlightCandidate]
    ) -> SelectionCheckpoint {
        SelectionCheckpoint(
            configuration: configuration,
            sourceURLs: sourceURLs,
            inputVideoCount: inputVideoCount,
            analyzedCandidateCount: analyzedCandidateCount,
            advancedModel: advancedModel,
            selectedCandidates: selectedCandidates
        )
    }

    static func save(_ checkpoint: SelectionCheckpoint, to outputFolder: URL) throws {
        try FileManager.default.createDirectory(
            at: outputFolder,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        try data.write(
            to: outputFolder.appendingPathComponent(filename),
            options: .atomic
        )
    }

    static func loadValid(for configuration: JobConfiguration) -> SelectionCheckpoint? {
        let url = configuration.outputFolder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(SelectionCheckpoint.self, from: data),
              checkpoint.schema == SelectionCheckpoint.schemaVersion,
              checkpoint.inputFolder == configuration.inputFolder.standardizedFileURL.path,
              checkpoint.outputFolder == configuration.outputFolder.standardizedFileURL.path,
              checkpoint.useDeepAnalysis == configuration.useDeepAnalysis,
              abs(checkpoint.deepCandidateFraction - configuration.deepCandidateFraction) < 0.0001,
              checkpoint.deepFrameCount == configuration.deepFrameCount,
              Set(checkpoint.selectedThemes) == configuration.selectedThemes,
              !checkpoint.selectedCandidates.isEmpty,
              sourcesAreUnchanged(checkpoint, configuration: configuration)
        else {
            return nil
        }
        return checkpoint
    }

    static func remove(from outputFolder: URL) {
        try? FileManager.default.removeItem(
            at: outputFolder.appendingPathComponent(filename)
        )
    }

    static func ensureOutputSpace(
        candidates: [HighlightCandidate],
        previouslyExported: [ExportedClip],
        outputFolder: URL
    ) throws {
        let remaining = candidates.filter { candidate in
            !previouslyExported.contains { $0.matches(candidate) }
        }
        let estimatedBytes = remaining.reduce(Int64(0)) { total, candidate in
            guard candidate.source.duration > 0, candidate.source.fileSize > 0 else {
                return total
            }
            let ratio = min(1, max(0, candidate.duration / candidate.source.duration))
            return total + Int64(Double(candidate.source.fileSize) * ratio)
        }
        let safetyMargin = max(Int64(256_000_000), estimatedBytes / 10)
        let required = estimatedBytes + safetyMargin
        guard let available = availableOutputCapacity(at: outputFolder),
              available < required
        else {
            return
        }
        throw TravelCutError.insufficientOutputSpace(
            requiredGB: Double(required) / 1_000_000_000,
            availableGB: Double(available) / 1_000_000_000
        )
    }

    static func availableOutputCapacity(at outputFolder: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let values = try? outputFolder.resourceValues(forKeys: keys)
        let standardCapacity = values?.volumeAvailableCapacity.map(Int64.init)
        let importantCapacity = values?.volumeAvailableCapacityForImportantUsage
        let fileSystemCapacity = (
            try? FileManager.default.attributesOfFileSystem(forPath: outputFolder.path)
        )?[.systemFreeSize].flatMap { ($0 as? NSNumber)?.int64Value }

        if ProcessInfo.processInfo.environment["TRAVELCUT_DEBUG"] == "1" {
            let detail = "DISK standard=\(standardCapacity ?? -1) filesystem=\(fileSystemCapacity ?? -1) important=\(importantCapacity ?? -1)\n"
            FileHandle.standardError.write(Data(detail.utf8))
        }

        return preferredAvailableCapacity(
            standard: standardCapacity,
            fileSystem: fileSystemCapacity,
            important: importantCapacity
        )
    }

    static func preferredAvailableCapacity(
        standard: Int64?,
        fileSystem: Int64?,
        important: Int64?
    ) -> Int64? {
        if let standard, standard > 0 { return standard }
        if let fileSystem, fileSystem > 0 { return fileSystem }
        if let important, important > 0 { return important }
        return nil
    }

    private static func sourcesAreUnchanged(
        _ checkpoint: SelectionCheckpoint,
        configuration: JobConfiguration
    ) -> Bool {
        guard let urls = try? MediaDiscovery.discoverVideos(
            in: configuration.inputFolder,
            excludingFolders: [configuration.outputFolder]
        ) else {
            return false
        }
        let current = urls.compactMap(SourceSignature.init).sorted { $0.path < $1.path }
        guard current.count == checkpoint.sourceSignatures.count else { return false }
        return zip(current, checkpoint.sourceSignatures).allSatisfy { $0.matches($1) }
    }
}

extension ExportedClip {
    func matches(_ candidate: HighlightCandidate) -> Bool {
        guard sourceFile == candidate.source.url.path,
              abs(startSeconds - candidate.start) < 0.01,
              abs(durationSeconds - candidate.duration) < 0.01,
              FileManager.default.fileExists(atPath: outputFile),
              let size = try? URL(fileURLWithPath: outputFile)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize
        else {
            return false
        }
        return size > 0
    }
}

public enum HighlightRecovery {
    public static func resumableOutputFolder(
        in inputFolder: URL,
        selectedThemes: Set<HighlightTheme>,
        useDeepAnalysis: Bool = true,
        deepCandidateFraction: Double = 0.40,
        deepFrameCount: Int = 10
    ) -> URL? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: inputFolder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let candidates = children.filter { url in
            guard url.lastPathComponent.lowercased().hasPrefix("travelcut 高光片段"),
                  (try? url.resourceValues(forKeys: keys).isDirectory) == true,
                  !FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("selection.json").path
                  )
            else {
                return false
            }
            return FileManager.default.fileExists(
                atPath: url.appendingPathComponent(SelectionCheckpointStore.filename).path
            )
        }.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }

        for outputFolder in candidates {
            let configuration = JobConfiguration(
                inputFolder: inputFolder,
                outputFolder: outputFolder,
                useDeepAnalysis: useDeepAnalysis,
                deepCandidateFraction: deepCandidateFraction,
                deepFrameCount: deepFrameCount,
                selectedThemes: selectedThemes
            )
            if SelectionCheckpointStore.loadValid(for: configuration) != nil {
                return outputFolder
            }
        }
        return nil
    }
}

public enum TravelCutDiagnostics {
    public static func recoverySelfTest() -> [String] {
        var failures: [String] = []
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("TravelCut-Recovery-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        let output = input.appendingPathComponent("TravelCut 高光片段", isDirectory: true)
        defer { try? manager.removeItem(at: root) }

        do {
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            let sourceURL = input.appendingPathComponent("source.mp4")
            try Data(repeating: 7, count: 128).write(to: sourceURL)
            let source = SourceVideo(
                url: sourceURL,
                duration: 10,
                createdAt: Date(),
                hasAudio: true,
                width: 3840,
                height: 2160,
                nominalFrameRate: 60,
                codec: "hvc1",
                isHDR: true,
                fileSize: 128
            )
            let candidate = diagnosticCandidate(source: source)
            let configuration = JobConfiguration(
                inputFolder: input,
                outputFolder: output,
                selectedThemes: [.roadScenery]
            )
            let checkpoint = SelectionCheckpointStore.create(
                configuration: configuration,
                sourceURLs: [sourceURL],
                inputVideoCount: 1,
                analyzedCandidateCount: 1,
                advancedModel: QwenVideoAnalyzer.modelName,
                selectedCandidates: [candidate]
            )
            try SelectionCheckpointStore.save(checkpoint, to: output)
            if SelectionCheckpointStore.loadValid(for: configuration) == nil {
                failures.append("valid recovery checkpoint does not load")
            }
            if HighlightRecovery.resumableOutputFolder(
                in: input,
                selectedThemes: [.roadScenery]
            )?.standardizedFileURL.path != output.standardizedFileURL.path {
                failures.append("valid recovery folder is not discovered")
            }
            if HighlightRecovery.resumableOutputFolder(
                in: input,
                selectedThemes: [.people]
            ) != nil {
                failures.append("checkpoint ignores changed content themes")
            }

            try Data(repeating: 8, count: 256).write(to: sourceURL)
            if SelectionCheckpointStore.loadValid(for: configuration) != nil {
                failures.append("checkpoint does not invalidate after source change")
            }

            let hugeSource = SourceVideo(
                url: sourceURL,
                duration: 10,
                createdAt: Date(),
                hasAudio: false,
                fileSize: 8_000_000_000_000_000
            )
            do {
                try SelectionCheckpointStore.ensureOutputSpace(
                    candidates: [diagnosticCandidate(source: hugeSource)],
                    previouslyExported: [],
                    outputFolder: output
                )
                failures.append("output space check did not reject impossible export")
            } catch TravelCutError.insufficientOutputSpace {
                // Expected.
            } catch {
                failures.append("output space check returned unexpected error")
            }
            if let available = SelectionCheckpointStore.availableOutputCapacity(at: output),
               available <= 0 {
                failures.append("output capacity fallback returned a non-positive value")
            }
            if SelectionCheckpointStore.preferredAvailableCapacity(
                standard: 0,
                fileSystem: 120_000_000_000,
                important: 0
            ) != 120_000_000_000 {
                failures.append("output capacity does not fall back after a false zero")
            }
            if SelectionCheckpointStore.preferredAvailableCapacity(
                standard: 0,
                fileSystem: -1,
                important: 0
            ) != nil {
                failures.append("output capacity accepts invalid non-positive values")
            }
        } catch {
            failures.append("recovery self-test setup failed: \(error.localizedDescription)")
        }
        return failures
    }

    private static func diagnosticCandidate(source: SourceVideo) -> HighlightCandidate {
        HighlightCandidate(
            source: source,
            sourceIndex: 0,
            start: 1,
            duration: 4,
            score: 0.9,
            aestheticScore: 0.8,
            technicalScore: 0.8,
            brightness: 0.5,
            faceCount: 0,
            faceQuality: 0,
            isUtilityImage: false,
            labels: [],
            semanticScore: 0.9,
            semanticLabel: "沿途风景",
            audioLabels: [],
            featurePrint: nil,
            semanticEmbedding: nil
        )
    }
}
