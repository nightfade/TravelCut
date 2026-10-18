import Foundation
import TravelCutCore

@main
struct TravelCutCLI {
    static func main() async {
        if CommandLine.arguments.contains("--photos") {
            await runPhotos()
            return
        }
        do {
            let configuration = try parseArguments()
            let summary = try await HighlightEngine().run(configuration: configuration) { update in
                let percent = Int(update.fraction * 100)
                FileHandle.standardError.write(Data("[\(percent)%] \(update.message)\n".utf8))
            }
            print("完成：\(summary.outputFolder.path)")
            print("从 \(summary.inputVideoCount) 个视频中导出 \(summary.selectedClipCount) 段独立高光")
            print("选片报告：\(summary.reportFile.path)")
        } catch {
            FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func parseArguments() throws -> JobConfiguration {
        var input: URL?
        var outputFolder: URL?
        var useDeepAnalysis = true
        var selectedThemes = HighlightTheme.defaultSelection
        var index = 1
        let arguments = CommandLine.arguments

        while index < arguments.count {
            switch arguments[index] {
            case "--input":
                index += 1
                guard index < arguments.count else {
                    throw TravelCutError.invalidArguments("--input 缺少路径")
                }
                input = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--output-folder":
                index += 1
                guard index < arguments.count else {
                    throw TravelCutError.invalidArguments("--output-folder 缺少路径")
                }
                outputFolder = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--fast-only":
                useDeepAnalysis = false
            case "--themes":
                index += 1
                guard index < arguments.count else {
                    throw TravelCutError.invalidArguments("--themes 缺少逗号分隔的标签")
                }
                let names = arguments[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let themes = Set(names.compactMap(HighlightTheme.init(rawValue:)))
                let unknown = names.filter { HighlightTheme(rawValue: $0) == nil }
                guard !themes.isEmpty, unknown.isEmpty else {
                    throw TravelCutError.invalidArguments(
                        "未知或空标签：\(unknown.joined(separator: ", "))；可用标签：\(themeNames)"
                    )
                }
                selectedThemes = themes
            case "--list-themes":
                print(themeNames)
                Foundation.exit(0)
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                throw TravelCutError.invalidArguments("未知参数：\(arguments[index])")
            }
            index += 1
        }

        guard let input else {
            printHelp()
            throw TravelCutError.invalidArguments("必须提供 --input")
        }
        return JobConfiguration(
            inputFolder: input,
            outputFolder: outputFolder ?? input.appendingPathComponent("TravelCut 高光片段"),
            useDeepAnalysis: useDeepAnalysis,
            selectedThemes: selectedThemes
        )
    }

    /// Photo culling: ratings go into the RAW sidecars under the input folder.
    private static func runPhotos() async {
        var input: URL?
        var themes = HighlightTheme.defaultSelection
        var useQwen = true
        var write = true
        var index = 1
        let arguments = CommandLine.arguments
        while index < arguments.count {
            switch arguments[index] {
            case "--photos": break
            case "--input":
                index += 1
                if index < arguments.count { input = URL(fileURLWithPath: arguments[index]).standardizedFileURL }
            case "--themes":
                index += 1
                if index < arguments.count {
                    themes = Set(arguments[index].split(separator: ",").compactMap {
                        HighlightTheme(rawValue: $0.trimmingCharacters(in: .whitespaces))
                    })
                }
            case "--fast-only": useQwen = false
            case "--dry-run": write = false
            default:
                FileHandle.standardError.write(Data("错误：未知参数 \(arguments[index])\n".utf8))
                Foundation.exit(1)
            }
            index += 1
        }
        guard let input else {
            printHelp()
            Foundation.exit(1)
        }
        do {
            let summary = try await PhotoCullEngine().run(configuration: PhotoCullConfiguration(
                inputFolder: input, selectedThemes: themes, useQwen: useQwen, writeRatings: write
            )) { update in
                FileHandle.standardError.write(Data("[\(Int(update.fraction * 100))%] \(update.message)\n".utf8))
            }
            print("完成：\(summary.photoCount) 张照片，分成 \(summary.groupCount) 组")
            print("2 星以上 \(summary.starredCount) 张，拒绝 \(summary.rejectedCount) 张")
            if summary.skippedUserMarked > 0 { print("已有你的星级或标签而跳过：\(summary.skippedUserMarked) 张") }
            if summary.withoutRAW > 0 { print("没有 RAW、未写入：\(summary.withoutRAW) 张") }
            print(summary.wroteRatings ? "星级已写入 RAW 旁边的 .xmp" : "试运行：没有写入任何星级")
            print("报告：\(summary.reportFile.path)")
        } catch {
            FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func printHelp() {
        print("""
        TravelCut CLI

          travelcut-cli --input <素材文件夹> [--output-folder <输出文件夹>]
                        [--themes "沿途风景,自然景观"] [--fast-only]

          照片精选（星级写入 RAW 旁边的 .xmp，Bridge 可读）：
          travelcut-cli --photos --input <照片根目录> [--themes …] [--fast-only] [--dry-run]

          可用标签：\(themeNames)
        """)
    }

    private static var themeNames: String {
        HighlightTheme.allCases.map(\.rawValue).joined(separator: ", ")
    }
}
