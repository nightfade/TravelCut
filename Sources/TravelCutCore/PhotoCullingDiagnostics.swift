import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        let qwenPick = PhotoGroupJudgement(bestMember: 2, keep: true, highlightScore: 0.9, theme: .nature, label: "湖边", reason: nil)
        let picked = PhotoRater.rate(pickScores: [0.5, 0.9, 0.88], junk: [false, false, false], judgement: qwenPick)
        expect(picked.ratings == [0, 2, 3], "Qwen's choice gets 3 and the technical best becomes the alternate, got \(picked.ratings)")
        let dropped = PhotoGroupJudgement(bestMember: 0, keep: false, highlightScore: 0.3, theme: nil, label: nil, reason: nil)
        let weak = PhotoRater.rate(pickScores: [0.6, 0.59, 0.58], junk: [false, false, false], judgement: dropped)
        expect(weak.ratings == [2, 0, 0], "a group Qwen would drop keeps its best at 2 with no alternate, got \(weak.ratings)")
        let session = PhotoRater.rate(pickScores: [1, 0.99, 0.98, 0.97, 0.5, 0.96, 0.4, 0.3], junk: [Bool](repeating: false, count: 8), judgement: nil)
        expect(session.ratings.filter { $0 == 2 }.count == 2, "one close alternate per four photos, got \(session.ratings)")
        let allJunk = PhotoRater.rate(pickScores: [0.1, 0.2], junk: [true, true], judgement: nil)
        expect(allJunk.ratings == [-1, -1] && allJunk.best == nil, "an all-junk group is rejected")
        expect(PhotoRater.title(group: 42, rank: 1, size: 5) == "组 0042 · 第 1/5", "group title")
        expect(PhotoRater.title(group: 7, rank: 1, size: 1) == "组 0007", "single photo title")
        expect(PhotoRater.title(group: 42, rank: 2, size: 5, label: "父女共读") == "组 0042 · 第 2/5 · 父女共读", "title with Qwen label")

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

        // A group never spans more than 90 s from its first photo, however similar each step is.
        let walk = PhotoGrouper.group(
            times: [0, 40, 80, 120, 160].map { base.addingTimeInterval($0) },
            folders: [String](repeating: "/t", count: 5)
        ) { _, _ in 0.1 }
        expect(walk == [[0, 1, 2], [3, 4]], "groups are capped at 90 s, got \(walk)")

        // Embedded metadata (JPEG): ownership rules and the arguments sent to exiftool.
        typealias E = EmbeddedMetadataWriter.Existing
        expect(EmbeddedMetadataWriter.decide(E(rating: 0, label: "", title: "", hierarchical: [])), "fresh JPEG is written")
        expect(!EmbeddedMetadataWriter.decide(E(rating: 5, label: "", title: "", hierarchical: [])), "user rating is respected")
        expect(!EmbeddedMetadataWriter.decide(E(rating: 0, label: "红色", title: "", hierarchical: [])), "user label is respected")
        expect(EmbeddedMetadataWriter.decide(E(rating: 3, label: "", title: "", hierarchical: ["TravelCut|写入星级|3"])), "own rating may be replaced")
        expect(!EmbeddedMetadataWriter.decide(E(rating: 4, label: "", title: "", hierarchical: ["TravelCut|写入星级|3"])), "changed own rating is respected")
        let job = EmbeddedMetadataWriter.Job(file: URL(fileURLWithPath: "/t/A.JPG"), fields: .init(
            rating: 2, title: "组 0001 · 第 2/3", keywords: [["TravelCut", "组", "组 0001"]]))
        let args = EmbeddedMetadataWriter.arguments(for: job, existing: E(
            rating: 3, label: "", title: "我的标题", hierarchical: ["TravelCut|组|组 0009", "TravelCut|写入星级|3", "巴黎"]))
        expect(args.contains("-XMP-xmp:Rating=2") && args.last == "/t/A.JPG", "rating argument and file last")
        expect(!args.contains { $0.hasPrefix("-XMP-dc:Title") }, "a user's own title is kept")
        expect(args.contains("-XMP-lr:HierarchicalSubject-=TravelCut|组|组 0009") && args.contains("-XMP-dc:Subject-=组 0009"),
               "old TravelCut keywords are removed")
        expect(!args.contains { $0.contains("巴黎") }, "user keywords are untouched")
        expect(args.contains("-XMP-lr:HierarchicalSubject+=TravelCut|写入星级|2"), "new ownership marker")
        // Organising only (no stars): rated photos are written, the rating is left alone, old own ratings cleared.
        let organise = EmbeddedMetadataWriter.Job(file: URL(fileURLWithPath: "/t/B.JPG"), fields: .init(
            rating: nil, title: "组 0002 · 第 1/2", keywords: [["TravelCut", "组", "组 0002"]]))
        let userRated = EmbeddedMetadataWriter.arguments(for: organise, existing: E(rating: 5, label: "红色", title: "", hierarchical: []))
        expect(!userRated.contains { $0.hasPrefix("-XMP-xmp:Rating") } && !userRated.contains { $0.contains("写入星级") },
               "no stars: user rating untouched and no marker, got \(userRated)")
        expect(userRated.contains("-XMP-lr:HierarchicalSubject+=TravelCut|组|组 0002"), "no stars: keywords still written")
        let oldOwn = EmbeddedMetadataWriter.arguments(for: organise, existing: E(rating: 3, label: "", title: "", hierarchical: ["TravelCut|写入星级|3"]))
        expect(oldOwn.contains("-XMP-xmp:Rating=0") && oldOwn.contains("-XMP-lr:HierarchicalSubject-=TravelCut|写入星级|3"),
               "no stars: an unchanged old TravelCut rating is cleared with its marker")
        let changedOld = EmbeddedMetadataWriter.arguments(for: organise, existing: E(rating: 4, label: "", title: "", hierarchical: ["TravelCut|写入星级|3"]))
        expect(!changedOld.contains { $0.hasPrefix("-XMP-xmp:Rating") }, "no stars: a rating the user changed is kept")

        failures += placeSelfTest()
        failures += cacheSelfTest()
        failures += previewSelfTest()
        failures += xmpSelfTest()
        return failures
    }

    /// A file whose embedded thumbnail is tiny (as in Sony ARW) must still yield a usable preview.
    private static func previewSelfTest() -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TravelCut-thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let context = CGContext(
            data: nil, width: 2000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return ["photo: preview test setup failed"] }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1500))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return ["photo: preview test setup failed"] }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationEmbedThumbnail: true,
            kCGImageDestinationImageMaxPixelSize: 2000,
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)

        var failures: [String] = []
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
               kCGImageSourceThumbnailMaxPixelSize: 1024,
           ] as CFDictionary),
           max(embedded.width, embedded.height) >= 1000 {
            failures.append("photo: test setup did not produce a small embedded thumbnail (\(embedded.width)px)")
        }
        // Local sharpness: a fine pattern is sharp, the same pattern blurred is junk.
        if let pattern = makeChecker(), let blurred = blur(pattern) {
            let sharp = PhotoAnalyzer.localSharpness(of: pattern), soft = PhotoAnalyzer.localSharpness(of: blurred)
            if sharp < 0.3 { failures.append("photo: sharp pattern scored \(sharp)") }
            if soft >= PhotoMetrics.blurThreshold { failures.append("photo: blurred pattern scored \(soft)") }
        }
        let preview = PhotoDiscovery.preview(of: url)
        if (preview.map { max($0.width, $0.height) } ?? 0) < 1000 {
            failures.append("photo: tiny embedded thumbnail was used, got \(preview?.width ?? 0)px")
        }
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

        // 6. Organising only (no stars).
        let organise = XMPSidecarWriter.Fields(rating: nil, title: "组 0007 · 第 1/2", keywords: [["TravelCut", "组", "组 0007"]])
        let rated = folder.appendingPathComponent("C.xmp")   // user rated 5 in case 5
        expect((try? XMPSidecarWriter.apply(organise, to: rated)) == .written, "no stars: a user-rated photo still gets organised")
        expect(rating(rated) == ["5"], "no stars: the user's rating is untouched, got \(rating(rated))")
        expect(values(rated, hierPath) == ["TravelCut|组|组 0007"], "no stars: keywords written")
        let old = folder.appendingPathComponent("F.xmp")
        _ = try? XMPSidecarWriter.apply(fields, to: old)      // an earlier version wrote 3 stars
        expect((try? XMPSidecarWriter.apply(organise, to: old)) == .written, "no stars: own old sidecar is written")
        expect(rating(old) == ["0"] && !read(old).contains("travelcut:Rating"), "no stars: unchanged old TravelCut stars are cleared")
        expect((try? XMPSidecarWriter.apply(organise, to: fresh)) == .written && rating(fresh) == ["4"],
               "no stars: stars the user changed are kept")
        return failures
    }

    private static func makeChecker() -> CGImage? {
        guard let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        for y in stride(from: 0, to: 800, by: 6) {
            for x in stride(from: 0, to: 1200, by: 6) where (x / 6 + y / 6) % 2 == 0 {
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 6, height: 6))
            }
        }
        return context.makeImage()
    }

    private static func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: 40).cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent)
    }

    /// The cache must round-trip metrics exactly and survive a partial last line.
    private static func cacheSelfTest() -> [String] {
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TravelCut-cache-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let embedding: [Float] = (0..<512).map { Float($0) / 1000 - 0.25 }
        let metrics = PhotoMetrics(
            aesthetic: 0.7, sharpness: 0.4, faceSharpness: 0.5, faceQuality: 0.6, eyesClosed: true, brightness: 0.45,
            isUtility: false, semanticLabel: nil, theme: nil, featurePrint: nil, previewSize: 1024,
            embedding: embedding, visionFailed: false
        )
        let item = PhotoItem(primary: root.appendingPathComponent("Day/A.JPG"), sidecarTarget: nil,
                             capturedAt: Date(timeIntervalSince1970: 1_800_000_000.25), timeZone: .current)
        guard let cache = PhotoCache(root: root) else { return ["cache: cannot create"] }
        let key = cache.key(for: item)
        if key != "Day/A.JPG|1800000000.25" { failures.append("cache: key is relative path + capture time, got \(key)") }
        cache.store(metrics, for: key)
        let judgement = PhotoGroupJudgement(bestMember: 1, keep: true, highlightScore: 0.7, theme: .nature, label: "湖", reason: nil)
        let groupKey = PhotoCache.groupKey(photoKeys: [key], themes: [.nature, .people])
        cache.store(judgement, for: groupKey)

        // Simulate a killed run, then reopen.
        let file = root.appendingPathComponent(".travelcut-cache/analysis-v\(PhotoCache.analysisVersion).jsonl")
        if let handle = try? FileHandle(forWritingTo: file) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data("{\"key\":\"half".utf8)); try? handle.close() }
        guard let reopened = PhotoCache(root: root) else { return failures + ["cache: cannot reopen"] }
        guard let back = reopened.metrics(for: key) else { return failures + ["cache: stored metrics missing after reopen"] }
        if back.embedding != embedding { failures.append("cache: embedding does not round-trip") }
        if back.aesthetic != 0.7 || back.faceSharpness != 0.5 || back.eyesClosed != true || back.previewSize != 1024 {
            failures.append("cache: metrics do not round-trip")
        }
        if reopened.judgement(for: groupKey)?.label != "湖" { failures.append("cache: judgement does not round-trip") }
        if reopened.judgement(for: PhotoCache.groupKey(photoKeys: [key], themes: [.nature])) != nil {
            failures.append("cache: changing themes must miss the Qwen cache")
        }
        let failed = PhotoMetrics(
            aesthetic: 0.5, sharpness: 0.4, faceSharpness: nil, faceQuality: 0, eyesClosed: false, brightness: 0.5,
            isUtility: false, semanticLabel: nil, theme: nil, featurePrint: nil, previewSize: 1024, embedding: nil, visionFailed: true
        )
        reopened.store(failed, for: "Day/B.JPG|1")
        if reopened.metrics(for: "Day/B.JPG|1") != nil { failures.append("cache: photos whose Vision analysis failed are not cached") }
        return failures
    }

    private static func placeSelfTest() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append("place: " + message) } }

        // GeoNames lines: id, name, ascii, alternates, lat, lon, class, code, country, cc2, a1..a4, population.
        func line(_ name: String, _ alt: String, _ lat: Double, _ lon: Double, _ code: String, _ cc: String, _ pop: Int) -> String {
            ["1", name, name, alt, "\(lat)", "\(lon)", "P", code, cc, "", "", "", "", "", "\(pop)"].joined(separator: "\t")
        }
        let text = [
            line("Prague", "Praha,プラハ,布拉格", 50.088, 14.420, "PPLC", "CZ", 1_300_000),
            line("Praha 1", "布拉格1区", 50.087, 14.421, "PPLX", "CZ", 30_000),
            line("Tiny", "", 50.090, 14.425, "PPL", "CZ", 600),
            line("Stranda", "Stranden", 62.309, 6.937, "PPL", "NO", 2969),
            line("Versailles", "凡尔赛", 48.804, 2.135, "PPL", "FR", 85_000),
            line("Saint-Quentin-en-Yvelines", "", 48.773, 2.044, "PPL", "FR", 230_000),
        ].joined(separator: "\n")
        let entries = (try? GeoPlaces.parse(text)) ?? []
        expect(entries.count == 5, "city sections (PPLX) are skipped, got \(entries.count)")
        expect(entries.first?.chineseName == "布拉格", "Chinese name picked over Japanese katakana")
        let geo = GeoPlaces(entries: entries)
        let prague = geo.place(latitude: 50.089, longitude: 14.424)
        expect(prague?.city == "布拉格" && prague?.country == "捷克", "most populous place nearby wins, got \(String(describing: prague))")
        let geiranger = geo.place(latitude: 62.101, longitude: 7.206)   // ~27 km from Stranda, no closer town
        expect(geiranger?.city == "Stranda", "nearest town within 50 km when nothing is within 10 km, got \(String(describing: geiranger))")
        expect(geo.place(latitude: 0, longitude: -160) == nil, "no place far from any town")
        let versailles = geo.place(latitude: 48.8049, longitude: 2.1204)
        expect(versailles?.city == "凡尔赛", "a close town beats a bigger one 8 km away, got \(String(describing: versailles))")

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let oslo = Place(countryCode: "NO", country: "挪威", city: "奥斯陆")
        let bergen = Place(countryCode: "NO", country: "挪威", city: "卑尔根")
        let times = [0, 600, 1000, 1200, 7200].map { base.addingTimeInterval(TimeInterval($0)) }
        let known: [Place?] = [oslo, nil, nil, bergen, nil]
        let inferred = PlaceInference.infer(times: times, known: known)
        expect(inferred[0]?.0 == oslo && inferred[0]?.1 == .gps, "own GPS is kept")
        expect(inferred[1]?.0 == oslo && inferred[1]?.1 == .inferred, "nearer neighbour in time wins (10 min vs 10 min after 0 → oslo)")
        expect(inferred[2]?.0 == bergen, "nearer neighbour in time wins (bergen 200 s away)")
        expect(inferred[4] == nil, "nothing within 30 minutes → no place")

        // Online refinement: landmark kept, numbered districts and non-Chinese names lose to the offline city.
        let praha = Place(countryCode: "CZ", country: "捷克", city: "布拉格")
        let bridge = OnlinePlaces.merge(offline: praha, online: .init(locality: "Praha 1", landmark: "查理大桥", country: "捷克"))
        expect(bridge?.city == "布拉格" && bridge?.detail == "查理大桥", "district locality ignored, got \(String(describing: bridge))")
        expect(bridge?.keywordPath == ["TravelCut", "地点", "捷克", "布拉格", "查理大桥"], "landmark is the deepest keyword")
        expect(bridge?.text == "捷克 布拉格 查理大桥", "Qwen gets the landmark too")
        let tromso = OnlinePlaces.merge(offline: Place(countryCode: "NO", country: "挪威", city: "特罗姆瑟"),
                                        online: .init(locality: "Tromsø", landmark: "Tromsøya", country: "挪威"))
        expect(tromso?.city == "特罗姆瑟" && tromso?.detail == "Tromsøya", "Chinese offline city beats a local-name locality")
        let palace = OnlinePlaces.merge(offline: Place(countryCode: "FR", country: "法国", city: "Le Chesnay"),
                                        online: .init(locality: "凡尔赛", landmark: "凡尔赛宫", country: "法国"))
        expect(palace?.city == "凡尔赛" && palace?.detail == "凡尔赛宫", "Chinese online city beats a non-Chinese offline one")
        let sea = OnlinePlaces.merge(offline: praha, online: .init(locality: nil, landmark: nil, country: nil))
        expect(sea == praha, "an empty answer keeps the offline place")
        let lent = PlaceInference.infer(times: [base, base.addingTimeInterval(60)], known: [bridge, nil])
        expect(lent[1]?.0.detail == nil && lent[1]?.0.city == "布拉格", "inferred places stay at city level")
        expect(OnlinePlaces.key(latitude: 50.08649, longitude: 14.41140) == "50.086,14.411", "~110 m spot key")

        // GPS in EXIF: south and west are negative; 0/0 means no fix.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TravelCut-gps-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func jpeg(_ name: String, _ gps: [CFString: Any]) -> URL? {
            let url = folder.appendingPathComponent(name)
            guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? url : nil
        }
        if let rio = jpeg("rio.jpg", [kCGImagePropertyGPSLatitude: 22.9, kCGImagePropertyGPSLatitudeRef: "S",
                                      kCGImagePropertyGPSLongitude: 43.2, kCGImagePropertyGPSLongitudeRef: "W"]) {
            let c = PhotoDiscovery.coordinate(of: rio)
            expect(c.map { abs($0.0 + 22.9) < 0.001 && abs($0.1 + 43.2) < 0.001 } ?? false, "S/W coordinates are negative, got \(String(describing: c))")
        }
        if let none = jpeg("nofix.jpg", [kCGImagePropertyGPSLatitude: 0, kCGImagePropertyGPSLatitudeRef: "N",
                                         kCGImagePropertyGPSLongitude: 0, kCGImagePropertyGPSLongitudeRef: "E"]) {
            expect(PhotoDiscovery.coordinate(of: none) == nil, "0/0 is treated as no fix")
        }
        return failures
    }
}
