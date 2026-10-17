import Foundation
import Vision

public enum HighlightSelector {
    public static func candidatesForDeepAnalysis(
        from candidates: [HighlightCandidate],
        fraction: Double
    ) -> [HighlightCandidate] {
        let eligible = candidates.filter(isTechnicallyEligible)
        guard !eligible.isEmpty else { return [] }
        let desiredCount = min(
            eligible.count,
            max(min(120, eligible.count), Int(ceil(Double(eligible.count) * fraction)))
        )
        return Array(eligible.sorted { $0.score > $1.score }.prefix(desiredCount))
            .sorted(by: chronologicalOrder)
    }

    public static func select(
        from candidates: [HighlightCandidate],
        requiresDeepAnalysis: Bool
    ) -> [HighlightCandidate] {
        let eligible: [HighlightCandidate]
        if requiresDeepAnalysis {
            eligible = candidates.filter { candidate in
                guard isTechnicallyEligible(candidate), let deep = candidate.deepAnalysis else {
                    return false
                }
                return deep.keep
                    && deep.highlightScore >= 0.58
                    && deep.qualityScore >= 0.35
                    && deep.completenessScore >= 0.35
            }
        } else {
            let scores = candidates.filter(isFastPassEligible).map(\.score).sorted()
            guard !scores.isEmpty else { return [] }
            let index = min(scores.count - 1, Int(Double(scores.count - 1) * 0.65))
            let threshold = max(0.28, scores[index])
            eligible = candidates.filter { isFastPassEligible($0) && $0.score >= threshold }
        }

        var selected: [HighlightCandidate] = []
        for candidate in eligible.sorted(by: { $0.score > $1.score }) {
            if !isDuplicate(candidate, among: selected), !overlaps(candidate, selected) {
                selected.append(candidate)
            }
        }
        return mergeOverlappingChunks(selected.sorted(by: chronologicalOrder))
    }

    private static func isTechnicallyEligible(_ candidate: HighlightCandidate) -> Bool {
        return !candidate.isUtilityImage
            && candidate.brightness > 0.025
            && candidate.brightness < 0.975
            && candidate.technicalScore >= 0.18
            && candidate.duration >= 0.1
    }

    private static func isFastPassEligible(_ candidate: HighlightCandidate) -> Bool {
        let rejectedLabels: Set<String> = ["误拍废片", "遮挡镜头", "空白画面", "屏幕文件", "低价值画面"]
        return isTechnicallyEligible(candidate) && !rejectedLabels.contains(candidate.semanticLabel)
    }

    private static func mergeOverlappingChunks(
        _ candidates: [HighlightCandidate]
    ) -> [HighlightCandidate] {
        var merged: [HighlightCandidate] = []
        for candidate in candidates {
            guard let previous = merged.last,
                  previous.source.url == candidate.source.url,
                  candidate.start < previous.end
            else {
                merged.append(candidate)
                continue
            }
            let strongest = previous.score >= candidate.score ? previous : candidate
            let start = min(previous.start, candidate.start)
            let end = max(previous.end, candidate.end)
            merged[merged.count - 1] = HighlightCandidate(
                source: strongest.source,
                sourceIndex: strongest.sourceIndex,
                start: start,
                duration: end - start,
                score: max(previous.score, candidate.score),
                aestheticScore: max(previous.aestheticScore, candidate.aestheticScore),
                technicalScore: min(previous.technicalScore, candidate.technicalScore),
                brightness: (previous.brightness + candidate.brightness) / 2,
                faceCount: max(previous.faceCount, candidate.faceCount),
                faceQuality: max(previous.faceQuality, candidate.faceQuality),
                isUtilityImage: false,
                labels: Array(Set(previous.labels + candidate.labels)),
                semanticScore: max(previous.semanticScore, candidate.semanticScore),
                semanticLabel: strongest.semanticLabel,
                audioScore: max(previous.audioScore, candidate.audioScore),
                audioLabels: Array(Set(previous.audioLabels + candidate.audioLabels)),
                deepAnalysis: strongest.deepAnalysis,
                featurePrint: strongest.featurePrint,
                semanticEmbedding: strongest.semanticEmbedding
            )
        }
        return merged
    }

    private static func isDuplicate(
        _ candidate: HighlightCandidate,
        among selected: [HighlightCandidate]
    ) -> Bool {
        for existing in selected {
            if let left = candidate.semanticEmbedding,
               let right = existing.semanticEmbedding,
               MobileCLIPAnalyzer.cosine(left, right) > 0.972
            {
                return true
            }
            guard let left = candidate.featurePrint, let right = existing.featurePrint else { continue }
            var distance: Float = 0
            if (try? left.computeDistance(&distance, to: right)) != nil, distance < 0.25 {
                return true
            }
        }
        return false
    }

    private static func overlaps(
        _ candidate: HighlightCandidate,
        _ selected: [HighlightCandidate]
    ) -> Bool {
        selected.contains { existing in
            guard existing.source.url == candidate.source.url else { return false }
            let overlapStart = max(existing.start, candidate.start)
            let overlapEnd = min(existing.end, candidate.end)
            guard overlapEnd > overlapStart else { return false }
            let overlap = overlapEnd - overlapStart
            return overlap / min(existing.duration, candidate.duration) > 0.55
        }
    }

    private static func chronologicalOrder(
        _ lhs: HighlightCandidate,
        _ rhs: HighlightCandidate
    ) -> Bool {
        if lhs.source.createdAt != rhs.source.createdAt {
            return lhs.source.createdAt < rhs.source.createdAt
        }
        if lhs.source.url != rhs.source.url {
            return lhs.source.url.path.localizedStandardCompare(rhs.source.url.path) == .orderedAscending
        }
        return lhs.start < rhs.start
    }
}
