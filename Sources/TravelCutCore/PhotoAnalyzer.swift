import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// One shot. A RAW and a same-named JPEG next to it count as one photo; ratings go into the
/// RAW's XMP sidecar, which is what Bridge reads for RAW files.
struct PhotoItem: Sendable {
    let primary: URL          // the file whose preview is analysed
    let sidecarTarget: URL?   // RAW file that owns the .xmp sidecar; nil when there is no RAW
    /// JPEG / HEIC / TIFF / DNG without a RAW: Bridge reads metadata inside these files, so ratings
    /// are written into the file itself (metadata only, pixels untouched).
    var embeddedTarget: URL? {
        sidecarTarget == nil && PhotoDiscovery.embeddedExtensions.contains(primary.pathExtension.lowercased())
            ? primary : nil
    }
    let capturedAt: Date
    let timeZone: TimeZone
}

enum PhotoDiscovery {
    static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw", "3fr", "iiq", "rwl", "x3f",
    ]
    static let renderedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff", "dng"]
    static let embeddedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "dng"]

    static func discover(in folder: URL) throws -> [PhotoItem] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw TravelCutError.invalidArguments("无法读取文件夹：\(folder.path)") }

        var byStem: [String: [URL]] = [:]
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if url.lastPathComponent.lowercased().hasPrefix("travelcut ") { enumerator.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard rawExtensions.contains(ext) || renderedExtensions.contains(ext) else { continue }
            let key = url.deletingPathExtension().path.lowercased()
            byStem[key, default: []].append(url)
        }

        var items: [PhotoItem] = []
        for urls in byStem.values {
            let raw = urls.first { rawExtensions.contains($0.pathExtension.lowercased()) }
            let rendered = urls.first { renderedExtensions.contains($0.pathExtension.lowercased()) }
            guard let primary = raw ?? rendered else { continue }
            let (date, zone) = captureDate(of: primary) ?? rendered.flatMap(captureDate(of:))
                ?? (fileDate(primary), .current)
            items.append(PhotoItem(primary: primary, sidecarTarget: raw, capturedAt: date, timeZone: zone))
        }
        return items.sorted {
            $0.capturedAt != $1.capturedAt
                ? $0.capturedAt < $1.capturedAt
                : $0.primary.path.localizedStandardCompare($1.primary.path) == .orderedAscending
        }
    }

    /// EXIF DateTimeOriginal with sub-seconds, in the recorded offset when there is one.
    static func captureDate(of url: URL) -> (Date, TimeZone)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let offset = exif["OffsetTimeOriginal" as CFString] as? String
        let subsec = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
        return parseExifDate(original, subsec: subsec, offset: offset)
    }

    static func parseExifDate(_ value: String, subsec: String?, offset: String?) -> (Date, TimeZone)? {
        let zone = offset.flatMap { ClipOrganizer.timeZone(fromISO8601: "2000-01-01T00:00:00" + $0) } ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: String(value.prefix(19))) else { return nil }
        let fraction = subsec.flatMap { Double("0." + $0.filter(\.isNumber)) } ?? 0
        return (date.addingTimeInterval(fraction), zone)
    }

    /// The camera's embedded preview when it is big enough, so RAW files are usually not decoded.
    /// Some RAW files (Sony ARW among them) also carry a 160×120 thumbnail that ImageIO may hand
    /// back first; anything that small is useless for judging, so the RAW is decoded instead.
    static let minimumPreviewSize = 1000

    static func preview(of url: URL, maxPixelSize: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
           max(embedded.width, embedded.height) >= min(minimumPreviewSize, maxPixelSize) {
            return embedded
        }
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func fileDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }
}

/// Per-photo measurements used to group shots and pick the best of each group.
struct PhotoMetrics: Sendable {
    let aesthetic: Double
    let sharpness: Double          // sharpest region of the frame, so shallow depth of field is not "soft"
    let faceSharpness: Double?     // largest face, when there is a usable one
    let faceQuality: Double
    let eyesClosed: Bool           // largest face looks like a blink
    let brightness: Double
    let isUtility: Bool
    let semanticLabel: String?
    let theme: HighlightTheme?
    let featurePrint: VNFeaturePrintObservation?
    let previewSize: Int           // longest side of the image that was analysed
    let embedding: [Float]?        // MobileCLIP image embedding, exported for taste experiments
    let visionFailed: Bool         // a Vision request failed; aesthetics, faces or grouping fell back to defaults

    /// How good this frame is technically, for choosing within a group. Faces dominate when present.
    var pickScore: Double {
        let exposure = min(1, max(0, 1 - abs(brightness - 0.5) / 0.5))
        if let faceSharpness {
            return 0.40 * faceSharpness + 0.20 * faceQuality + 0.15 * aesthetic + 0.10 * exposure
                + (eyesClosed ? 0 : 0.15)
        }
        return 0.55 * sharpness + 0.30 * aesthetic + 0.15 * exposure
    }

    /// Why the frame is clearly unusable, or nil. Only black, white and badly out-of-focus frames:
    /// on a 9,000-photo trip, MobileCLIP's rejection prompts and Vision's "utility" flag rejected
    /// dozens of shallow-depth-of-field portraits the user later edited, so neither counts any more.
    static let blurThreshold = 0.06

    var junkReason: String? {
        if brightness < 0.015 { return "全黑" }
        if brightness > 0.985 { return "全白" }
        if sharpness < Self.blurThreshold && (faceSharpness ?? 0) < 0.08 { return "模糊" }
        return nil
    }

    var isJunk: Bool { junkReason != nil }
}

final class PhotoAnalyzer {
    private let vision: VisionAnalyzer

    init(selectedThemes: Set<HighlightTheme>) {
        vision = VisionAnalyzer(selectedThemes: selectedThemes)
    }

    var hasSemanticModel: Bool { vision.fastModelName != nil }

    /// Rebuilds metrics from the cache, re-scoring the stored embedding against the current themes.
    func metrics(from cached: PhotoCache.Metrics) -> PhotoMetrics {
        let semantic = cached.embedding.flatMap { vision.semantic(forEmbedding: $0) }
        return PhotoMetrics(
            aesthetic: cached.aesthetic,
            sharpness: cached.sharpness,
            faceSharpness: cached.faceSharpness,
            faceQuality: cached.faceQuality,
            eyesClosed: cached.eyesClosed,
            brightness: cached.brightness,
            isUtility: cached.isUtility,
            semanticLabel: semantic?.label,
            theme: semantic?.theme,
            featurePrint: cached.featurePrint.flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0)
            },
            previewSize: cached.previewSize,
            embedding: cached.embedding,
            visionFailed: false
        )
    }

    func analyze(_ image: CGImage) -> PhotoMetrics {
        let failuresBefore = vision.failureCount
        let frame = vision.analyzeFrame(image)
        let face = largestFace(in: image)
        let faceSharpness = face.flatMap { box -> Double? in
            guard let crop = image.cropping(to: pixelRect(box, in: image)) else { return nil }
            return vision.edgeSharpness(of: crop)
        }
        return PhotoMetrics(
            aesthetic: frame.aesthetic,
            sharpness: Self.localSharpness(of: image),
            faceSharpness: faceSharpness,
            faceQuality: frame.faceQuality,
            eyesClosed: face.map { _ in eyesClosedInLargestFace(image) } ?? false,
            brightness: frame.brightness,
            isUtility: frame.isUtility,
            semanticLabel: frame.semantic?.label,
            theme: frame.semantic?.theme,
            featurePrint: frame.featurePrint,
            previewSize: max(image.width, image.height),
            embedding: frame.semantic?.embedding,
            visionFailed: vision.failureCount > failuresBefore
        )
    }

    /// Laplacian energy of the sharpest of 6×6 tiles at 384 px, scaled so a sharp photo is about
    /// 0.3–1 and a badly blurred one under 0.05 (calibrated on travel photos with Gaussian blur).
    static func localSharpness(of image: CGImage) -> Double {
        let width = 384
        let height = max(3, Int(Double(image.height) / Double(max(1, image.width)) * Double(width)))
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0.5 }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let tiles = 6
        var sums = [Double](repeating: 0, count: tiles * tiles)
        var counts = [Int](repeating: 0, count: tiles * tiles)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Int(pixels[y * width + x]) * 4
                let neighbors = Int(pixels[(y - 1) * width + x]) + Int(pixels[(y + 1) * width + x])
                    + Int(pixels[y * width + x - 1]) + Int(pixels[y * width + x + 1])
                let tile = min(tiles - 1, y * tiles / height) * tiles + min(tiles - 1, x * tiles / width)
                sums[tile] += abs(Double(center - neighbors)) / 1020
                counts[tile] += 1
            }
        }
        let best = zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 0 }.max() ?? 0
        return min(1, best * 12)
    }

    /// Normalized bounding box of the largest face that is big enough to judge (≥ 8% of the width).
    private func largestFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .map(\.boundingBox)
            .filter { $0.width >= 0.08 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private func eyesClosedInLargestFace(_ image: CGImage) -> Bool {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let face = (request.results ?? []).max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }), let left = face.landmarks?.leftEye?.normalizedPoints,
            let right = face.landmarks?.rightEye?.normalizedPoints
        else { return false }
        return Self.isClosed(left) && Self.isClosed(right)
    }

    /// Eye outline height relative to its width; an open eye is roughly 0.25–0.4, a blink well under 0.15.
    static func eyeOpenness(_ points: [CGPoint]) -> Double {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX
        else { return 1 }
        return Double((maxY - minY) / (maxX - minX))
    }

    static func isClosed(_ points: [CGPoint]) -> Bool { eyeOpenness(points) < 0.15 }

    private func pixelRect(_ box: CGRect, in image: CGImage) -> CGRect {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Vision boxes have their origin at the bottom left.
        return CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        ).integral
    }
}
