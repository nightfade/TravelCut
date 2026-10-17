import Foundation

enum TravelCutResources {
    static let bundle: Bundle? = {
        let bundleName = "TravelCut_TravelCutCore.bundle"
        let executableFolder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            executableFolder.appendingPathComponent(bundleName),
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()
}
