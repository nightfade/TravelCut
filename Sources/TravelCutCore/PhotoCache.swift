import Foundation
import Vision

/// Per-photo analysis and per-group Qwen judgements, kept in `<photo root>/.travelcut-cache/` so a
/// re-run skips work already done and a stopped run picks up where it left off. The folder travels
/// with the photos; its leading dot keeps Bridge and TravelCut's own discovery away from it.
///
/// Files are append-only JSON Lines, written the moment each photo or group finishes.
/// - Photos are keyed by path relative to the root plus capture time, not by size or modification
///   date: writing ratings into a JPEG changes its size and must not invalidate the cache.
/// - Only the MobileCLIP embedding is stored, never the theme, so changing the selected themes
///   re-scores cached photos instead of re-analysing them.
/// - Bump `analysisVersion` / `qwenVersion` whenever the analysis or the prompt changes.
final class PhotoCache {
    static let analysisVersion = 1
    static let qwenVersion = 2   // 2: the prompt includes the place
    static let folderName = ".travelcut-cache"

    struct Metrics: Codable {
        let aesthetic: Double
        let sharpness: Double
        let faceSharpness: Double?
        let faceQuality: Double
        let eyesClosed: Bool
        let brightness: Double
        let isUtility: Bool
        let previewSize: Int
        let embedding: [Float]?
        let featurePrint: Data?

        enum CodingKeys: String, CodingKey {
            case aesthetic, sharpness, faceSharpness, faceQuality, eyesClosed, brightness, isUtility, previewSize
            case embedding, featurePrint
        }

        init(_ metrics: PhotoMetrics) {
            aesthetic = metrics.aesthetic
            sharpness = metrics.sharpness
            faceSharpness = metrics.faceSharpness
            faceQuality = metrics.faceQuality
            eyesClosed = metrics.eyesClosed
            brightness = metrics.brightness
            isUtility = metrics.isUtility
            previewSize = metrics.previewSize
            embedding = metrics.embedding
            featurePrint = metrics.featurePrint.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
        }

        // The embedding is stored as base64 of raw Float32 bytes: a third of the size of JSON numbers.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            aesthetic = try c.decode(Double.self, forKey: .aesthetic)
            sharpness = try c.decode(Double.self, forKey: .sharpness)
            faceSharpness = try c.decodeIfPresent(Double.self, forKey: .faceSharpness)
            faceQuality = try c.decode(Double.self, forKey: .faceQuality)
            eyesClosed = try c.decode(Bool.self, forKey: .eyesClosed)
            brightness = try c.decode(Double.self, forKey: .brightness)
            isUtility = try c.decode(Bool.self, forKey: .isUtility)
            previewSize = try c.decode(Int.self, forKey: .previewSize)
            embedding = try c.decodeIfPresent(Data.self, forKey: .embedding).map { data in
                data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            featurePrint = try c.decodeIfPresent(Data.self, forKey: .featurePrint)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(aesthetic, forKey: .aesthetic)
            try c.encode(sharpness, forKey: .sharpness)
            try c.encodeIfPresent(faceSharpness, forKey: .faceSharpness)
            try c.encode(faceQuality, forKey: .faceQuality)
            try c.encode(eyesClosed, forKey: .eyesClosed)
            try c.encode(brightness, forKey: .brightness)
            try c.encode(isUtility, forKey: .isUtility)
            try c.encode(previewSize, forKey: .previewSize)
            try c.encodeIfPresent(embedding.map { values in values.withUnsafeBufferPointer { Data(buffer: $0) } },
                                  forKey: .embedding)
            try c.encodeIfPresent(featurePrint, forKey: .featurePrint)
        }
    }

    private struct AnalysisLine: Codable { let key: String; let metrics: Metrics }
    private struct QwenLine: Codable { let key: String; let judgement: PhotoGroupJudgement }

    private let root: URL
    private var analysis: [String: Metrics] = [:]
    private var judgements: [String: PhotoGroupJudgement] = [:]
    private var analysisHandle: FileHandle?
    private var qwenHandle: FileHandle?
    private let encoder = JSONEncoder()

    /// Returns nil when the cache cannot be used (read-only volume, or disabled by TRAVELCUT_NO_CACHE=1).
    init?(root: URL) {
        guard ProcessInfo.processInfo.environment["TRAVELCUT_NO_CACHE"] != "1" else { return nil }
        self.root = root.standardizedFileURL
        let folder = root.appendingPathComponent(Self.folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { return nil }
        let analysisURL = folder.appendingPathComponent("analysis-v\(Self.analysisVersion).jsonl")
        let qwenURL = folder.appendingPathComponent("qwen-v\(Self.qwenVersion).jsonl")
        analysis = Self.load(analysisURL, as: AnalysisLine.self).reduce(into: [:]) { $0[$1.key] = $1.metrics }
        judgements = Self.load(qwenURL, as: QwenLine.self).reduce(into: [:]) { $0[$1.key] = $1.judgement }
        analysisHandle = Self.appendHandle(analysisURL)
        qwenHandle = Self.appendHandle(qwenURL)
        guard analysisHandle != nil, qwenHandle != nil else { return nil }
    }

    deinit {
        try? analysisHandle?.close()
        try? qwenHandle?.close()
    }

    var cachedPhotoCount: Int { analysis.count }

    func key(for item: PhotoItem) -> String {
        let path = item.primary.standardizedFileURL.path
        let relative = path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
        return "\(relative)|\(String(format: "%.2f", item.capturedAt.timeIntervalSince1970))"
    }

    func metrics(for key: String) -> Metrics? { analysis[key] }

    func store(_ metrics: PhotoMetrics, for key: String) {
        guard !metrics.visionFailed else { return }   // retry failed photos next time
        let cached = Metrics(metrics)
        analysis[key] = cached
        append(AnalysisLine(key: key, metrics: cached), to: analysisHandle)
    }

    static func groupKey(photoKeys: [String], themes: Set<HighlightTheme>, place: String? = nil) -> String {
        let themeList = HighlightTheme.allCases.filter(themes.contains).map(\.rawValue).joined(separator: ",")
        return themeList + "@" + (place ?? "") + "#" + photoKeys.joined(separator: "#")
    }

    func judgement(for key: String) -> PhotoGroupJudgement? { judgements[key] }

    func store(_ judgement: PhotoGroupJudgement, for key: String) {
        judgements[key] = judgement
        append(QwenLine(key: key, judgement: judgement), to: qwenHandle)
    }

    private func append<T: Encodable>(_ value: T, to handle: FileHandle?) {
        guard let handle, var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    private static func load<T: Decodable>(_ url: URL, as type: T.Type) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        // A run killed mid-write leaves a partial last line; skip anything that does not decode.
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }

    private static func appendHandle(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        let end = (try? handle.seekToEnd()) ?? 0
        // Terminate a partial last line from a killed run, so the next record starts on its own line.
        if end > 0, let reader = try? FileHandle(forReadingFrom: url) {
            try? reader.seek(toOffset: end - 1)
            if reader.readData(ofLength: 1) != Data([0x0A]) { try? handle.write(contentsOf: Data([0x0A])) }
            try? reader.close()
        }
        return handle
    }
}
