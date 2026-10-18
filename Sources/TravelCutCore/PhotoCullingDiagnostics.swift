import CoreGraphics
import Foundation

extension TravelCutDiagnostics {
    public static func photoCullingSelfTest() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append("photo: " + message) }
        }

        // Grouping: a burst, a re-shoot of the same scene within a minute, then a new scene.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let times = [0, 0.4, 0.9, 40, 200, 201].map { base.addingTimeInterval($0) }
        let distances: [Int: Float] = [1: 0.6, 2: 0.3, 3: 0.40, 4: 0.9, 5: 0.2]   // to the previous photo
        let oneFolder = [String](repeating: "/trip", count: times.count)
        let groups = PhotoGrouper.group(times: times, folders: oneFolder) { _, j in distances[j] }
        expect(groups == [[0, 1, 2, 3], [4, 5]], "grouping gives contiguous groups, got \(groups)")
        let split = PhotoGrouper.group(times: times, folders: oneFolder) { _, _ in 0.95 }
        expect(split.count == 6, "dissimilar shots are never grouped")
        // Two cameras in two folders shooting the same burst at the same time.
        let twoCameras = PhotoGrouper.group(
            times: [0, 0.1, 0.5, 0.6].map { base.addingTimeInterval($0) },
            folders: ["/S9", "/X100", "/S9", "/X100"]
        ) { _, _ in 0.1 }
        expect(twoCameras == [[0, 2], [1, 3]], "groups never span folders, got \(twoCameras)")
        // A blurred frame inside a burst looks like a different scene but belongs to the burst.
        let blurred = PhotoGrouper.group(
            times: [0, 0.5, 1.0, 30].map { base.addingTimeInterval($0) },
            folders: ["/t", "/t", "/t", "/t"], junk: [false, false, true, true]
        ) { _, j in [1: 0.1, 2: 0.9, 3: 0.9][j] }
        expect(blurred == [[0, 1, 2], [3]], "junk frames join their burst only within the burst gap, got \(blurred)")

        // Rating.
        let plain = PhotoRater.rate(pickScores: [0.5, 0.9, 0.88, 0.2], junk: [false, false, false, true], judgement: nil)
        expect(plain.ratings == [0, 3, 2, -1], "best 3, close alternate 2, junk rejected, got \(plain.ratings)")
        expect(plain.order == [1, 2, 0, 3], "ranking puts rejects last, got \(plain.order)")
        expect(PhotoRater.standoutThreshold(keptScores: [0.85, 0.85, 0.85, 0.85, 0.9]) == 0.9,
               "standout is relative when Qwen scores everything alike")
        expect(PhotoRater.standoutThreshold(keptScores: [0.5, 0.6, 0.7]) == 0.82, "standout never drops below 0.82")
        let tied = PhotoRater.standoutThreshold(keptScores: [0.85, 0.85, 0.85, 0.85, 0.85, 0.85, 0.9])
        expect(tied > 0.85 && tied <= 0.9, "a score most groups share is not a standout, got \(tied)")
        let qwenPick = PhotoGroupJudgement(bestMember: 2, keep: true, highlightScore: 0.9, theme: .nature, label: "湖边", reason: nil)
        let picked = PhotoRater.rate(pickScores: [0.5, 0.9, 0.88], junk: [false, false, false], judgement: qwenPick)
        expect(picked.ratings == [0, 2, 4], "Qwen's choice wins and a standout gets 4, got \(picked.ratings)")
        let dropped = PhotoGroupJudgement(bestMember: 0, keep: false, highlightScore: 0.3, theme: nil, label: nil, reason: nil)
        let weak = PhotoRater.rate(pickScores: [0.6, 0.59, 0.58], junk: [false, false, false], judgement: dropped)
        expect(weak.ratings == [2, 0, 0], "a group Qwen would drop keeps its best at 2 with no alternate, got \(weak.ratings)")
        let allJunk = PhotoRater.rate(pickScores: [0.1, 0.2], junk: [true, true], judgement: nil)
        expect(allJunk.ratings == [-1, -1] && allJunk.best == nil, "an all-junk group is rejected")
        expect(PhotoRater.title(group: 42, rank: 1, size: 5) == "组 0042 · 第 1/5", "group title")
        expect(PhotoRater.title(group: 7, rank: 1, size: 1) == "组 0007", "single photo title")

        // EXIF dates and eyes.
        if let (date, zone) = PhotoDiscovery.parseExifDate("2026:11:28 10:15:30", subsec: "25", offset: "+01:00") {
            expect(zone.secondsFromGMT() == 3600, "EXIF offset is used")
            expect(abs(date.timeIntervalSince1970 - 1_795_857_330.25) < 0.001, "EXIF date with sub-seconds, got \(date.timeIntervalSince1970)")
        } else {
            expect(false, "EXIF date parses")
        }
        let open = [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.65), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 0.35)]
        let shut = [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.53), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 0.47)]
        expect(!PhotoAnalyzer.isClosed(open) && PhotoAnalyzer.isClosed(shut), "eye openness")

        let schema = QwenVideoAnalyzer.photoSchema(count: 3, themes: [.nature, .people])
        expect(schema.contains(#""enum":[1,2,3]"#), "photo schema limits best to the shown photos")
        expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil, "photo schema is valid JSON")

        failures += xmpSelfTest()
        return failures
    }

    private static func xmpSelfTest() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append("xmp: " + message) }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TravelCut-xmp-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fields = XMPSidecarWriter.Fields(
            rating: 3, title: "组 0042 · 第 1/5",
            keywords: [["TravelCut", "组", "组 0042"], ["TravelCut", "主题", "自然景观"]]
        )
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func values(_ url: URL, _ xpath: String) -> [String] {
            guard let document = try? XMLDocument(contentsOf: url, options: []),
                  let nodes = try? document.nodes(forXPath: xpath) else { return [] }
            return nodes.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        func rating(_ url: URL) -> [String] {
            guard let document = try? XMLDocument(contentsOf: url, options: []),
                  let descriptions = try? document.nodes(forXPath: "//*[local-name()='Description']") as? [XMLElement]
            else { return [] }
            return descriptions.compactMap {
                $0.attribute(forLocalName: "Rating", uri: XMPSidecarWriter.xmpNS)?.stringValue
            }
        }
        let subjectPath = "//*[local-name()='subject']//*[local-name()='li']"
        let hierPath = "//*[local-name()='hierarchicalSubject']//*[local-name()='li']"

        // 1. New sidecar.
        let fresh = folder.appendingPathComponent("A.xmp")
        expect((try? XMPSidecarWriter.apply(fields, to: fresh)) == .written, "new sidecar is written")
        expect(rating(fresh) == ["3"], "new sidecar has the rating, got \(rating(fresh))")
        expect(values(fresh, "//*[local-name()='title']//*[local-name()='li']") == ["组 0042 · 第 1/5"], "title written")
        expect(Set(values(fresh, hierPath)) == ["TravelCut|组|组 0042", "TravelCut|主题|自然景观"], "hierarchical keywords")
        expect(Set(values(fresh, subjectPath)) == ["组 0042", "自然景观"], "flat keywords")

        // 2. Re-run replaces TravelCut's own values without duplicating keywords.
        let rerun = XMPSidecarWriter.Fields(rating: 2, title: "组 0043 · 第 2/3",
                                            keywords: [["TravelCut", "组", "组 0043"]])
        expect((try? XMPSidecarWriter.apply(rerun, to: fresh)) == .written, "re-run on own sidecar is written")
        expect(rating(fresh) == ["2"], "re-run updates the rating")
        expect(values(fresh, hierPath) == ["TravelCut|组|组 0043"], "re-run replaces old keywords, got \(values(fresh, hierPath))")

        // 3. User changed the rating after TravelCut wrote it: hands off.
        try? read(fresh).replacingOccurrences(of: "xmp:Rating=\"2\"", with: "xmp:Rating=\"4\"")
            .write(to: fresh, atomically: true, encoding: .utf8)
        let changedByUser = read(fresh)
        expect(changedByUser.contains("xmp:Rating=\"4\""), "test setup: user rating applied")
        expect((try? XMPSidecarWriter.apply(fields, to: fresh)) == .skippedUserMarks, "user-changed rating is respected")
        expect(read(fresh) == changedByUser, "skipped sidecar is left byte for byte")

        // 4. Camera Raw sidecar without a rating: edits and user keywords survive.
        let edited = folder.appendingPathComponent("B.xmp")
        try? """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmp:CreatorTool="Adobe Bridge 2025"
           crs:Version="17.0"
           crs:Exposure2012="+0.50"
           crs:Temperature="5600">
           <dc:subject><rdf:Bag><rdf:li>巴黎</rdf:li></rdf:Bag></dc:subject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.write(to: edited, atomically: true, encoding: .utf8)
        expect((try? XMPSidecarWriter.apply(fields, to: edited)) == .written, "Camera Raw sidecar is written")
        let after = read(edited)
        expect(after.contains("crs:Exposure2012=\"+0.50\"") && after.contains("crs:Temperature=\"5600\""), "Camera Raw edits kept")
        expect(after.contains("Adobe Bridge 2025"), "other metadata kept")
        expect(Set(values(edited, subjectPath)) == ["巴黎", "组 0042", "自然景观"], "user keywords kept, got \(values(edited, subjectPath))")
        expect(rating(edited) == ["3"], "rating added to Camera Raw sidecar")

        // 5. User marks: attribute rating, element rating, colour label.
        let marks = [
            ("C", #"xmp:Rating="5""#, ""),
            ("D", "", "<xmp:Rating>5</xmp:Rating>"),
            ("E", #"xmp:Label="红色""#, ""),
        ]
        for (name, attribute, element) in marks {
            let url = folder.appendingPathComponent("\(name).xmp")
            let original = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \(attribute)>\(element)</rdf:Description>\
            </rdf:RDF></x:xmpmeta>
            """
            try? original.write(to: url, atomically: true, encoding: .utf8)
            expect((try? XMPSidecarWriter.apply(fields, to: url)) == .skippedUserMarks, "\(name): user mark is respected")
            expect(read(url) == original, "\(name): left byte for byte")
        }
        return failures
    }
}
