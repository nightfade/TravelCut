import Foundation

/// Offline coordinate → place name, from GeoNames `cities500` (CC BY 4.0): every town with 500+
/// people. Downloaded once on first need and kept in Application Support; lookups never leave the Mac.
struct Place: Equatable, Codable, Sendable {
    let countryCode: String
    let country: String   // Chinese name from the system locale, e.g. 挪威
    let city: String      // Chinese name when GeoNames has one, else the local name, e.g. 特罗姆瑟 / Tromsø

    var keywordPath: [String] { ["TravelCut", "地点", country, city] }
    var text: String { "\(country) \(city)" }
}

final class GeoPlaces {
    struct Entry {
        let latitude: Double
        let longitude: Double
        let population: Int
        let name: String
        let chineseName: String?
        let countryCode: String
    }

    static let fileName = "cities500.txt"
    static let source = URL(string: "https://download.geonames.org/export/dump/cities500.zip")!
    /// Within this radius, size and closeness are traded off: log10(population) minus distance / 2.5 km.
    /// Central Paris stays 巴黎 rather than a suburb, while Versailles stays 凡尔赛 rather than the
    /// larger new town 8 km away (a plain "most populous within 10 km" picked the new town).
    static let preferredRadiusKm = 10.0
    static let kmPerPopulationDecade = 2.5
    /// Otherwise the nearest place this close; beyond it, no name rather than a misleading one.
    static let fallbackRadiusKm = 50.0

    private var cells: [Int: [Entry]] = [:]

    init(entries: [Entry]) {
        for entry in entries { cells[Self.cell(entry.latitude, entry.longitude), default: []].append(entry) }
    }

    /// Loads the installed database, downloading it first if needed.
    static func load(progress: @Sendable @escaping (String) -> Void) throws -> GeoPlaces {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TravelCut/Geo", isDirectory: true)
        else { throw TravelCutError.modelUnavailable("无法访问 Application Support") }
        let file = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: file.path) {
            progress("首次使用正在下载离线城市数据（约 14 MB）…")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let zip = folder.appendingPathComponent("cities500.zip")
            try run("/usr/bin/curl", ["--location", "--fail", "--silent", "--show-error", "--retry", "3",
                                      "--output", zip.path, source.absoluteString])
            try run("/usr/bin/unzip", ["-o", "-q", zip.path, fileName, "-d", folder.path])
            try? FileManager.default.removeItem(at: zip)
        }
        progress("正在载入离线城市数据…")
        return GeoPlaces(entries: try parse(String(contentsOf: file, encoding: .utf8)))
    }

    /// GeoNames tab-separated columns: 1 name, 3 alternate names, 4 lat, 5 lon, 7 feature code,
    /// 8 country, 14 population.
    static func parse(_ text: String) throws -> [Entry] {
        let skipped: Set<Substring> = ["PPLX", "PPLH", "PPLQ", "PPLW"]   // city sections and gone places
        var entries: [Entry] = []
        entries.reserveCapacity(240_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count > 14, !skipped.contains(f[7]),
                  let lat = Double(f[4]), let lon = Double(f[5]) else { continue }
            entries.append(Entry(
                latitude: lat, longitude: lon, population: Int(f[14]) ?? 0, name: String(f[1]),
                chineseName: chineseName(in: f[3]), countryCode: String(f[8])
            ))
        }
        return entries
    }

    /// The first alternate name made only of CJK ideographs (Japanese uses katakana for foreign places).
    static func chineseName(in alternates: Substring) -> String? {
        for name in alternates.split(separator: ",") where !name.isEmpty && name.count <= 10 {
            if name.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) || $0 == "·" }) {
                return String(name)
            }
        }
        return nil
    }

    func place(latitude: Double, longitude: Double) -> Place? {
        let candidates = nearby(latitude, longitude)
            .map { ($0, Self.distanceKm(latitude, longitude, $0.latitude, $0.longitude)) }
        func score(_ entry: Entry, _ km: Double) -> Double {
            log10(Double(entry.population) + 10) - km / Self.kmPerPopulationDecade
        }
        let chosen = candidates.filter { $0.1 <= Self.preferredRadiusKm }.max { score($0.0, $0.1) < score($1.0, $1.1) }
            ?? candidates.filter { $0.1 <= Self.fallbackRadiusKm }.min { $0.1 < $1.1 }
        guard let entry = chosen?.0 else { return nil }
        let country = Locale(identifier: "zh_CN").localizedString(forRegionCode: entry.countryCode) ?? entry.countryCode
        return Place(countryCode: entry.countryCode, country: country, city: entry.chineseName ?? entry.name)
    }

    private func nearby(_ lat: Double, _ lon: Double) -> [Entry] {
        // Cells are 1°; at high latitude a degree of longitude is short, so look wider east and west.
        let lonSpan = Int(min(30, ceil(1 / max(0.05, cos(lat * .pi / 180)))))
        var result: [Entry] = []
        for dLat in -1...1 {
            for dLon in -lonSpan...lonSpan {
                result += cells[Self.cell(lat + Double(dLat), lon + Double(dLon))] ?? []
            }
        }
        return result
    }

    private static func cell(_ lat: Double, _ lon: Double) -> Int {
        let la = Int(floor(max(-90, min(89.999, lat)))) + 90
        var lo = Int(floor(lon)) + 180
        lo = ((lo % 360) + 360) % 360
        return la * 360 + lo
    }

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, p = Double.pi / 180
        let a = sin((lat2 - lat1) * p / 2) * sin((lat2 - lat1) * p / 2)
            + cos(lat1 * p) * cos(lat2 * p) * sin((lon2 - lon1) * p / 2) * sin((lon2 - lon1) * p / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TravelCutError.modelUnavailable("离线城市数据下载失败（\((tool as NSString).lastPathComponent)）")
        }
    }
}

/// Places for photos without GPS, from the nearest geotagged photo in time.
enum PlaceInference {
    /// Only borrow a place from a photo taken this close in time; city level makes 30 min safe.
    static let window: TimeInterval = 30 * 60

    enum Source: String, Codable, Sendable { case gps = "GPS", inferred = "推断" }

    /// `known[i]` is photo i's own place, if it has GPS. Times need not be sorted.
    static func infer(times: [Date], known: [Place?]) -> [(Place, Source)?] {
        let tagged = times.indices.filter { known[$0] != nil }.sorted { times[$0] < times[$1] }
        let taggedTimes = tagged.map { times[$0] }
        return times.indices.map { index -> (Place, Source)? in
            if let own = known[index] { return (own, .gps) }
            guard !tagged.isEmpty else { return nil }
            // Binary search for the first geotagged photo at or after this time.
            var low = 0, high = tagged.count
            while low < high {
                let mid = (low + high) / 2
                if taggedTimes[mid] < times[index] { low = mid + 1 } else { high = mid }
            }
            let neighbors = [low - 1, low].filter { $0 >= 0 && $0 < tagged.count }
                .map { (tagged[$0], abs(taggedTimes[$0].timeIntervalSince(times[index]))) }
                .filter { $0.1 <= window }
            guard let nearest = neighbors.min(by: { $0.1 < $1.1 }), let place = known[nearest.0] else { return nil }
            return (place, .inferred)
        }
    }
}
