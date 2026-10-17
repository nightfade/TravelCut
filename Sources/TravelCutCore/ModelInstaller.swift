import Foundation

actor ModelInstaller {
    struct ModelFile: Sendable {
        let name: String
        let size: Int64
    }

    struct ModelSet: Sendable {
        let repository: String
        let revision: String
        let directoryName: String
        let files: [ModelFile]

        var totalSize: Int64 { files.reduce(Int64(0)) { $0 + $1.size } }
    }

    static let qwen = ModelSet(
        repository: "Qwen/Qwen3-VL-4B-Instruct-GGUF",
        revision: "1cd86afb9a95c410a6038ab3b40d8b578c892266",
        directoryName: "Qwen3-VL-4B-Instruct-GGUF-1cd86afb9a95c410a6038ab3b40d8b578c892266",
        files: [
            ModelFile(name: "Qwen3VL-4B-Instruct-Q4_K_M.gguf", size: 2_497_281_664),
            ModelFile(name: "mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf", size: 453_974_304),
        ]
    )

    /// Apple's own Core ML export. Downloaded on first use rather than bundled,
    /// because the weights are licensed for research use only.
    static let mobileCLIP = ModelSet(
        repository: "apple/coreml-mobileclip",
        revision: "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947",
        directoryName: "coreml-mobileclip-3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947",
        files: [
            ModelFile(name: "mobileclip_s2_image.mlpackage/Manifest.json", size: 617),
            ModelFile(name: "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 299_056),
            ModelFile(name: "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 71_397_632),
            ModelFile(name: "mobileclip_s2_text.mlpackage/Manifest.json", size: 617),
            ModelFile(name: "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 128_127),
            ModelFile(name: "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 126_866_880),
        ]
    )

    let modelSet: ModelSet

    init(_ modelSet: ModelSet = ModelInstaller.qwen) {
        self.modelSet = modelSet
    }

    /// Where a model set lives once installed; nil if Application Support is unavailable.
    static func installedDirectory(for modelSet: ModelSet) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TravelCut/Models", isDirectory: true)
            .appendingPathComponent(modelSet.directoryName, isDirectory: true)
    }

    private let manager = FileManager.default

    func install(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let directory = try modelDirectory()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = modelSet.totalSize
        var completed = existingByteCount(in: directory)
        try checkFreeSpace(at: directory, required: max(0, total - completed))
        progress(Double(completed) / Double(total))

        for file in modelSet.files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.name)
            if fileSize(destination) == file.size { continue }
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }

            let partial = destination.appendingPathExtension("part")
            if fileSize(partial) > file.size {
                try manager.removeItem(at: partial)
            }
            let partialStart = fileSize(partial)
            if partialStart == file.size {
                try manager.moveItem(at: partial, to: destination)
                continue
            }
            let completedBeforeFile = completed - partialStart
            let source = try sourceURL(filename: file.name)
            let downloader = ResumableFileDownload(
                source: source,
                partial: partial,
                expectedSize: file.size
            ) { fileBytes in
                progress(Double(completedBeforeFile + fileBytes) / Double(total))
            }
            try await downloader.start()
            guard fileSize(partial) == file.size else {
                throw TravelCutError.modelUnavailable("模型文件下载不完整：\(file.name)")
            }
            try manager.moveItem(at: partial, to: destination)
            completed = completedBeforeFile + file.size
            progress(Double(completed) / Double(total))
        }
        progress(1)
        return directory
    }

    private func modelDirectory() throws -> URL {
        guard let directory = Self.installedDirectory(for: modelSet) else {
            throw TravelCutError.modelUnavailable("无法访问 Application Support")
        }
        return directory
    }

    private func sourceURL(filename: String) throws -> URL {
        let path = "https://huggingface.co/\(modelSet.repository)/resolve/\(modelSet.revision)/\(filename)?download=true"
        guard let url = URL(string: path) else {
            throw TravelCutError.modelUnavailable("模型下载地址无效")
        }
        return url
    }

    private func existingByteCount(in directory: URL) -> Int64 {
        modelSet.files.reduce(Int64(0)) { total, file in
            let destination = directory.appendingPathComponent(file.name)
            if fileSize(destination) == file.size { return total + file.size }
            let partial = destination.appendingPathExtension("part")
            return total + min(file.size, fileSize(partial))
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func checkFreeSpace(at directory: URL, required: Int64) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // Some volumes wrongly report 0 here; a non-positive value means "unknown", not "full".
        guard let available = values.volumeAvailableCapacityForImportantUsage, available > 0 else { return }
        if available < required + 1_000_000_000 {
            let needed = Double(required + 1_000_000_000) / 1_000_000_000
            throw TravelCutError.modelUnavailable(
                String(format: "磁盘空间不足，下载模型需要至少约 %.1f GB 可用空间", needed)
            )
        }
    }
}

private final class ResumableFileDownload: @unchecked Sendable {
    private let source: URL
    private let partial: URL
    private let expectedSize: Int64
    private let progress: @Sendable (Int64) -> Void

    init(
        source: URL,
        partial: URL,
        expectedSize: Int64,
        progress: @Sendable @escaping (Int64) -> Void
    ) {
        self.source = source
        self.partial = partial
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func start() async throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--location",
            "--fail",
            "--silent",
            "--show-error",
            "--retry", "5",
            "--retry-all-errors",
            "--retry-delay", "2",
            "--connect-timeout", "30",
            "--speed-limit", "1024",
            "--speed-time", "120",
            "--continue-at", "-",
            "--output", partial.path,
            source.absoluteString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    Task.detached { [self] in
                        var lastReported: Int64 = -1
                        while process.isRunning {
                            let size = currentSize()
                            let step = max(1_000_000, expectedSize / 100)
                            if lastReported < 0 || size - lastReported >= step {
                                lastReported = size
                                progress(size)
                            }
                            try? await Task.sleep(nanoseconds: 350_000_000)
                        }
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        progress(currentSize())
        guard status == 0 else {
            let data = try? errorPipe.fileHandleForReading.readToEnd()
            let rawMessage = data.flatMap { String(data: $0, encoding: .utf8) }
            let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TravelCutError.modelUnavailable(
                message?.isEmpty == false ? message! : "模型下载失败"
            )
        }
    }

    private func currentSize() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
