import Foundation
import TravelCutCore

@main
struct TravelCutCLI {
    static func main() async {
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

    private static func printHelp() {
        print("""
        TravelCut CLI

          travelcut-cli --input <素材文件夹> [--output-folder <输出文件夹>]
                        [--themes "沿途风景,自然景观"] [--fast-only]

          可用标签：\(themeNames)
        """)
    }

    private static var themeNames: String {
        HighlightTheme.allCases.map(\.rawValue).joined(separator: ", ")
    }
}
