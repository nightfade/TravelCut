import Foundation

/// Decides where each exported clip goes: one folder per trip day, clips numbered in
/// shooting order inside it, with the time and content type in the file name. Dragging a
/// day folder into 剪映 then gives that day's timeline in order.
///
///     TravelCut 高光片段/D1_0718_周五/001_0935_自然景观_山顶日出_DJI_0042.mov
///
/// The source file name stays at the end so a clip can be traced without opening the report,
/// while the part 剪映 shows first is sequence, time and content type.
enum ClipOrganizer {
    struct Placement: Equatable {
        let dayFolder: String
        let baseName: String
        let clipStartedAt: Date
        let timeZone: TimeZone
    }

    static let fallbackTheme = "旅行高光"

    /// One placement per candidate, in the same order as `candidates`.
    static func plan(_ candidates: [HighlightCandidate]) -> [Placement] {
        let clips = candidates.map { candidate -> (start: Date, zone: TimeZone, day: DateComponents) in
            let zone = captureTimeZone(candidate.source) ?? .current
            let start = candidate.source.createdAt.addingTimeInterval(candidate.start)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return (start, zone, calendar.dateComponents([.year, .month, .day], from: start))
        }
        guard let firstDay = clips.map(\.day).min(by: isEarlier) else { return [] }

        // Number clips per day in shooting order, independent of the input order.
        var sequence: [Int: Int] = [:]
        var placements = [Placement?](repeating: nil, count: candidates.count)
        let order = clips.indices.sorted { clips[$0].start < clips[$1].start }
        let digits = 3
        for index in order {
            let clip = clips[index]
            let dayNumber = daysBetween(firstDay, clip.day) + 1
            sequence[dayNumber, default: 0] += 1
            let candidate = candidates[index]
            placements[index] = Placement(
                dayFolder: dayFolderName(dayNumber: dayNumber, date: clip.start, zone: clip.zone),
                baseName: baseName(
                    sequence: sequence[dayNumber]!,
                    digits: digits,
                    date: clip.start,
                    zone: clip.zone,
                    theme: candidate.theme?.rawValue,
                    label: candidate.semanticLabel,
                    sourceName: candidate.source.url.deletingPathExtension().lastPathComponent
                ),
                clipStartedAt: clip.start,
                timeZone: clip.zone
            )
        }
        return placements.compactMap { $0 }
    }

    static func dayFolderName(dayNumber: Int, date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = zone
        formatter.dateFormat = "MMdd"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "zh_CN")
        weekdayFormatter.timeZone = zone
        weekdayFormatter.dateFormat = "EEE"   // 周五
        return "D\(dayNumber)_\(formatter.string(from: date))_\(weekdayFormatter.string(from: date))"
    }

    static func baseName(
        sequence: Int,
        digits: Int,
        date: Date,
        zone: TimeZone,
        theme: String?,
        label: String,
        sourceName: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HHmm"
        let themeName = sanitized(theme ?? "", maximumUTF8Bytes: 24)
        let labelName = sanitized(label, maximumUTF8Bytes: 48)
        var parts = [String(format: "%0*d", digits, sequence), formatter.string(from: date)]
        parts.append(themeName.isEmpty ? fallbackTheme : themeName)
        // The fast pass labels clips with the theme name itself; don't repeat it.
        if !labelName.isEmpty, labelName != themeName { parts.append(labelName) }
        let source = sanitized(sourceName, maximumUTF8Bytes: 96, keepUnderscores: true)
        parts.append(source.isEmpty ? "原视频" : source)
        return parts.joined(separator: "_")
    }

    /// The offset the camera recorded with the date, when it wrote one
    /// (iPhone, DJI and others put it in `com.apple.quicktime.creationdate`).
    /// Without it, clips use this Mac's time zone.
    static func captureTimeZone(_ source: SourceVideo) -> TimeZone? {
        guard let value = source.metadata.first(where: {
            ($0.identifier ?? $0.key ?? "").contains("com.apple.quicktime.creationdate")
        })?.value else { return nil }
        return timeZone(fromISO8601: value)
    }

    static func timeZone(fromISO8601 value: String) -> TimeZone? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) }
        // ±HH:MM or ±HHMM at the end, after the time part.
        guard let tIndex = text.firstIndex(of: "T"),
              let signIndex = text[tIndex...].lastIndex(where: { $0 == "+" || $0 == "-" })
        else { return nil }
        let digits = text[text.index(after: signIndex)...].filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
              hours <= 14, minutes < 60
        else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (text[signIndex] == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    static func sanitized(_ value: String, maximumUTF8Bytes: Int, keepUnderscores: Bool = false) -> String {
        // Underscores separate the name's fields, so they are only kept in the trailing source name.
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t" + (keepUnderscores ? "" : "_"))
        let clean = value.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in clean {
            let next = result + String(character)
            if next.utf8.count > maximumUTF8Bytes { break }
            result = next
        }
        return result
    }

    private static func isEarlier(_ lhs: DateComponents, _ rhs: DateComponents) -> Bool {
        (lhs.year ?? 0, lhs.month ?? 0, lhs.day ?? 0) < (rhs.year ?? 0, rhs.month ?? 0, rhs.day ?? 0)
    }

    /// Calendar days between two dates, so a day without clips still advances the number.
    private static func daysBetween(_ from: DateComponents, _ to: DateComponents) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = calendar.date(from: from), let end = calendar.date(from: to) else { return 0 }
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}

extension TravelCutDiagnostics {
    public static func organizationSelfTest() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let paris = TimeZone(secondsFromGMT: 3600)!
        func source(_ name: String, _ iso: String, offset: String?) -> SourceVideo {
            let formatter = ISO8601DateFormatter()
            let metadata = offset.map {
                [MediaMetadataRecord(
                    identifier: "mdta/com.apple.quicktime.creationdate",
                    keySpace: "mdta",
                    key: "com.apple.quicktime.creationdate",
                    value: $0
                )]
            } ?? []
            return SourceVideo(
                url: URL(fileURLWithPath: "/tmp/\(name).mov"),
                duration: 600,
                createdAt: formatter.date(from: iso)!,
                hasAudio: true,
                metadata: metadata
            )
        }
        func candidate(_ source: SourceVideo, start: TimeInterval, theme: HighlightTheme?, label: String) -> HighlightCandidate {
            HighlightCandidate(
                source: source, sourceIndex: 0, start: start, duration: 5, score: 0.9,
                aestheticScore: 0.5, technicalScore: 0.5, brightness: 0.5, faceCount: 0,
                faceQuality: 0, isUtilityImage: false, labels: [], semanticScore: 0.5,
                semanticLabel: label, theme: theme, featurePrint: nil, semanticEmbedding: nil
            )
        }

        // 2026-07-17 Fri 23:58 Paris, 2026-07-18 00:03 Paris, a gap day, then 2026-07-20.
        let lateNight = source("A", "2026-07-17T22:58:00Z", offset: "2026-07-17T23:58:00+0100")
        let nextDay = source("B", "2026-07-18T08:30:00Z", offset: "2026-07-18T09:30:00+01:00")
        let afterGap = source("C", "2026-07-20T11:00:00Z", offset: "2026-07-20T12:00:00+0100")
        let candidates = [
            candidate(afterGap, start: 0, theme: .food, label: "烤串"),
            candidate(lateNight, start: 300, theme: .people, label: "人物互动"),   // 00:03 next day
            candidate(lateNight, start: 0, theme: nil, label: "夜景"),
            candidate(nextDay, start: 0, theme: .nature, label: "山顶/日出"),
        ]
        let plan = ClipOrganizer.plan(candidates)
        expect(plan.count == 4, "every clip gets a placement")
        if plan.count == 4 {
            expect(plan[2].dayFolder == "D1_0717_周五", "first day folder uses capture zone and weekday, got \(plan[2].dayFolder)")
            expect(plan[2].baseName == "001_2358_旅行高光_夜景_A", "missing theme falls back, got \(plan[2].baseName)")
            expect(plan[1].dayFolder == "D2_0718_周六", "clip after midnight moves to the next day, got \(plan[1].dayFolder)")
            expect(plan[1].baseName == "001_0003_人物互动_A", "label equal to theme is not repeated, got \(plan[1].baseName)")
            expect(plan[3].baseName == "002_0930_自然景观_山顶-日出_B", "per-day numbering follows shooting time, got \(plan[3].baseName)")
            expect(plan[0].dayFolder == "D4_0720_周一", "a day without clips still counts, got \(plan[0].dayFolder)")
            expect(plan[0].timeZone.secondsFromGMT() == paris.secondsFromGMT(), "capture offset is used")
        }

        expect(ClipOrganizer.timeZone(fromISO8601: "2026-07-18T09:30:00-0700")?.secondsFromGMT() == -25200,
               "negative offsets parse")
        expect(ClipOrganizer.timeZone(fromISO8601: "2026-07-18T09:30:00Z")?.secondsFromGMT() == 0, "Z parses as UTC")
        expect(ClipOrganizer.timeZone(fromISO8601: "2026-07-18T09:30:00") == nil, "no offset means unknown")
        expect(ClipOrganizer.captureTimeZone(source("D", "2026-07-18T09:30:00Z", offset: nil)) == nil,
               "sources without the QuickTime date fall back to this Mac")

        let schema = QwenVideoAnalyzer.responseSchema(themes: [.nature, .food])
        expect(schema.contains(#""enum":["自然景观","当地美食"]"#), "Qwen schema limits theme to the selection")
        expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil, "Qwen schema is valid JSON")
        return failures
    }
}

extension TravelCutDiagnostics {
    /// Real export through AVFoundation into day folders, skipping clip selection.
    /// `sample` must carry `com.apple.quicktime.creationdate` with an offset and be at least 12 s long.
    public static func exportSelfTest(sample: URL) async -> [String] {
        var failures: [String] = []
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("TravelCut-export-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        guard let source = await MediaDiscovery.probe([sample]).first else {
            return ["export test: cannot read \(sample.path)"]
        }
        guard let zone = ClipOrganizer.captureTimeZone(source) else {
            return ["export test: sample has no QuickTime creation date with an offset"]
        }
        func candidate(start: TimeInterval, theme: HighlightTheme, label: String) -> HighlightCandidate {
            HighlightCandidate(
                source: source, sourceIndex: 0, start: start, duration: 3, score: 0.9,
                aestheticScore: 0.5, technicalScore: 0.5, brightness: 0.5, faceCount: 0,
                faceQuality: 0, isUtilityImage: false, labels: [], semanticScore: 0.5,
                semanticLabel: label, theme: theme, featurePrint: nil, semanticEmbedding: nil
            )
        }
        let candidates = [
            candidate(start: 1, theme: .nature, label: "湖边"),
            candidate(start: 8, theme: .people, label: "人物互动"),
        ]
        let configuration = JobConfiguration(
            inputFolder: sample.deletingLastPathComponent(),
            outputFolder: output,
            useDeepAnalysis: false
        )
        do {
            let clips = try await ClipExporter.export(candidates: candidates, configuration: configuration) { _, _, _ in }
            let expected = ClipOrganizer.plan(candidates)
            if clips.count != 2 { failures.append("export test: expected 2 clips, got \(clips.count)") }
            for (clip, placement) in zip(clips, expected) {
                let url = URL(fileURLWithPath: clip.outputFile)
                let relative = url.path.replacingOccurrences(of: output.path + "/", with: "")
                if relative != "\(placement.dayFolder)/\(placement.baseName).\(url.pathExtension)" {
                    failures.append("export test: unexpected path \(relative)")
                }
                let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                if let created, abs(created.timeIntervalSince(placement.clipStartedAt)) > 1 {
                    failures.append("export test: file date \(created) is not the clip start \(placement.clipStartedAt)")
                }
                if clip.theme == nil || clip.dayFolder != placement.dayFolder {
                    failures.append("export test: report fields missing for \(relative)")
                }
                if let reread = await MediaDiscovery.probe([url]).first,
                   ClipOrganizer.captureTimeZone(reread)?.secondsFromGMT() != zone.secondsFromGMT() {
                    failures.append("export test: \(relative) lost the capture offset")
                }
            }
            if expected.first?.timeZone.secondsFromGMT() != zone.secondsFromGMT() {
                failures.append("export test: capture zone not applied")
            }
            print("export test wrote:")
            clips.forEach { print("  " + $0.outputFile.replacingOccurrences(of: output.path + "/", with: "")) }
        } catch {
            failures.append("export test failed: \(error.localizedDescription)")
        }
        return failures
    }
}
