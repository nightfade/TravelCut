import AVFoundation
import Foundation
import Vision

public enum HighlightTheme: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case roadScenery = "沿途风景"
    case nature = "自然景观"
    case cityStreet = "城市街景"
    case landmark = "地标建筑"
    case people = "人物互动"
    case food = "当地美食"
    case cultureActivity = "活动人文"
    case animals = "动物"

    public var id: String { rawValue }

    public static var defaultSelection: Set<HighlightTheme> {
        Set(allCases)
    }

    var mobileCLIPPrompt: String {
        switch self {
        case .roadScenery:
            return "memorable scenery filmed along a road or through a train car boat window during a journey"
        case .nature:
            return "a beautiful travel landscape with mountains beach ocean lake forest waterfall snow sunset sunrise aurora northern lights or a starry night sky"
        case .cityStreet:
            return "an interesting city street neighborhood market or everyday street scene while traveling, by day or at night with festive lights"
        case .landmark:
            return "an impressive travel landmark historic site temple church interior museum or beautiful architecture"
        case .people:
            return "friends or family enjoying a vacation together with candid emotion conversation or interaction"
        case .food:
            return "local food restaurant cafe market meal or cooking experience during a trip"
        case .cultureActivity:
            return "a cultural performance festival light show ride sport or memorable travel activity"
        case .animals:
            return "wildlife pets or animals encountered during a journey"
        }
    }

    var qwenGuidance: String {
        switch self {
        case .roadScenery:
            return "沿途风景：公路、步行途中、车窗、火车、船上看到的景色和旅途氛围；只要清晰稳定并能记录路线，即使常见也有保留价值"
        case .nature:
            return "自然景观：山川、海岸、湖泊、森林、瀑布、雪景雪原、日出日落、极光、星空和夜空等"
        case .cityStreet:
            return "城市街景：街道、社区、市场、店铺和当地日常生活环境，包括夜晚的街景、节日灯饰和城市灯光"
        case .landmark:
            return "地标建筑：名胜、历史遗迹、建筑及其内部、教堂、寺庙、博物馆和观景地"
        case .people:
            return "人物互动：同行者的表情、对话、动作、合影过程和真实情绪"
        case .food:
            return "当地美食：餐厅、咖啡馆、市场、菜品和制作过程"
        case .cultureActivity:
            return "活动人文：表演、节庆、灯光秀、游乐、运动和当地文化体验"
        case .animals:
            return "动物：旅途中遇到的野生动物、牧场动物和宠物互动"
        }
    }
}

public struct JobConfiguration: Sendable {
    public let inputFolder: URL
    public let outputFolder: URL
    public let useDeepAnalysis: Bool
    public let deepCandidateFraction: Double
    public let deepFrameCount: Int
    public let selectedThemes: Set<HighlightTheme>

    public init(
        inputFolder: URL,
        outputFolder: URL,
        useDeepAnalysis: Bool = true,
        deepCandidateFraction: Double = 0.40,
        deepFrameCount: Int = 10,
        selectedThemes: Set<HighlightTheme> = HighlightTheme.defaultSelection
    ) {
        self.inputFolder = inputFolder
        self.outputFolder = outputFolder
        self.useDeepAnalysis = useDeepAnalysis
        self.deepCandidateFraction = min(1, max(0.05, deepCandidateFraction))
        self.deepFrameCount = min(16, max(6, deepFrameCount))
        self.selectedThemes = selectedThemes
    }
}

public struct ProgressUpdate: Sendable {
    public let fraction: Double
    public let message: String

    public init(fraction: Double, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

public struct JobSummary: Sendable {
    public let outputFolder: URL
    public let reportFile: URL
    public let exportedFiles: [URL]
    public let inputVideoCount: Int
    public let analyzedCandidateCount: Int
    public let selectedClipCount: Int
    public let totalOutputDuration: TimeInterval
    public let advancedModelUsed: String?
}

public struct MediaMetadataRecord: Codable, Hashable, Sendable {
    public let identifier: String?
    public let keySpace: String?
    public let key: String?
    public let value: String?

    public init(identifier: String?, keySpace: String?, key: String?, value: String?) {
        self.identifier = identifier
        self.keySpace = keySpace
        self.key = key
        self.value = value
    }
}

public struct SourceVideo: Codable, Hashable, Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let createdAt: Date
    public let modifiedAt: Date
    public let hasAudio: Bool
    public let width: Int
    public let height: Int
    public let nominalFrameRate: Double
    public let codec: String
    public let isHDR: Bool
    public let fileSize: Int64
    public let metadata: [MediaMetadataRecord]

    public init(
        url: URL,
        duration: TimeInterval,
        createdAt: Date,
        modifiedAt: Date? = nil,
        hasAudio: Bool,
        width: Int = 0,
        height: Int = 0,
        nominalFrameRate: Double = 0,
        codec: String = "unknown",
        isHDR: Bool = false,
        fileSize: Int64 = 0,
        metadata: [MediaMetadataRecord] = []
    ) {
        self.url = url
        self.duration = duration
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.hasAudio = hasAudio
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.codec = codec
        self.isHDR = isHDR
        self.fileSize = fileSize
        self.metadata = metadata
    }
}

public struct CandidatePlan: Equatable, Hashable, Sendable {
    public let sourceIndex: Int
    public let start: TimeInterval
    public let duration: TimeInterval

    public var end: TimeInterval { start + duration }

    public init(sourceIndex: Int, start: TimeInterval, duration: TimeInterval) {
        self.sourceIndex = sourceIndex
        self.start = start
        self.duration = duration
    }
}

public struct DeepAnalysisResult: Codable, Sendable {
    public let keep: Bool
    public let highlightScore: Double
    public let qualityScore: Double
    public let completenessScore: Double
    public let label: String
    public let reason: String
    public let suggestedStart: TimeInterval?
    public let suggestedEnd: TimeInterval?
    /// The selected content type the clip fits best; nil in checkpoints from older versions.
    public let theme: HighlightTheme?

    public init(
        keep: Bool,
        highlightScore: Double,
        qualityScore: Double,
        completenessScore: Double,
        label: String,
        reason: String,
        suggestedStart: TimeInterval? = nil,
        suggestedEnd: TimeInterval? = nil,
        theme: HighlightTheme? = nil
    ) {
        self.keep = keep
        self.highlightScore = min(1, max(0, highlightScore))
        self.qualityScore = min(1, max(0, qualityScore))
        self.completenessScore = min(1, max(0, completenessScore))
        self.label = label
        self.reason = reason
        self.suggestedStart = suggestedStart
        self.suggestedEnd = suggestedEnd
        self.theme = theme
    }
}

struct AudioEvent: Sendable {
    let start: TimeInterval
    let duration: TimeInterval
    let identifier: String
    let confidence: Double

    var end: TimeInterval { start + duration }
}

struct AudioSummary: Sendable {
    let score: Double
    let labels: [String]

    static let unavailable = AudioSummary(score: 0.5, labels: [])
}

public final class HighlightCandidate: @unchecked Sendable {
    public let source: SourceVideo
    public let sourceIndex: Int
    public let start: TimeInterval
    public let duration: TimeInterval
    public let score: Double
    public let aestheticScore: Double
    public let technicalScore: Double
    public let brightness: Double
    public let faceCount: Int
    public let faceQuality: Double
    public let isUtilityImage: Bool
    public let labels: [String]
    public let semanticScore: Double
    public let semanticLabel: String
    /// Content type used to name and sort the exported clip.
    public let theme: HighlightTheme?
    public let audioScore: Double
    public let audioLabels: [String]
    public let deepAnalysis: DeepAnalysisResult?
    let featurePrint: VNFeaturePrintObservation?
    let semanticEmbedding: [Float]?

    public var end: TimeInterval { start + duration }

    init(
        source: SourceVideo,
        sourceIndex: Int,
        start: TimeInterval,
        duration: TimeInterval,
        score: Double,
        aestheticScore: Double,
        technicalScore: Double,
        brightness: Double,
        faceCount: Int,
        faceQuality: Double,
        isUtilityImage: Bool,
        labels: [String],
        semanticScore: Double,
        semanticLabel: String,
        theme: HighlightTheme? = nil,
        audioScore: Double = 0.5,
        audioLabels: [String] = [],
        deepAnalysis: DeepAnalysisResult? = nil,
        featurePrint: VNFeaturePrintObservation?,
        semanticEmbedding: [Float]?
    ) {
        self.source = source
        self.sourceIndex = sourceIndex
        self.start = start
        self.duration = duration
        self.score = score
        self.aestheticScore = aestheticScore
        self.technicalScore = technicalScore
        self.brightness = brightness
        self.faceCount = faceCount
        self.faceQuality = faceQuality
        self.isUtilityImage = isUtilityImage
        self.labels = labels
        self.semanticScore = semanticScore
        self.semanticLabel = semanticLabel
        self.theme = theme
        self.audioScore = audioScore
        self.audioLabels = audioLabels
        self.deepAnalysis = deepAnalysis
        self.featurePrint = featurePrint
        self.semanticEmbedding = semanticEmbedding
    }

    func applying(
        _ result: DeepAnalysisResult,
        start: TimeInterval,
        duration: TimeInterval
    ) -> HighlightCandidate {
        let combinedScore = 0.35 * score
            + 0.35 * result.highlightScore
            + 0.15 * result.qualityScore
            + 0.15 * result.completenessScore
        return HighlightCandidate(
            source: source,
            sourceIndex: sourceIndex,
            start: start,
            duration: duration,
            score: combinedScore,
            aestheticScore: aestheticScore,
            technicalScore: technicalScore,
            brightness: brightness,
            faceCount: faceCount,
            faceQuality: faceQuality,
            isUtilityImage: isUtilityImage,
            labels: labels,
            semanticScore: semanticScore,
            semanticLabel: result.label,
            theme: result.theme ?? theme,
            audioScore: audioScore,
            audioLabels: audioLabels,
            deepAnalysis: result,
            featurePrint: featurePrint,
            semanticEmbedding: semanticEmbedding
        )
    }

    func applying(_ audio: AudioSummary) -> HighlightCandidate {
        HighlightCandidate(
            source: source,
            sourceIndex: sourceIndex,
            start: start,
            duration: duration,
            score: score * 0.88 + audio.score * 0.12,
            aestheticScore: aestheticScore,
            technicalScore: technicalScore,
            brightness: brightness,
            faceCount: faceCount,
            faceQuality: faceQuality,
            isUtilityImage: isUtilityImage,
            labels: labels,
            semanticScore: semanticScore,
            semanticLabel: semanticLabel,
            theme: theme,
            audioScore: audio.score,
            audioLabels: audio.labels,
            deepAnalysis: deepAnalysis,
            featurePrint: featurePrint,
            semanticEmbedding: semanticEmbedding
        )
    }
}

struct ExportedClip: Codable, Sendable {
    let outputFile: String
    let sourceFile: String
    let sourceCreatedAt: Date
    let sourceModifiedAt: Date
    let startSeconds: Double
    let durationSeconds: Double
    let score: Double
    let semanticLabel: String
    let reason: String?
    /// Added in 0.4.0; absent in older checkpoints.
    let theme: String?
    let clipStartedAt: Date?
    let dayFolder: String?
    let width: Int
    let height: Int
    let nominalFrameRate: Double
    let codec: String
    let hdr: Bool
    let hasAudio: Bool
    let audioLabels: [String]
    let sourceMetadata: [MediaMetadataRecord]
}

struct SelectionReport: Codable, Sendable {
    let generatedAt: Date
    let inputFolder: String
    let outputFolder: String
    let analyzedVideos: Int
    let analyzedCandidates: Int
    let advancedModel: String?
    let selectedThemes: [String]
    let totalOutputDurationSeconds: Double
    let exportedClips: [ExportedClip]
}

public enum TravelCutError: LocalizedError {
    case noVideos
    case noUsableVideos
    case noCandidates
    case noHighlights
    case cannotCreateExporter
    case outputAlreadyExists(String)
    case exportFailed(String)
    case modelUnavailable(String)
    case modelResponseInvalid
    case invalidArguments(String)
    case insufficientOutputSpace(requiredGB: Double, availableGB: Double)

    public var errorDescription: String? {
        switch self {
        case .noVideos: return "所选文件夹中没有找到支持的视频。"
        case .noUsableVideos: return "没有可读取的视频。"
        case .noCandidates: return "没有生成可分析的候选事件。"
        case .noHighlights: return "这批素材中没有找到达到保留标准的高光片段。"
        case .cannotCreateExporter: return "无法创建保持原始规格的导出器。"
        case .outputAlreadyExists(let path): return "输出文件已存在：\(path)"
        case .exportFailed(let reason): return "导出失败：\(reason)"
        case .modelUnavailable(let reason): return "本地模型不可用：\(reason)"
        case .modelResponseInvalid: return "Qwen3-VL 返回了无法解析的分析结果。"
        case .invalidArguments(let reason): return reason
        case .insufficientOutputSpace(let required, let available):
            return String(
                format: "输出磁盘空间不足：预计还需要 %.1f GB（含安全余量），当前约有 %.1f GB。筛选结果已保存；清理空间后再次运行会直接继续导出。",
                required,
                available
            )
        }
    }
}
