import Foundation

/// Groups photos taken back to back of the same scene. Groups are always contiguous in
/// shooting time and never span folders, so sorting by date in Bridge keeps every group together
/// in the folder being viewed.
enum PhotoGrouper {
    /// Bursts: always one group when shots are this close and still look alike.
    static let burstGap: TimeInterval = 2
    static let burstDistance: Float = 0.70
    /// Same scene shot again a little later, or from a slightly different angle.
    static let sceneGap: TimeInterval = 60
    static let sceneDistance: Float = 0.45
    /// A group never spans more than this from its first photo. Without it, walking down a street
    /// shooting every few seconds chained 47 different houses into one group.
    static let maxSpan: TimeInterval = 90

    /// `distance(i, j)` is the Vision feature-print distance between photos i and j, nil if unknown.
    /// `junk` marks unusable frames: a blurred frame is as far from its burst (≈0.9) as a different
    /// scene is, so within a burst a junk frame joins on timing alone.
    static func group(
        times: [Date], folders: [String], junk: [Bool] = [], distance: (Int, Int) -> Float?
    ) -> [[Int]] {
        // Shooting order within each folder; folders keep the order of their first photo.
        var lastIndexInFolder: [String: Int] = [:]
        var groupOfIndex: [Int: Int] = [:]
        var groups: [[Int]] = []
        var groupStart: [Date] = []
        for index in times.indices {
            let folder = folders[index]
            guard let previous = lastIndexInFolder[folder], let groupIndex = groupOfIndex[previous],
                  groups[groupIndex].last == previous
            else {
                groups.append([index])
                groupStart.append(times[index])
                groupOfIndex[index] = groups.count - 1
                lastIndexInFolder[folder] = index
                continue
            }
            lastIndexInFolder[folder] = index
            let gap = times[index].timeIntervalSince(times[previous])
            let d = distance(previous, index)
            let isJunk = { (i: Int) in i < junk.count && junk[i] }
            let joins: Bool
            if times[index].timeIntervalSince(groupStart[groupIndex]) > maxSpan {
                joins = false
            } else if gap <= burstGap, isJunk(index) || isJunk(previous) {
                joins = true
            } else if let d {
                joins = (gap <= burstGap && d <= burstDistance) || (gap <= sceneGap && d <= sceneDistance)
            } else {
                joins = gap <= 0.5
            }
            if joins {
                groups[groupIndex].append(index)
                groupOfIndex[index] = groupIndex
            } else {
                groups.append([index])
                groupStart.append(times[index])
                groupOfIndex[index] = groups.count - 1
            }
        }
        return groups
    }
}

/// What Qwen said about a group, or nil fields when it was not asked.
struct PhotoGroupJudgement: Codable, Sendable {
    let bestMember: Int?        // index into the group's members
    let keep: Bool?
    let highlightScore: Double?
    let theme: HighlightTheme?
    let label: String?
    let reason: String?
}

/// Star ratings for one group. Stars mark group representatives, not quality: checked against the
/// photos the user edited from a 9,000-photo trip, neither Qwen's scores nor any technical score
/// predicted which frame the user would keep, so no 4 stars until a taste model exists.
///
/// - best of the group (Qwen's pick when it gave one): 3 stars, 2 when Qwen would not keep the group
/// - close alternatives: 2 stars, up to one per four photos, within 95% of the best's score
/// - clearly unusable frames: rejected
/// - everything else: left unrated
enum PhotoRater {
    static let alternateRatio = 0.95
    static let alternatesPer = 4

    struct Result: Equatable {
        let ratings: [Int]   // per member: -1 rejected, 0 unrated, 1...5 stars
        let order: [Int]     // members from best to worst, for the "第 k/n" title
        let best: Int?
    }

    static func rate(pickScores: [Double], junk: [Bool], judgement: PhotoGroupJudgement?) -> Result {
        let count = pickScores.count
        var ratings = [Int](repeating: 0, count: count)
        let usable = (0..<count).filter { !junk[$0] }.sorted { pickScores[$0] > pickScores[$1] }
        for index in 0..<count where junk[index] { ratings[index] = -1 }

        guard let technicalBest = usable.first else {
            return Result(ratings: ratings, order: (0..<count).sorted { pickScores[$0] > pickScores[$1] }, best: nil)
        }
        var best = technicalBest
        if let chosen = judgement?.bestMember, usable.contains(chosen) { best = chosen }
        ratings[best] = judgement?.keep == false ? 2 : 3

        let others = usable.filter { $0 != best }
        if judgement?.keep != false {
            let quota = Int((Double(count) / Double(alternatesPer)).rounded(.up))
            for alternate in others.prefix(quota) where pickScores[alternate] >= pickScores[best] * alternateRatio {
                ratings[alternate] = 2
            }
        }
        let rejected = (0..<count).filter { junk[$0] }.sorted { pickScores[$0] > pickScores[$1] }
        return Result(ratings: ratings, order: [best] + others + rejected, best: best)
    }

    static func title(group: Int, rank: Int, size: Int) -> String {
        size == 1 ? String(format: "组 %04d", group) : String(format: "组 %04d · 第 %d/%d", group, rank, size)
    }
}
