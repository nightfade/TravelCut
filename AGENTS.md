# TravelCut AI 接手指南

这是 TravelCut 项目的开发与交接入口。后续 AI 或开发者开始修改前，必须完整阅读本文件，再阅读 `README.md`。不要另建内容重叠的上下文文档；产品决策、架构或交付状态发生变化时，同步更新本文件。

## 1. 项目目标

TravelCut 是面向 macOS 的本地旅行视频高光提取工具。它的输出不是最终影片，而是一组可直接投入剪映模板的独立高光视频片段。

核心工作是：先理解整批素材，再找出值得保留的自然事件，确定各自真实起止点，裁成单独文件，按旅程时间排序、编号并添加中文语义标签。

当前版本：`0.7.0`，build `18`。

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
- 输出按旅行的天分文件夹 `D<第几天>_<MMdd>_<周几>/`，天数按日历天计算，没有片段的日子也占一个编号。文件名为 `当天序号_拍摄时分_主题_语义标签_原文件名.ext`，标签与主题相同时不重复。原文件名必须保留，让用户无需打开报告即可追溯来源；`selection.json` 继续记录完整源路径。目标是把一天的文件夹拖进剪映即得到按时间排好的素材。
- 日期按相机写入 `com.apple.quicktime.creationdate` 的时区计算，没有记录时回退到运行这台 Mac 的时区。切片内嵌的创建时间是该片段开始的时刻，并保留原时区。实现在 `ClipOrganizer.swift`。
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
- 0.7.0（2026-10-19）地点：读 EXIF GPS（S/W 取负，0/0 视为无定位）；`GeoPlaces` 用 GeoNames cities500 离线查城市（首次需要时下载到 Application Support，跳过 PPLX 等城区和已消失的地点；10 公里内按 log10(人口) − 距离/2.5km 取分最高者，否则 50 公里内最近，否则无）；国家名用系统中文名，城市名取别名里第一个纯汉字的名字，否则当地名（欧洲 5 万人以上城镇约 55% 有中文名）。`PlaceInference`：无 GPS 的照片取 30 分钟内时间最近的带位置照片的城市。关键字 `TravelCut|地点|国家|城市`；推断的地点只写关键字，不写 GPS（用户确认）。地点放进 Qwen 提示，`qwenVersion` 升为 2。地点查询失败只记日志，不中断。实测：巴黎、特罗姆瑟、布拉格正确；盖朗厄尔落到所属的 Stranda；10 分钟后无 GPS 的照片推断为布拉格，2.5 小时后的不推断；Qwen 写出「特罗姆瑟港口雪景」；凡尔赛宫一开始被标成 8 公里外人口更多的 Saint-Quentin-en-Yvelines，改成人口与距离加权后正确。
- 0.6.5（2026-10-19）Qwen 的标签之前只在报告里，没写进 XMP；现在加在标题末尾并写成关键字 `TravelCut|标签|…`，同组成员都带上。标题仍以「组 」开头，写入器据此识别自己的标题。
- 0.6.4（2026-10-19）「导出画面特征」「保存调试日志」做成照片精选界面上的开关（记住上次选择），日志写到照片根目录「TravelCut 调试日志.txt」，用户不必再从终端启动。所有调试输出改走 `TravelCutLog`：`TRAVELCUT_DEBUG=1` 写 stderr，开关写文件。命令行新增 `--export-features`、`--debug-log`。
- 0.6.3（2026-10-19）新增分析缓存 `PhotoCache`：`<root>/.travelcut-cache/analysis-v1.jsonl` 和 `qwen-v1.jsonl`，追加写入，每张、每组完成即落盘。照片键是相对根目录的路径加拍摄时间（不用大小和修改时间，因为写 JPEG 星级会改大小）；只存 MobileCLIP 特征，主题按当前选择用 `MobileCLIPAnalyzer.classify` 重算；特征以 Float32 原始字节 base64 存；画面指纹用 NSKeyedArchiver；Vision 失败的照片不缓存；Qwen 键是主题加候选照片键；打开时若最后一行不完整先补换行，读取时跳过坏行。改了分析算法或提示词时必须递增 `analysisVersion` / `qwenVersion`。实测 46 张：首跑 30 秒，重跑 0.7 秒且结果完全一致；中途 kill 后续跑复用已完成的 31 张。
- 0.6.2（2026-10-19）用户的个人 Mac 上 Qwen 每组约 30 秒（本机约 3.5 秒），9,000 张跑了十多个小时才完成约四分之一。推断主因是每组都重新启动 llama-mtmd-cli、重新加载约 3GB 模型。改动：App 的 Qwen 开关默认关闭（检验显示 Qwen 对挑片没有帮助，主要价值是标签）；单张可用照片的组不再调用 Qwen（约占三分之二），主题由 MobileCLIP 给出；每组最多 3 张、`--image-max-tokens` 384；特征文件在分析和分组之后、Qwen 之前写出。根治需要常驻的推理服务（llama-server）避免反复加载模型，尚未做。
- 0.6.1（2026-10-18）修复照片精选的内存泄漏：分析循环在 async 任务里运行，Vision / Core Image 的 autorelease 对象从不释放，跑到约 5,000 张时 IOSurface 耗尽，之后每张照片的 Vision 请求都失败并静默回退默认值（美感 0.5、无画面特征、无人脸）。0.5.2 和 0.6.0 的欧洲行报告都有 3,750 张（41%，全在后半段）受影响，所以 0.6.0 记录的 AUC 评估被污染，需重新评估。每张照片包一层 `autoreleasepool` 后，4,800 张的内存峰值从 7.9GB 降到 0.52GB，耗时不变。用户这次 Qwen 卡在第一组，推断是同一原因导致的内存压力。另外：Vision 失败不再静默，按张记录在报告 `visionFailed` 并在完成时提示；Qwen 单组 3 分钟超时，超时或出错的组按技术分挑选并计数；进度在每组开始前更新；视频快速筛选循环也加了 autoreleasepool。
- 0.6.0（2026-10-18）用 2024 欧洲行 9,082 张 JPEG（4,489 组）检验，以用户修过的 486 张为参照（多为人像；风光修得少，不能作参照）。结论：最终星级 AUC 0.52，等于随机；单项指标 AUC 只有 0.6 左右（美感 0.63、人脸清晰度 0.64），Qwen 高光分在人像上 0.51；组内「最佳」与用户选中的那张无关（0.51）；Qwen 4,380 组全判保留。36 张用户修过的照片被拒，35 张在普罗旺斯：浅景深长焦人像整体清晰度低、脸小未检出，被 MobileCLIP 标「遮挡镜头」。卑尔根一组 47 张跨 5.4 分钟，是边走边拍的连锁合并。修改：废片只认全黑、全白、严重失焦；清晰度改为 384 像素 6×6 分块取最清楚的一块再乘 12（用配图加高斯模糊校准：清晰 0.3–1，严重模糊 <0.05，门槛 0.06）；一组从第一张起不超过 90 秒；星级改为「每组代表」：最佳 3 星，接近备选（≥95%）每 4 张最多 1 张 2 星，取消 4 星；JPEG / HEIC / TIFF / DNG 用 exiftool 写入文件元数据（`EmbeddedMetadataWriter`，批量 `-execute`，写后读回核对），所有权标记写成关键字 `TravelCut|写入星级|N`；`TRAVELCUT_EXPORT_FEATURES=1` 导出 MobileCLIP 特征，下一步用它训练个人口味模型并交叉验证。用 exiftool 13.59 实测：写入正确、像素哈希不变、用户 5 星和改过的星级都逐字节不动、重跑不重复关键字。
- 0.5.2（2026-10-18）第二次真实试运行（同一批 60 张 ARW）：预览都是 1024 像素，废片 3 张，Qwen 判断 34 组，选中位置分散在第 1–4 张，标签贴切（如「父女共读」）。但 Qwen 的高光分只有 0.6 / 0.7 / 0.85 三档，15 组并列 0.85，按分数门槛给 4 星占了 44%。改为按数量：4 星取保留组的前 15%（向上取整），同分时按技术分排，且不低于 0.82；Qwen 给分低于 0.65 的组，最佳那张给 2 星而不是 3 星。用这份报告重算：4 星 6、3 星 24、2 星 10、无星 17、拒绝 3。用户在 Bridge 里确认被拒绝的 3 张（清晰度约 0.15、无人脸）确实是废片。MobileCLIP 对这批家庭日常照片 43/60 标为「误拍废片」，说明它的排除提示词在非旅行题材上基本不可用，0.5.1 已不再单凭它判废片。
- 0.5.1（2026-10-18）首次真实试运行（60 张 ZV-E10 ARW）有 53 张被判为废片。原因一：ARW 里带 160×120 的内嵌缩略图，ImageIO 优先返回它，用邮票大小的图判断必然偏差；现在内嵌预览最长边不到 1000 像素时改为解码 RAW，并有自测覆盖（去掉这条修复时自测拿到的正是 160 像素）。原因二：MobileCLIP 的排除提示词对不贴旅行主题的日常照片容易胜出，原来单凭它就判废片；现在必须同时清晰度低（<0.2）才算。报告每张照片新增诊断字段：废片原因、清晰度、人脸清晰度、亮度、美感、是否工具性画面、MobileCLIP 标签、分析用图的尺寸。
- 0.5.0（2026-10-18）新增照片精选模式（`PhotoCullEngine`）。流程：`PhotoDiscovery` 递归找照片，RAW 和同名 JPEG 算一张，读 RAW 内嵌预览和 EXIF 时间（含 OffsetTimeOriginal）→ `PhotoAnalyzer` 复用 `VisionAnalyzer.analyzeFrame`，另加人脸区域清晰度和闭眼检测 → `PhotoGrouper` 只在同一文件夹内按时间连续分组（2 秒内且距离 ≤0.70，或 60 秒内且距离 ≤0.45；2 秒内有一张是废片也并组，因为糊片和换场景的距离都约 0.9）→ Qwen 看每组技术最好的最多 4 张（技术最好的放第一张，抵消模型偏向第一个选项）→ `PhotoRater` 评星 → `XMPSidecarWriter` 写 `.xmp`。4 星用相对门槛：保留组高光分的前 15%，且必须高于中位数、不低于 0.82，因为 Qwen 对多数像样的照片都给 0.85。XMP 规则：只写 RAW 的 sidecar；已有 `xmp:Rating` 或 `xmp:Label` 的整张跳过；TravelCut 写过的值记在 `travelcut:` 命名空间里，重跑时只有星级没被用户改过才覆盖；Camera Raw 等其他字段原样保留。用网上旅行配图造了 11 张的测试集（含模拟连拍、糊片、全黑、已有 5 星、只有 JPEG、两个文件夹），快速和 Qwen 两种模式的分组、评星、跳过规则都符合预期，Qwen 标签准确（如「查理大桥雪景」），每组约 3.5 秒。分组阈值和闭眼阈值（眼部高宽比 <0.15）是按这批测试图定的，**尚未用真实 RAW 旅行照片校准**；`TRAVELCUT_DEBUG=1` 会打印相邻照片的时间间隔和画面距离，用于调参。
- 0.4.0 主题描述补充：自然景观加入极光、星空、夜空、雪原；城市街景加入夜晚街景和节日灯饰；地标建筑加入教堂和建筑内部；博物馆只归地标建筑，活动人文加入灯光秀。排除提示词「空白画面」去掉了 dark frame，避免把夜空当废片。用 5 张公开授权的夜景照片（两张极光、银河、布拉格圣诞市集、香榭丽舍圣诞灯）做成视频对比：两张天空类从「沿途风景」改判为「自然景观」，语义分 0.57→0.73、0.64→0.80；两张圣诞灯 0.61→0.72、0.50→0.72。这是专业照片，真实手持夜景视频仍需验收。
- 0.4.0（2026-10-17）切片按天分文件夹整理，文件名加入拍摄时分和主题。Qwen 的 JSON schema 按所选主题动态生成枚举，必须返回 `theme`；没有深度判断时用 MobileCLIP 得分最高的已选主题。主题经检查点和 `selection.json` 保留，旧检查点缺这个字段也能读。自测新增整理规则用例（跨午夜、空白日、时区、主题兜底、标签去重、schema），以及可选的真实导出检查：`TRAVELCUT_EXPORT_SAMPLE=<带 QuickTime 时区创建时间、至少 12 秒的样片> swift run --disable-sandbox travelcut-selftest`。已用样片验证文件落在正确的日期文件夹、文件创建时间等于片段开始时刻、读回的内嵌时间保留原时区。
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
