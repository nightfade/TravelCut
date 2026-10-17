import AVFoundation
import Foundation

enum ClipExporter {
    static func export(
        candidates: [HighlightCandidate],
        configuration: JobConfiguration,
        previouslyExported: [ExportedClip] = [],
        progress: @escaping (Int, Int, [ExportedClip]) throws -> Void
    ) async throws -> [ExportedClip] {
        let manager = FileManager.default
        try manager.createDirectory(
            at: configuration.outputFolder,
            withIntermediateDirectories: true
        )

        let placements = ClipOrganizer.plan(candidates)
        var exported: [ExportedClip] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            if let existing = previouslyExported.first(where: { $0.matches(candidate) }) {
                exported.append(existing)
                try progress(index + 1, candidates.count, exported)
                continue
            }
            let asset = AVURLAsset(url: candidate.source.url)
            let metadata = (try? await asset.load(.metadata)) ?? []
            guard let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw TravelCutError.cannotCreateExporter
            }

            let fileType = preferredFileType(
                sourceExtension: candidate.source.url.pathExtension,
                supported: exporter.supportedFileTypes
            )
            let fileExtension = extensionForFileType(fileType)
            let placement = placements[index]
            let dayFolder = configuration.outputFolder
                .appendingPathComponent(placement.dayFolder, isDirectory: true)
            try manager.createDirectory(at: dayFolder, withIntermediateDirectories: true)
            let outputURL = uniqueOutputURL(
                folder: dayFolder,
                baseName: placement.baseName,
                fileExtension: fileExtension
            )
            if manager.fileExists(atPath: outputURL.path) {
                throw TravelCutError.outputAlreadyExists(outputURL.path)
            }

            let safeStart = min(candidate.source.duration, max(0, candidate.start))
            let safeDuration = min(candidate.duration, candidate.source.duration - safeStart)
            guard safeDuration >= 0.1 else { continue }
            exporter.outputURL = outputURL
            exporter.outputFileType = fileType
            exporter.shouldOptimizeForNetworkUse = false
            // The moment the clip starts, so editors that sort by date keep shooting order
            // even for several clips cut from one long source.
            exporter.metadata = metadataWithCreationDate(
                metadata,
                creationDate: placement.clipStartedAt,
                timeZone: placement.timeZone
            )
            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: safeStart, preferredTimescale: 60_000),
                duration: CMTime(seconds: safeDuration, preferredTimescale: 60_000)
            )

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously { continuation.resume() }
            }
            guard exporter.status == .completed else {
                try? manager.removeItem(at: outputURL)
                throw TravelCutError.exportFailed(
                    "\(candidate.source.url.lastPathComponent)："
                        + (exporter.error?.localizedDescription ?? "未知错误")
                )
            }

            try? manager.setAttributes([
                .creationDate: placement.clipStartedAt,
                .modificationDate: candidate.source.modifiedAt,
            ], ofItemAtPath: outputURL.path)

            exported.append(ExportedClip(
                outputFile: outputURL.path,
                sourceFile: candidate.source.url.path,
                sourceCreatedAt: candidate.source.createdAt,
                sourceModifiedAt: candidate.source.modifiedAt,
                startSeconds: rounded(safeStart),
                durationSeconds: rounded(safeDuration),
                score: rounded(candidate.score),
                semanticLabel: candidate.semanticLabel,
                reason: candidate.deepAnalysis?.reason,
                theme: candidate.theme?.rawValue,
                clipStartedAt: placement.clipStartedAt,
                dayFolder: placement.dayFolder,
                width: candidate.source.width,
                height: candidate.source.height,
                nominalFrameRate: rounded(candidate.source.nominalFrameRate),
                codec: candidate.source.codec,
                hdr: candidate.source.isHDR,
                hasAudio: candidate.source.hasAudio,
                audioLabels: candidate.audioLabels,
                sourceMetadata: candidate.source.metadata
            ))
            try progress(index + 1, candidates.count, exported)
        }
        return exported
    }

    private static func preferredFileType(
        sourceExtension: String,
        supported: [AVFileType]
    ) -> AVFileType {
        let preferred: AVFileType
        switch sourceExtension.lowercased() {
        case "mov": preferred = .mov
        case "m4v": preferred = .m4v
        default: preferred = .mp4
        }
        if supported.contains(preferred) { return preferred }
        if supported.contains(.mov) { return .mov }
        if supported.contains(.mp4) { return .mp4 }
        return supported.first ?? .mov
    }

    private static func metadataWithCreationDate(
        _ metadata: [AVMetadataItem],
        creationDate: Date,
        timeZone: TimeZone
    ) -> [AVMetadataItem] {
        let creationIdentifiers: Set<AVMetadataIdentifier> = [
            .commonIdentifierCreationDate,
            .quickTimeMetadataCreationDate,
            .quickTimeUserDataCreationDate,
        ]
        let withoutDuplicate = metadata.filter {
            guard let identifier = $0.identifier else { return true }
            return !creationIdentifiers.contains(identifier)
        }
        // Keep the capture offset (2026-07-17T23:58:00+01:00) so the clip still sorts into
        // the right day when re-imported, instead of collapsing to UTC.
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        let value = formatter.string(from: creationDate)
        let creationItems = creationIdentifiers.map { identifier -> AVMetadataItem in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        return withoutDuplicate + creationItems
    }

    private static func extensionForFileType(_ fileType: AVFileType) -> String {
        switch fileType {
        case .mp4: return "mp4"
        case .m4v: return "m4v"
        default: return "mov"
        }
    }

    private static func uniqueOutputURL(
        folder: URL,
        baseName: String,
        fileExtension: String
    ) -> URL {
        let manager = FileManager.default
        var url = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while manager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName)_\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return url
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }
}
