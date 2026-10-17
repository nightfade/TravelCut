# TravelCut

TravelCut 是完全在 Mac 本地运行的旅行视频高光提取工具。它不生成最终影片，而是分析整批素材，挑出值得保留的事件，按自然边界裁成独立视频，供剪映模板继续成片。

开发者或后续 AI 修改项目前，请先完整阅读 [`AGENTS.md`](AGENTS.md)。它是产品约束、架构、模型版本、验证状态和交接信息的唯一入口。

## 使用方式

1. 从 GitHub Release 下载最新的 `TravelCut-<版本>-macOS.zip`，在目标 Mac 解压，把 `TravelCut.app` 拖入“应用程序”。
2. 首次在 Finder 中右键 App 并选择“打开”。
3. 选择包含旅行视频的文件夹，再多选想保留的内容标签。默认全选，也可以只保留沿途风景、自然景观、城市街景、地标建筑、人物互动、当地美食、活动人文或动物中的部分类型。
4. 点击“自动挑选高光”。标签会同时影响快速筛选与 Qwen 深度判断，而不只是输出文件名。
5. 首次处理会联网下载约 3.15 GB 模型；以后可以离线使用。
6. 在自动创建的 `TravelCut 高光片段` 文件夹中取得结果。

当前测试包采用本地临时签名，尚未经过 Apple 公证。若要做到从网络下载后直接双击、完全不出现安全提示，需要使用 Apple Developer ID 签名并提交公证。

输出文件按拍摄时间排序编号，文件名格式示例：

```text
001_20260718_093512_DJI_0042_山顶日出.mov
002_20260718_101833_IMG_1847_缆车远眺.mp4
```

原文件名位于拍摄时间与 AI 语义标签之间，方便直接追溯来源；`selection.json` 另存完整源文件路径。

应用不要求预设总时长或单段时长。每段长度由事件的实际起止点决定。

## 本地分析流程

1. 读取全部素材的拍摄时间和媒体规格。
2. 检测场景变化，划分自然事件；超长连续镜头只在分析时分块，连续入选部分会重新合并。
3. 使用 MobileCLIP-S2、Apple Vision 和多帧技术指标快速排除黑屏、误拍、严重失焦及明显重复内容。
4. 使用 Apple Sound Analysis 检测笑声、欢呼、掌声、讲话、风噪等现场声音。
5. 只把初筛候选交给 Qwen3-VL-4B，结合用户选择的内容类型、多帧和声音标签判断记录价值、完整性、标签和最终起止时间。选中“沿途风景”后，不会仅因景色常见而拒绝清晰稳定的旅途记录。
6. 在整批素材中比较、去重并按拍摄时间排序。
7. 使用 AVFoundation passthrough 从原文件分别裁出高光，不创建统一画布，也不添加转场或配乐。

所有视频分析均在本机完成，不调用云端 AI API，也不消耗在线模型 token。

## 模型与硬件

- 深度模型：Qwen3-VL-4B-Instruct，Q4_K_M 量化。
- 视觉投影：Q8_0。
- 推理后端：随 App 分发的 llama.cpp Apple Silicon 版本。
- 快速层模型：Apple MobileCLIP-S2 的 Core ML 版本，从 Apple 官方 Hugging Face 仓库 `apple/coreml-mobileclip` 下载，约 199 MB。
- 首次使用共下载约 3.15 GB 模型文件，固定保存在 `~/Library/Application Support/TravelCut/Models/`。
- 最低系统：Apple Silicon Mac，macOS 14 或更新版本。
- 推荐内存：24 GB。分析候选按顺序执行，每次最多使用10帧，避免批量并发占满内存。

## 媒体保真

每段高光使用 `AVAssetExportPresetPassthrough` 导出，不统一分辨率、横竖方向或帧率，也不重新渲染画面。原始视频与音频轨、HDR信号和可由目标容器承载的元信息会保留。MTS/M2TS 等不适合作为输出容器的格式会改装入 MOV，但不会主动改变音视频编码。

`selection.json` 同时记录来源文件、原始时间范围、分辨率、帧率、编码、HDR、声音标签和 AVFoundation 可读取的源元信息，便于追溯容器未能携带的字段。

## 中断恢复与保持唤醒

- 完成整批筛选后，TravelCut 会先把入选片段写入隐藏检查点，再开始导出。
- 每成功导出一段就更新检查点。磁盘空间不足、App 退出或导出失败后，清理空间并用相同素材和标签再次运行，会跳过已经完成的分析与片段。
- 导出前会按来源文件码率和入选时长估算所需空间，并预留安全余量；不足时先停止导出，但保留筛选结果。空间容量通过多种 macOS API 交叉回退，异常的 0 或负数不会被当作真实容量。
- 筛选与导出期间会阻止 App Nap、显示器空闲睡眠和系统空闲睡眠，避免普通自动锁屏让本地模型暂停。任务结束或失败后恢复系统原有设置。
- 手动锁定屏幕、合上笔记本或公司 MDM 强制锁定不在 App 可绕过的范围内。

## 当前边界

- 通用模型不知道某个普通画面对个人的特殊纪念意义。
- 无损直通裁剪受原视频关键帧结构影响；播放器可能依赖编辑列表从准确时间开始播放。
- 当前快速质量层使用多帧 Vision 与技术指标。DOVER-Mobile 尚未纳入安装版，需要先完成 Core ML 转换和真实旅行素材基准测试，不能仅凭论文指标加入。
- MobileCLIP 权重由 Apple 以研究用途许可发布，TravelCut 不分发它，而是在首次使用时从 Apple 官方仓库下载。使用前请阅读 `Sources/TravelCutCore/Resources/Licenses/MobileCLIP-MODEL-LICENSE.txt`。

## 构建与验证

```bash
git clone https://github.com/nightfade/TravelCut.git
```

```bash
swift build --disable-sandbox
swift run --disable-sandbox travelcut-selftest
./scripts/package-release.sh
```

命令行版本：

```bash
swift run --disable-sandbox travelcut-cli \
  --input "/path/to/videos" \
  --output-folder "/path/to/highlights" \
  --themes "沿途风景,自然景观,城市街景"
```

`--fast-only` 仅用于开发诊断，会跳过 Qwen3-VL 深度判断。
