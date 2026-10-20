import Foundation

/// Writes title, keywords and optionally a rating into JPEG / HEIC / TIFF / DNG files with exiftool,
/// because Bridge reads metadata inside these files rather than from a sidecar. Only metadata changes;
/// exiftool copies the image data unchanged. Same rules as `XMPSidecarWriter`:
///
/// - without a rating, every photo gets title and keywords; an old TravelCut rating the user has not
///   changed is cleared
/// - with a rating, photos the user already rated or colour-labelled are skipped
/// - values TravelCut wrote before may be replaced, unless the user has since changed the rating
///
/// exiftool cannot write a custom namespace without a config file, so TravelCut remembers the rating
/// it wrote as a keyword: `TravelCut|写入星级|3`.
enum EmbeddedMetadataWriter {
    static let markerPrefix = "TravelCut|写入星级|"

    struct Job {
        let file: URL
        let fields: XMPSidecarWriter.Fields
    }

    enum Outcome: Equatable {
        case written
        case skippedUserMarks
        case failed
    }

    static func findExiftool() -> URL? {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in candidates {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("exiftool")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    struct Existing: Equatable {
        let rating: Int
        let label: String
        let title: String
        let hierarchical: [String]
    }

    /// What decides whether TravelCut may write, given what is in the file now.
    static func marker(in existing: Existing) -> Int? {
        existing.hierarchical.first { $0.hasPrefix(markerPrefix) }.flatMap { Int($0.dropFirst(markerPrefix.count)) }
    }

    static func decide(_ existing: Existing) -> Bool {
        let marker = marker(in: existing)
        if !existing.label.isEmpty { return false }
        if let marker { return existing.rating == marker }
        return existing.rating == 0
    }

    /// Arguments for one file, to be followed by `-execute` in a batch.
    static func arguments(for job: Job, existing: Existing) -> [String] {
        var args = ["-overwrite_original", "-P"]
        if let rating = job.fields.rating {
            args.append("-XMP-xmp:Rating=\(rating)")
        } else if let marker = marker(in: existing), marker == existing.rating {
            args.append("-XMP-xmp:Rating=0")   // clear a rating an earlier version wrote
        }
        if existing.title.isEmpty || existing.title.hasPrefix("组 ") {
            args.append("-XMP-dc:Title=\(job.fields.title)")
        }
        let ours = existing.hierarchical.filter { $0.hasPrefix("TravelCut|") }
        for keyword in ours {
            args.append("-XMP-lr:HierarchicalSubject-=\(keyword)")
            if let leaf = keyword.split(separator: "|").last, !keyword.hasPrefix(markerPrefix) {
                args.append("-XMP-dc:Subject-=\(leaf)")
            }
        }
        for path in job.fields.keywords {
            args.append("-XMP-lr:HierarchicalSubject+=\(path.joined(separator: "|"))")
            if let leaf = path.last { args.append("-XMP-dc:Subject+=\(leaf)") }
        }
        if let rating = job.fields.rating { args.append("-XMP-lr:HierarchicalSubject+=\(markerPrefix)\(rating)") }
        args.append(job.file.path)
        return args
    }

    static func apply(_ jobs: [Job], exiftool: URL) throws -> [URL: Outcome] {
        guard !jobs.isEmpty else { return [:] }
        let existing = try read(jobs.map(\.file), exiftool: exiftool)
        var outcomes: [URL: Outcome] = [:]
        var batch: [String] = []
        var written: [Job] = []
        for job in jobs {
            let current = existing[job.file.path] ?? Existing(rating: 0, label: "", title: "", hierarchical: [])
            guard job.fields.rating == nil || decide(current) else { outcomes[job.file] = .skippedUserMarks; continue }
            batch += arguments(for: job, existing: current) + ["-execute"]
            written.append(job)
        }
        if !batch.isEmpty {
            _ = try run(exiftool, arguments: batch)
            // Verify by reading back instead of parsing exiftool's per-command messages.
            let after = try read(written.map(\.file), exiftool: exiftool)
            for job in written {
                let check = job.fields.keywords.first.map { $0.joined(separator: "|") }
                let ok = job.fields.rating.map { after[job.file.path]?.rating == $0 }
                    ?? (check.map { after[job.file.path]?.hierarchical.contains($0) ?? false } ?? true)
                outcomes[job.file] = ok ? .written : .failed
            }
        }
        return outcomes
    }

    static func read(_ files: [URL], exiftool: URL) throws -> [String: Existing] {
        var result: [String: Existing] = [:]
        for start in stride(from: 0, to: files.count, by: 500) {
            let chunk = Array(files[start..<min(files.count, start + 500)])
            let output = try run(exiftool, arguments: [
                "-j", "-n", "-XMP-xmp:Rating", "-XMP-xmp:Label", "-XMP-dc:Title", "-XMP-lr:HierarchicalSubject",
            ] + chunk.map(\.path))
            guard let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { continue }
            for row in rows {
                guard let path = row["SourceFile"] as? String else { continue }
                let rating = (row["Rating"] as? NSNumber)?.intValue ?? Int("\(row["Rating"] ?? "0")") ?? 0
                let hierarchical: [String]
                switch row["HierarchicalSubject"] {
                case let list as [Any]: hierarchical = list.map { "\($0)" }
                case let single?: hierarchical = ["\(single)"]
                case nil: hierarchical = []
                }
                result[path] = Existing(
                    rating: rating,
                    label: (row["Label"] as? String) ?? "",
                    title: row["Title"].map { "\($0)" } ?? "",
                    hierarchical: hierarchical
                )
            }
        }
        return result
    }

    private static func run(_ exiftool: URL, arguments: [String]) throws -> String {
        let argfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("TravelCut-exiftool-\(UUID().uuidString).args")
        try (arguments.joined(separator: "\n") + "\n").write(to: argfile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: argfile) }
        let process = Process()
        process.executableURL = exiftool
        // -common_args applies to every command separated by -execute in the argfile.
        process.arguments = ["-@", argfile.path, "-common_args", "-charset", "filename=utf8", "-q", "-q"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
