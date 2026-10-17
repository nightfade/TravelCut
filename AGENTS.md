# TravelCut AI 接手指南

这是 TravelCut 项目的开发与交接入口。后续 AI 或开发者开始修改前，必须完整阅读本文件，再阅读 `README.md`。不要另建内容重叠的上下文文档；产品决策、架构或交付状态发生变化时，同步更新本文件。

## 1. 项目目标

TravelCut 是面向 macOS 的本地旅行视频高光提取工具。它的输出不是最终影片，而是一组可直接投入剪映模板的独立高光视频片段。

核心工作是：先理解整批素材，再找出值得保留的自然事件，确定各自真实起止点，裁成单独文件，按旅程时间排序、编号并添加中文语义标签。

当前版本：`0.3.0`，build `7`。

## 2. 不可擅自改变的产品约束

- 不提供或推导固定单段时长、目标总时长、目标片段数。高光可能极短，也可能很长，长度必须来自事件边界。
- 必须先观察整批素材再做全局比较，不能把每个源文件机械地裁一段，也不能保证每个源文件都有入选片段。
- 用户必须能多选想保留的内容类型，且选择要真实影响 MobileCLIP 快速筛选和 Qwen 深度判断，不得仅用来改变文件名。默认全选，并记住用户上次选择。
- 「沿途风景」是一等内容类型。用户选中后，清晰稳定且能记录公路、步行路线、车窗、火车或船上旅途氛围的景色，不得仅因常见或不够戏剧化而被拒绝。
- 输出必须是独立高光片段，不负责转场、配乐、字幕、模板或最终成片。
- 默认保持每个来源片段的原始分辨率、横竖方向、帧率、HDR 和现场声。不要建立统一画布，不要补模糊背景，不要旋转横竖素材，不要主动重新编码。
- 使用 `AVAssetExportPresetPassthrough` 裁剪。MTS/M2TS 等容器必要时可重封装为 MOV，但不要主动改变音视频编码。
- 尽量保留来源元信息和文件创建、修改时间。容器无法承载的字段必须写入 `selection.json`，不能宣称任意厂商私有元信息都能百分之百原样保留。
- 按拍摄时间排序。优先使用媒体内嵌 creation date，其次 Finder 创建时间，再其次修改时间；同一时间按路径排序。
- 文件名格式为 `编号_拍摄日期时间_原文件名_语义标签.ext`，必须让用户无需打开报告即可追溯来源；`selection.json` 继续记录完整源路径。
- 所有视频内容分析必须在本机完成，不调用云端 AI API，不消耗在线模型 token。首次下载本地模型不属于云端推理。
- 默认深度模型是 Qwen3-VL-4B，不要改为 8B。实际运行目标是另一台 24GB Apple Silicon Mac，不是当前开发机。
- Qwen 候选必须串行分析，不能为了速度并发加载多份模型或并行跑多个候选。
- 筛选完成后、导出开始前必须持久化可恢复检查点；每成功导出一段就更新检查点。相同素材、标签和分析配置重试时跳过筛选及已完成输出。
- 导出前必须估算剩余片段空间并预留安全余量。空间不足时保留检查点并给出可恢复提示，不能让用户重新跑完整模型分析。
- macOS 某些卷会让 `volumeAvailableCapacityForImportantUsage` 错误返回 0。空间读取必须优先用普通 volume capacity，再回退到 filesystem free size 和 important-usage capacity；非正数无效，全部不可用时跳过预检，不能误报 0GB。
- App 执行筛选和导出时必须通过 `ProcessInfo.beginActivity` 阻止 App Nap、显示器空闲睡眠及系统空闲睡眠，结束或失败后释放 activity。不得承诺绕过手动锁屏、合盖或 MDM 策略。
- 项目、App 和模型都不得放入 Google Drive 或其他云盘同步目录。

若用户明确改变上述决策，先确认影响，再修改代码和本文件。

## 3. 目标环境与本地路径

- 运行目标：24GB Apple Silicon Mac，macOS 14 或更新版本。
- 项目：GitHub 公开仓库 `nightfade/TravelCut`
- 发布产物：`dist/`，不进 Git。安装包作为 GitHub Release 附件发布
- 目标 Mac 的模型：`~/Library/Application Support/TravelCut/Models/`，MobileCLIP 和 Qwen 都在首次使用时下载
- 仓库是公开的：不要提交模型权重、个人路径或个人信息

## 4. 当前处理流程

入口为 `HighlightEngine.run`：

1. `MediaDiscovery` 递归发现 MP4、MOV、M4V、MTS 和 M2TS，读取创建时间、时长、尺寸、方向变换、帧率、编码、HDR、音轨和 AVFoundation 可读元信息。
2. `EventSegmenter` 用低分辨率帧直方图检测场景变化，形成自然事件。超过 45 秒的连续事件仅在分析阶段按 45 秒、3 秒重叠分块；相邻入选块之后重新合并。
3. `VisionAnalyzer` 对每个事件取 1 到 3 帧，结合 Apple Vision 美学、面部质量、特征指纹、亮度、清晰度和 MobileCLIP-S2 做快速技术及语义筛选；MobileCLIP 的正向语义由用户所选内容类型动态生成。
4. `AudioEventAnalyzer` 使用 Apple Sound Analysis 检测笑声、欢呼、掌声、讲话、风噪等现场声音，并把摘要交给深度模型。
5. `HighlightSelector.candidatesForDeepAnalysis` 保留技术合格候选。合格候选不超过 120 个时全部交给 Qwen；更多时至少取 120 个，并确保不少于配置比例，App 当前比例为 40%。这是偏重召回率的设计。
6. `QwenVideoAnalyzer` 从候选中顺序抽取最多 10 张 640 像素 JPEG，通过安装包内的 llama.cpp 调用 Qwen3-VL-4B。提示词带入用户所选内容类型，并要求对符合选择的普通旅途记录按记录价值判断，而不是只保留稀有或戏剧性事件；输出 keep、三个评分、中文标签、理由和建议起止时间。
7. `HighlightSelector.select` 应用深度判断阈值、视觉重复检测和时间重叠处理，再合并同一自然事件的连续分析块，并按拍摄时间排序。
8. 最终选择先写入 `.travelcut-selection-checkpoint.json`，再按来源码率估算输出空间。空间不足会在导出前停止，但保留筛选结果。
9. `ClipExporter` 使用 passthrough 独立导出各片段，每完成一段就更新检查点；恢复任务会跳过已经成功的输出。全部完成后写入 `selection.json` 并删除检查点。

这里的 45 秒是模型分析分块上限，不是输出片段长度上限。不得把它暴露成用户的“每段时长”参数。

## 5. 模型与运行时

### 快速层

- Apple Vision、Core Image、Core ML、Sound Analysis 均为系统框架。
- MobileCLIP-S2 图像与文本 Core ML 模型来自 Apple 官方仓库 `apple/coreml-mobileclip`，固定 revision `3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947`。
- 首次处理素材、开始快速筛选前下载，共 6 个文件约 199MB，保存在 `~/Library/Application Support/TravelCut/Models/coreml-mobileclip-<revision>/`。编译后的 `.mlmodelc` 缓存在 `~/Library/Caches/TravelCut/MobileCLIP-S2-v1/`。
- MobileCLIP 权重许可只允许研究用途，所以不随 App 或仓库分发，由用户从 Apple 下载。不得重新把权重打进安装包或提交进仓库。
- 分词器文件 `clip-merges.txt`、`clip-vocab.json` 来自 OpenAI CLIP（MIT），仍随 App 打包。

### 深度层

- 仓库：`Qwen/Qwen3-VL-4B-Instruct-GGUF`
- 固定 revision：`1cd86afb9a95c410a6038ab3b40d8b578c892266`
- 主模型：`Qwen3VL-4B-Instruct-Q4_K_M.gguf`，2,497,281,664 bytes
- 视觉投影：`mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf`，453,974,304 bytes
- 首次实际处理素材时下载，约 2.95GB；加上 MobileCLIP 共约 3.15GB。下载支持断点续传，之后可离线使用。
- 下载实现位于 `ModelInstaller.swift`，`ModelInstaller.qwen` 和 `ModelInstaller.mobileCLIP` 两套文件清单共用同一个断点续传下载器。模型保存在用户的 Application Support，不放入 App，因此安装包约 7MB。
- 推理使用 `Resources/llama/` 中的官方 Apple Silicon llama.cpp build `b11105`。版本和来源记录在 `Resources/llama/VERSION.txt`。
- 当前使用 Q4_K_M 主模型和 Q8_0 projector，在 24GB 目标上优先保证质量与内存平衡。

曾尝试 MLX Swift，但在当前工具环境遇到 Metal JIT cache 权限失败，因此安装版改用固定的 llama.cpp GGUF 运行时。不要在没有跨机器验证的情况下恢复 MLX 依赖。

## 6. 代码地图

- `Sources/TravelCutApp/main.swift`：SwiftUI 界面、选择输入目录、多选并持久化想保留的内容、生成唯一输出目录、启动任务。
- `Sources/TravelCutCore/HighlightEngine.swift`：完整流水线和进度编排。
- `Sources/TravelCutCore/Models.swift`：配置、媒体、候选、深度结果、报告和错误类型。
- `Sources/TravelCutCore/MediaDiscovery.swift`：素材发现、规格及元信息读取、旅程时间排序。
- `Sources/TravelCutCore/EventSegmenter.swift`：场景边界、自然事件和长事件分析分块。
- `Sources/TravelCutCore/VisionAnalyzer.swift`：多帧视觉与技术质量快速分析。
- `Sources/TravelCutCore/MobileCLIPAnalyzer.swift`、`CLIPTokenizer.swift`：本地语义分类和嵌入。
- `Sources/TravelCutCore/AudioEventAnalyzer.swift`：现场声事件分析。
- `Sources/TravelCutCore/HighlightSelector.swift`：深度候选、阈值、去重、合并和排序。
- `Sources/TravelCutCore/QwenVideoAnalyzer.swift`：分析帧提取、提示词、llama.cpp 子进程和 JSON 解析。
- `Sources/TravelCutCore/ModelInstaller.swift`：固定版本 GGUF 下载、校验大小、空间检查和断点续传。
- `Sources/TravelCutCore/ClipExporter.swift`：passthrough 导出、命名、时间和报告数据。
- `Sources/TravelCutCore/RecoveryCheckpoint.swift`：素材指纹、筛选检查点、空间预检、断点恢复和恢复自测。
- `Sources/TravelCutCLI/main.swift`：命令行入口，`--fast-only` 仅供诊断。
- `Sources/TravelCutSelfTest/main.swift`：无需真实素材的核心逻辑自测。
- `Resources/Info.plist`：App 版本、bundle identifier 和最低系统。
- `scripts/build-app.sh`：arm64 release App 组装和临时签名。
- `scripts/package-release.sh`：ZIP、PKG 与 SHA-256 文件生成。

## 7. 构建、测试与打包

在项目根目录执行：

```bash
swift build --disable-sandbox -c release --triple arm64-apple-macosx14.0
swift run --disable-sandbox travelcut-selftest
./scripts/package-release.sh
```

修改发布版本时必须同步更新：

- `Resources/Info.plist` 中的 short version 和 build number
- `scripts/package-release.sh` 中的 ZIP、PKG 文件名
- `README.md` 中的安装包名称
- 本文件中的当前版本

发布后至少检查：

```bash
codesign --verify --deep --strict dist/TravelCut.app
file dist/TravelCut.app/Contents/MacOS/TravelCut
file dist/TravelCut.app/Contents/Helpers/llama/llama-mtmd-cli
unzip -t dist/TravelCut-<版本>-macOS.zip
```

两个可执行文件都必须是 arm64，App 的 minimum OS 必须是 14.0，llama.cpp 当前 minimum OS 是 13.3。

当前包只有临时 ad-hoc App 签名，PKG 未签名，也没有 Apple notarization。另一台 Mac 推荐使用 ZIP，拖入“应用程序”后首次右键选择“打开”。若要求无安全提示的公开分发，需要 Developer ID Application、Developer ID Installer 及 Apple 公证，不能伪装成已公证。

## 8. 已完成验证

截至 2026-10-17：

- Swift release 构建通过，`travelcut-selftest` 全部通过。
- App 深层代码签名结构验证通过，ZIP 完整性验证通过。
- 安装包内 llama.cpp 已实际加载固定 Qwen 模型并完成图像描述。
- 单张图最终烟雾测试最大 resident set 约 3.49GB；此前 10 帧测试约 3.93GB，无 swap。由此判断 24GB 内存充足，但尚未在实际目标 Mac 上做验收。
- 真实视频快速流水线曾成功识别可变长度事件并导出片段。
- 使用 ffprobe 检查过样例：来源与输出保持 H.264、854x480、24fps 和 AAC；Finder/Spotlight 创建时间保持为原始时间。
- Qwen 完整调用曾返回合法中文 JSON，并正确拒绝不属于旅行高光的测试动画。
- 0.2.1 的标签链路已用同一张真实海岸风景图做正反测试：选择「沿途风景,自然景观」时 MobileCLIP 标为沿途风景、Qwen 保留并导出；只选择「人物互动」时 Qwen 因没有人物而拒绝，证明选择会影响实际选片。
- 0.2.1 增加用户可多选的内容偏好，并修正沿途风景因“不够稀有”而被过度过滤的问题。
- 0.2.2 增加磁盘空间预检、筛选与逐片段检查点、自动恢复、处理期间保持唤醒，并把原文件名加入输出名称。
- 0.2.3 修复部分卷的 important-usage 容量错误返回 0GB 导致的误拦截，改用普通容量、文件系统容量及重要用途容量三级回退。
- 0.3.0（2026-10-17）为公开仓库做准备：MobileCLIP 改为首次使用时从 Apple 官方仓库下载，安装包从约 182MB 降到约 7MB。下载的 6 个文件与原先打包的逐字节一致（SHA-256 相同）。用全新编译缓存跑通快速流水线，语义标签由模型给出。模型下载的磁盘预检对非正数容量视为未知，不再误报空间不足。bundle ID 改为 `local.nightfade.travelcut`，旧版记住的偏好不会带过来。`build-app.sh` 改为用 `swift build --show-bin-path` 取产物路径，兼容新版 SwiftPM 的目录结构。

## 9. 已知边界与下一步

- 最重要的下一步是在实际 24GB 目标 Mac 上，使用用户真实旅行素材做首轮验收和质量校准。不要仅用合成视频调整阈值。
- 需要建立一小批人工标注的真实素材基准，分别记录应保留事件、理想起止点、漏选、误选、重复和标签质量，再决定是否调整提示词、阈值或深度候选比例。
- DOVER-Mobile 尚未集成。加入前必须完成 Core ML 转换、许可检查、内存和速度测量，并用真实素材证明它比当前质量层有实质增益。
- 目前的场景边界是帧直方图方案，对缓慢转场和一个长镜头内的多个语义事件仍可能不够精确。
- 通用模型无法知道普通画面对用户的私人纪念意义。将来可考虑可选的“人物/地点偏好”，但不能让用户预先猜总时长。
- passthrough 的精确裁切受关键帧和容器 edit list 影响。若未来增加重编码精确裁切，必须作为明确的可选模式，不能破坏默认保真路径。
- AVFoundation 不能保证所有相机厂商私有元信息随新容器原样复制；`selection.json` 是可追溯兜底，不应删除。
- 当前没有 Apple Developer ID 签名与公证。

## 10. 修改纪律与验收清单

- 修改前先运行现有 self-test，确认基线；修改后再次运行。
- 不要把模型加入安装包或提交进仓库，不要把模型或构建产物移入 Google Drive。
- 不要删除或改写用户原始视频。测试输出放进明确的临时目录或独立输出目录。
- 不要用一段固定长度替代事件边界，也不要为了性能静默降低源文件输出规格。
- 不要并发运行多个 Qwen 候选。24GB 目标机优先稳定性。
- 变更模型仓库、revision、量化、llama.cpp 版本、提示词或选择阈值时，必须在本文件记录原因和新的基准结果。
- 变更输出时，用 ffprobe 或 AVFoundation 对比至少一个横屏、一个竖屏、一个 4K HDR 样例的编码、尺寸、帧率、色彩/HDR、音轨和时间元信息。
- 修改媒体发现逻辑时，确保 `TravelCut 高光片段*` 和带 `selection.json` 的旧结果目录不会被再次当作输入递归处理。
- 修改筛选算法、提示词或检查点字段后必须同步提升 `SelectionCheckpoint.schemaVersion`，避免新版恢复不兼容的旧筛选结果。
- 交付前重新构建 ZIP，验证签名结构、架构、压缩包完整性，并在最终回复中明确区分“开发机验证”和“24GB 目标机实测”。
