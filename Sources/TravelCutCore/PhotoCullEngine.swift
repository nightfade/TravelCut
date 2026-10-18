import CoreGraphics
import Foundation
import Vision

public struct PhotoCullConfiguration: Sendable {
    public let inputFolder: URL
    public let selectedThemes: Set<HighlightTheme>
    public let useQwen: Bool
    /// false: only write the report, leave every sidecar untouched.
    public let writeRatings: Bool

    public init(
        inputFolder: URL,
        selectedThemes: Set<HighlightTheme> = HighlightTheme.defaultSelection,
        useQwen: Bool = true,
        writeRatings: Bool = true
    ) {
        self.inputFolder = inputFolder
        self.selectedThemes = selectedThemes
        self.useQwen = useQwen
        self.writeRatings = writeRatings
    }
}

public struct PhotoCullSummary: Sendable {
    public let reportFile: URL
    public let photoCount: Int
    public let groupCount: Int
    public let starredCount: Int          // 2 stars or more
    public let rejectedCount: Int
    public let skippedUserMarked: Int     // already rated or labelled by the user
    public let withoutRAW: Int            // JPEG/HEIC/DNG only: no sidecar written
    public let wroteRatings: Bool
}

/// Groups a trip's photos, picks the best of each group with Qwen's help and writes the result
/// into the RAW sidecars as star ratings, a "组 0042 · 第 1/5" title and keywords for Bridge.
public final class PhotoCullEngine: @unchecked Sendable {
    public static let reportName = "TravelCut 照片精选报告.json"

    public init() {}

    public func run(
        configuration: PhotoCullConfiguration,
        progress: @Sendable @escaping (ProgressUpdate) -> Void = { _ in }
    ) async throws -> PhotoCullSummary {
        guard !configuration.selectedThemes.isEmpty else {
            throw TravelCutError.invalidArguments("请至少选择一种想保留的内容")
        }
        progress(ProgressUpdate(fraction: 0.01, message: "正在查找照片…"))
        let items = try PhotoDiscovery.discover(in: configuration.inputFolder)
        guard !items.isEmpty else { throw TravelCutError.invalidArguments("所选文件夹中没有找到照片。") }

        progress(ProgressUpdate(fraction: 0.02, message: "正在准备 MobileCLIP 本地模型…"))
        _ = try await ModelInstaller(ModelInstaller.mobileCLIP).install { value in
            progress(ProgressUpdate(
                fraction: 0.02,
                message: value < 1 ? "首次使用正在下载 MobileCLIP 模型 \(Int(value * 100))%…" : "MobileCLIP 已就绪"
            ))
        }

        let analyzer = PhotoAnalyzer(selectedThemes: configuration.selectedThemes)
        var metrics: [PhotoMetrics?] = []
        metrics.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            metrics.append(PhotoDiscovery.preview(of: item.primary).map(analyzer.analyze))
            if index % 10 == 0 || index == items.count - 1 {
                progress(ProgressUpdate(
                    fraction: 0.03 + 0.45 * Double(index + 1) / Double(items.count),
                    message: "正在分析照片 \(index + 1)/\(items.count)…"
                ))
            }
        }

        progress(ProgressUpdate(fraction: 0.49, message: "正在把连拍和相似照片分组…"))
        let groups = PhotoGrouper.group(
            times: items.map(\.capturedAt),
            folders: items.map { $0.primary.deletingLastPathComponent().path },
            junk: metrics.map { $0?.isJunk ?? true }
        ) { i, j in
            guard let left = metrics[i]?.featurePrint, let right = metrics[j]?.featurePrint else { return nil }
            var distance: Float = 0
            guard (try? left.computeDistance(&distance, to: right)) != nil else { return nil }
            if ProcessInfo.processInfo.environment["TRAVELCUT_DEBUG"] == "1" {
                let gap = items[j].capturedAt.timeIntervalSince(items[i].capturedAt)
                FileHandle.standardError.write(Data(String(
                    format: "GROUP %@ -> %@ gap=%.2fs distance=%.3f\n",
                    items[i].primary.lastPathComponent, items[j].primary.lastPathComponent, gap, distance
                ).utf8))
            }
            return distance
        }

        var judgements = [PhotoGroupJudgement?](repeating: nil, count: groups.count)
        if configuration.useQwen {
            let qwen = QwenVideoAnalyzer()
            progress(ProgressUpdate(fraction: 0.50, message: "正在准备 Qwen3-VL-4B 本地模型…"))
            try await qwen.load { value in
                progress(ProgressUpdate(
                    fraction: 0.50 + value * 0.04,
                    message: value < 1 ? "首次使用正在下载本地模型 \(Int(value * 100))%…" : "Qwen3-VL-4B 已就绪"
                ))
            }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("TravelCut-Photos-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }

            var failures = 0
            var lastError: Error?
            for (groupIndex, members) in groups.enumerated() {
                try Task.checkCancellation()
                // Up to four of the technically best usable frames, best first: if the model leans
                // towards the first image, it leans towards the technical pick.
                let candidates = Array(members.indices
                    .filter { metrics[members[$0]].map { !$0.isJunk } ?? false }
                    .sorted { (metrics[members[$0]]?.pickScore ?? 0) > (metrics[members[$1]]?.pickScore ?? 0) }
                    .prefix(4))
                if !candidates.isEmpty {
                    var files: [URL] = []
                    for (position, member) in candidates.enumerated() {
                        let url = temporary.appendingPathComponent("g\(groupIndex)-\(position + 1).jpg")
                        if let image = PhotoDiscovery.preview(of: items[members[member]].primary),
                           PhotoDiscovery.writeJPEG(image, to: url) {
                            files.append(url)
                        }
                    }
                    if files.count == candidates.count {
                        do {
                            let result = try await qwen.judgePhotoGroup(
                                images: files, selectedThemes: configuration.selectedThemes
                            )
                            judgements[groupIndex] = PhotoGroupJudgement(
                                bestMember: result.bestMember.map { candidates[$0] },
                                keep: result.keep,
                                highlightScore: result.highlightScore,
                                theme: result.theme,
                                label: result.label,
                                reason: result.reason
                            )
                        } catch {
                            failures += 1
                            lastError = error
                        }
                    }
                    files.forEach { try? FileManager.default.removeItem(at: $0) }
                }
                progress(ProgressUpdate(
                    fraction: 0.54 + 0.42 * Double(groupIndex + 1) / Double(groups.count),
                    message: "Qwen 正在挑选 \(groupIndex + 1)/\(groups.count) 组…"
                ))
            }
            if failures == groups.count, let lastError { throw lastError }
        }

        progress(ProgressUpdate(
            fraction: 0.97,
            message: configuration.writeRatings ? "正在写入星级…" : "试运行：只生成报告，不写入星级…"
        ))
        let standout = PhotoRater.standoutThreshold(
            keptScores: judgements.compactMap { $0?.keep == true ? $0?.highlightScore : nil }
        )
        var report: [PhotoCullReport.Group] = []
        var starred = 0, rejected = 0, skipped = 0, withoutRAW = 0
        for (groupIndex, members) in groups.enumerated() {
            let number = groupIndex + 1
            let judgement = judgements[groupIndex]
            let result = PhotoRater.rate(
                pickScores: members.map { metrics[$0]?.pickScore ?? 0 },
                junk: members.map { metrics[$0]?.isJunk ?? true },
                judgement: judgement,
                standout: standout
            )
            let bestTheme = judgement?.theme ?? result.best.flatMap { metrics[members[$0]]?.theme }
            var rows: [PhotoCullReport.Photo] = []
            for (position, index) in members.enumerated() {
                let item = items[index]
                let rating = result.ratings[position]
                let rank = (result.order.firstIndex(of: position) ?? position) + 1
                var keywords = [["TravelCut", "组", String(format: "组 %04d", number)]]
                if let bestTheme { keywords.append(["TravelCut", "主题", bestTheme.rawValue]) }
                var outcome = "试运行"
                if let raw = item.sidecarTarget {
                    if configuration.writeRatings {
                        let fields = XMPSidecarWriter.Fields(
                            rating: rating,
                            title: PhotoRater.title(group: number, rank: rank, size: members.count),
                            keywords: keywords
                        )
                        let written = try XMPSidecarWriter.apply(fields, to: XMPSidecarWriter.sidecarURL(for: raw))
                        outcome = written == .written ? "已写入" : "跳过：已有你的标记"
                        if written == .skippedUserMarks { skipped += 1 }
                    }
                } else {
                    outcome = "跳过：没有 RAW，未写入"
                    withoutRAW += 1
                }
                if rating >= 2 { starred += 1 }
                if rating < 0 { rejected += 1 }
                let m = metrics[index]
                rows.append(PhotoCullReport.Photo(
                    file: item.primary.path, capturedAt: item.capturedAt, rating: rating, rank: rank,
                    pickScore: m.map { ($0.pickScore * 1000).rounded() / 1000 },
                    eyesClosed: m?.eyesClosed, junk: m?.isJunk ?? true, outcome: outcome,
                    junkReason: m == nil ? "无法读取" : m?.junkReason,
                    sharpness: m.map { ($0.sharpness * 1000).rounded() / 1000 },
                    faceSharpness: m?.faceSharpness.map { ($0 * 1000).rounded() / 1000 },
                    brightness: m.map { ($0.brightness * 1000).rounded() / 1000 },
                    aesthetic: m.map { ($0.aesthetic * 1000).rounded() / 1000 },
                    utility: m?.isUtility,
                    clipLabel: m?.semanticLabel,
                    previewSize: m?.previewSize
                ))
            }
            report.append(PhotoCullReport.Group(
                group: number, theme: bestTheme?.rawValue, judgement: judgement, photos: rows
            ))
        }

        let reportURL = configuration.inputFolder.appendingPathComponent(Self.reportName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PhotoCullReport(
            generatedAt: Date(),
            inputFolder: configuration.inputFolder.path,
            selectedThemes: HighlightTheme.allCases.filter(configuration.selectedThemes.contains).map(\.rawValue),
            usedQwen: configuration.useQwen,
            wroteRatings: configuration.writeRatings,
            photoCount: items.count,
            groupCount: groups.count,
            groups: report
        )).write(to: reportURL, options: .atomic)
        progress(ProgressUpdate(fraction: 1, message: "完成"))

        return PhotoCullSummary(
            reportFile: reportURL, photoCount: items.count, groupCount: groups.count,
            starredCount: starred, rejectedCount: rejected, skippedUserMarked: skipped,
            withoutRAW: withoutRAW, wroteRatings: configuration.writeRatings
        )
    }
}

struct PhotoCullReport: Codable {
    struct Photo: Codable {
        let file: String
        let capturedAt: Date
        let rating: Int
        let rank: Int
        let pickScore: Double?
        let eyesClosed: Bool?
        let junk: Bool
        let outcome: String
        // Diagnostics for tuning.
        let junkReason: String?
        let sharpness: Double?
        let faceSharpness: Double?
        let brightness: Double?
        let aesthetic: Double?
        let utility: Bool?
        let clipLabel: String?
        let previewSize: Int?
    }

    struct Group: Codable {
        let group: Int
        let theme: String?
        let judgement: PhotoGroupJudgement?
        let photos: [Photo]
    }

    let generatedAt: Date
    let inputFolder: String
    let selectedThemes: [String]
    let usedQwen: Bool
    let wroteRatings: Bool
    let photoCount: Int
    let groupCount: Int
    let groups: [Group]
}
