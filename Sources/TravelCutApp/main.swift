import AppKit
import SwiftUI
import TravelCutCore

@main
struct TravelCutApplication: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TravelCut")
                        .font(.largeTitle.bold())
                    Text(model.mode == .video
                         ? "自动挑选并裁成独立高光片段，直接交给剪映模板"
                         : "把连拍和相似照片分组、挑出每组最好的一张，星级写进 RAW 旁边的 .xmp，在 Bridge 里看")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("模式", selection: $model.mode) {
                Text("视频高光").tag(AppModel.Mode.video)
                Text("照片精选").tag(AppModel.Mode.photos)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRunning)

            GroupBox("旅行素材") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.inputFolder?.lastPathComponent ?? "尚未选择文件夹")
                            .fontWeight(.medium)
                        Text(model.inputFolder?.path ?? (model.mode == .video
                            ? "支持 MP4、MOV、M4V、MTS 和 M2TS"
                            : "会递归查看所有子文件夹；星级只写入 RAW 照片"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("选择文件夹…") { model.chooseInputFolder() }
                        .disabled(model.isRunning)
                }
                .padding(6)
            }

            GroupBox("想保留的内容（可多选）") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("所选内容会同时影响快速筛选和 Qwen 深度判断")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("全选") { model.selectAllThemes() }
                            .buttonStyle(.link)
                            .disabled(model.isRunning)
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                        spacing: 8
                    ) {
                        ForEach(HighlightTheme.allCases) { theme in
                            Toggle(isOn: Binding(
                                get: { model.selectedThemes.contains(theme) },
                                set: { model.setTheme(theme, selected: $0) }
                            )) {
                                Label(theme.rawValue, systemImage: theme.systemImage)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.button)
                            .disabled(model.isRunning)
                        }
                    }
                    if model.selectedThemes.isEmpty {
                        Text("请至少选择一种内容")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(6)
            }

            GroupBox("自动处理") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.mode == .video {
                        Label("先分析整批素材，再按事件自然起止点决定片段长度", systemImage: "timeline.selection")
                        Label("Qwen3-VL-4B 在本机深度理解候选片段", systemImage: "brain.head.profile")
                        Label("处理期间保持 Mac 唤醒，避免空闲锁屏中断", systemImage: "moon.zzz")
                        Label("保留原始分辨率、方向、帧率、HDR 与现场声", systemImage: "checkmark.shield")
                        Label("每天一个文件夹，按拍摄时间编号，文件名带主题和内容标签", systemImage: "text.badge.checkmark")
                    } else {
                        Label("同一文件夹里连续拍的相似照片分成一组，按拍摄时间排序时组员挨在一起", systemImage: "square.stack.3d.up")
                        Label("Qwen3-VL-4B 从每组技术最好的几张里挑一张，并判断值不值得留", systemImage: "brain.head.profile")
                        Label("每组最佳 3 星（最出彩的 4 星），一张接近的备选 2 星，废片标为拒绝", systemImage: "star.leadinghalf.filled")
                        Label("标题写「组 0042 · 第 1/5」，关键字写组号和主题", systemImage: "text.badge.checkmark")
                        Label("不改 RAW 原片，不覆盖你已有的星级、颜色标签和 Camera Raw 调整", systemImage: "checkmark.shield")
                        Toggle("试运行：只生成报告，不写入星级", isOn: $model.photoDryRun)
                    }
                }
                .font(.callout)
                .padding(7)
            }

            Text("首次运行会下载数 GB 的4-bit模型，以后可以离线使用。模型和缓存保存在本机。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isRunning {
                VStack(alignment: .leading, spacing: 7) {
                    ProgressView(value: model.progress)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(model.lastRunSucceeded ? .green : .red)
                    .textSelection(.enabled)
            }

            HStack {
                if let outputFolder = model.lastOutputFolder {
                    Button(model.mode == .video ? "打开高光文件夹" : "打开照片文件夹") {
                        NSWorkspace.shared.open(outputFolder)
                    }
                }
                Spacer()
                Button {
                    if model.mode == .video { model.extractHighlights() } else { model.cullPhotos() }
                } label: {
                    Label(model.mode == .video ? "自动挑选高光" : "自动精选照片", systemImage: "wand.and.stars")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    model.inputFolder == nil
                        || model.isRunning
                        || model.selectedThemes.isEmpty
                )
            }
        }
        .padding(28)
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let selectedThemesKey = "TravelCut.selectedThemes"
    private static let modeKey = "TravelCut.mode"

    enum Mode: String { case video, photos }

    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: AppModel.modeKey) ?? "") ?? .video {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            statusMessage = ""
            lastOutputFolder = nil
        }
    }
    @Published var photoDryRun = false

    @Published var inputFolder: URL?
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var statusMessage = ""
    @Published var lastOutputFolder: URL?
    @Published var lastRunSucceeded = false
    @Published var selectedThemes: Set<HighlightTheme> {
        didSet {
            let values = HighlightTheme.allCases
                .filter(selectedThemes.contains)
                .map(\.rawValue)
            UserDefaults.standard.set(values, forKey: Self.selectedThemesKey)
        }
    }
    private var processingActivity: NSObjectProtocol?

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.selectedThemesKey) {
            selectedThemes = Set(saved.compactMap(HighlightTheme.init(rawValue:)))
        } else {
            selectedThemes = HighlightTheme.defaultSelection
        }
    }

    func setTheme(_ theme: HighlightTheme, selected: Bool) {
        if selected {
            selectedThemes.insert(theme)
        } else {
            selectedThemes.remove(theme)
        }
    }

    func selectAllThemes() {
        selectedThemes = HighlightTheme.defaultSelection
    }

    func chooseInputFolder() {
        let panel = NSOpenPanel()
        panel.title = mode == .video ? "选择旅行视频所在文件夹" : "选择旅行照片所在的根文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            inputFolder = panel.url
            statusMessage = ""
            lastOutputFolder = nil
        }
    }

    func extractHighlights() {
        guard let inputFolder else { return }
        let outputFolder = HighlightRecovery.resumableOutputFolder(
            in: inputFolder,
            selectedThemes: selectedThemes
        ) ?? uniqueOutputFolder(in: inputFolder)
        let configuration = JobConfiguration(
            inputFolder: inputFolder,
            outputFolder: outputFolder,
            useDeepAnalysis: true,
            deepCandidateFraction: 0.40,
            deepFrameCount: 10,
            selectedThemes: selectedThemes
        )

        isRunning = true
        progress = 0
        statusMessage = "准备开始…"
        lastRunSucceeded = false
        lastOutputFolder = nil
        beginProcessingActivity()

        Task {
            defer {
                endProcessingActivity()
                isRunning = false
            }
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try await HighlightEngine().run(configuration: configuration) { [weak self] update in
                        Task { @MainActor in
                            self?.progress = update.fraction
                            self?.statusMessage = update.message
                        }
                    }
                }.value
                lastOutputFolder = summary.outputFolder
                statusMessage = "完成：从 \(summary.inputVideoCount) 个视频中导出 \(summary.selectedClipCount) 段高光"
                lastRunSucceeded = true
            } catch {
                statusMessage = error.localizedDescription
                lastRunSucceeded = false
            }
        }
    }

    func cullPhotos() {
        guard let inputFolder else { return }
        let configuration = PhotoCullConfiguration(
            inputFolder: inputFolder,
            selectedThemes: selectedThemes,
            useQwen: true,
            writeRatings: !photoDryRun
        )
        isRunning = true
        progress = 0
        statusMessage = "准备开始…"
        lastRunSucceeded = false
        lastOutputFolder = nil
        beginProcessingActivity()

        Task {
            defer {
                endProcessingActivity()
                isRunning = false
            }
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try await PhotoCullEngine().run(configuration: configuration) { [weak self] update in
                        Task { @MainActor in
                            self?.progress = update.fraction
                            self?.statusMessage = update.message
                        }
                    }
                }.value
                lastOutputFolder = inputFolder
                var lines = ["完成：\(summary.photoCount) 张照片分成 \(summary.groupCount) 组，2 星以上 \(summary.starredCount) 张，拒绝 \(summary.rejectedCount) 张"]
                if summary.skippedUserMarked > 0 { lines.append("已有你的星级或标签而跳过 \(summary.skippedUserMarked) 张") }
                if summary.withoutRAW > 0 { lines.append("没有 RAW、未写入 \(summary.withoutRAW) 张") }
                lines.append(summary.wroteRatings
                    ? "在 Bridge 里按创建日期排序、过滤 2 星或 3 星以上即可"
                    : "试运行：没有写入星级，结果见文件夹里的「\(PhotoCullEngine.reportName)」")
                statusMessage = lines.joined(separator: "\n")
                lastRunSucceeded = true
            } catch {
                statusMessage = error.localizedDescription
                lastRunSucceeded = false
            }
        }
    }

    private func beginProcessingActivity() {
        guard processingActivity == nil else { return }
        processingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "TravelCut 正在分析和导出视频"
        )
    }

    private func endProcessingActivity() {
        guard let processingActivity else { return }
        ProcessInfo.processInfo.endActivity(processingActivity)
        self.processingActivity = nil
    }

    private func uniqueOutputFolder(in input: URL) -> URL {
        let manager = FileManager.default
        let base = input.appendingPathComponent("TravelCut 高光片段", isDirectory: true)
        if !manager.fileExists(atPath: base.path) { return base }
        for index in 2...999 {
            let candidate = input.appendingPathComponent("TravelCut 高光片段 \(index)", isDirectory: true)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return input.appendingPathComponent("TravelCut 高光片段 \(UUID().uuidString)", isDirectory: true)
    }
}

private extension HighlightTheme {
    var systemImage: String {
        switch self {
        case .roadScenery: return "road.lanes"
        case .nature: return "mountain.2"
        case .cityStreet: return "building.2"
        case .landmark: return "building.columns"
        case .people: return "person.2"
        case .food: return "fork.knife"
        case .cultureActivity: return "figure.walk"
        case .animals: return "pawprint"
        }
    }
}
