// Tokenization follows Apple's MIT-licensed MobileCLIP sample and the
// Hugging Face swift-coreml-transformers implementation. See bundled licenses.

import Foundation

private struct BytePair: Hashable {
    let first: String
    let second: String
}

final class CLIPTokenizer {
    private let contextLength = 77
    private let bpeRanks: [BytePair: Int]
    private let encoder: [String: Int]
    private let byteEncoder: [UInt8: String]

    init() throws {
        guard let resourceBundle = TravelCutResources.bundle,
              let mergesURL = resourceBundle.url(
            forResource: "clip-merges",
            withExtension: "txt",
            subdirectory: "Resources/Models"
        ), let vocabURL = resourceBundle.url(
            forResource: "clip-vocab",
            withExtension: "json",
            subdirectory: "Resources/Models"
        ) else {
            throw TravelCutError.invalidArguments("MobileCLIP tokenizer resources are missing")
        }

        let merges = try String(contentsOf: mergesURL, encoding: .utf8)
            .split(separator: "\n")
            .dropFirst()
        var ranks: [BytePair: Int] = [:]
        for (index, line) in merges.enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[BytePair(first: String(parts[0]), second: String(parts[1]))] = index
        }
        bpeRanks = ranks

        let data = try Data(contentsOf: vocabURL)
        encoder = try JSONDecoder().decode([String: Int].self, from: data)
        byteEncoder = Self.makeByteEncoder()
    }

    func encode(_ text: String) -> [Int32] {
        var tokens: [Int] = []
        for token in byteEncode(text.lowercased()) {
            tokens.append(contentsOf: bpe(token).split(separator: " ").compactMap { encoder[String($0)] })
        }
        tokens = Array(tokens.prefix(contextLength - 2))

        var result = [Int32](repeating: 0, count: contextLength)
        result[0] = Int32(encoder["<|startoftext|>"] ?? 0)
        for (index, token) in tokens.enumerated() { result[index + 1] = Int32(token) }
        result[tokens.count + 1] = Int32(encoder["<|endoftext|>"] ?? 0)
        return result
    }

    private func byteEncode(_ text: String) -> [String] {
        let pattern = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            return String(text[tokenRange].utf8.compactMap { byteEncoder[$0] }.joined())
        }
    }

    private func bpe(_ token: String) -> String {
        if token.count <= 1 { return token + "</w>" }
        var word = token.map(String.init)
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var bestPair: BytePair?
            var bestRank = Int.max
            for index in 0..<(word.count - 1) {
                let pair = BytePair(first: word[index], second: word[index + 1])
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestPair = pair
                }
            }
            guard let pair = bestPair else { break }

            var merged: [String] = []
            var index = 0
            while index < word.count {
                if index < word.count - 1,
                   word[index] == pair.first,
                   word[index + 1] == pair.second {
                    merged.append(pair.first + pair.second)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
        }
        return word.joined(separator: " ")
    }

    private static func makeByteEncoder() -> [UInt8: String] {
        var bytes = Array(UInt8(33)...UInt8(126))
        bytes += Array(UInt8(161)...UInt8(172))
        bytes += Array(UInt8(174)...UInt8(255))
        var codePoints = bytes.map(Int.init)
        var next = 0
        for value in 0...255 where !bytes.contains(UInt8(value)) {
            bytes.append(UInt8(value))
            codePoints.append(256 + next)
            next += 1
        }
        return Dictionary(uniqueKeysWithValues: zip(bytes, codePoints.map {
            String(UnicodeScalar($0)!)
        }))
    }
}
