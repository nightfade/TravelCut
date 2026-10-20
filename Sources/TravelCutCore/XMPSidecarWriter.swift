import Foundation

/// Writes rating, title and keywords into a RAW file's `.xmp` sidecar, the file Bridge and
/// Camera Raw read for RAW photos. The RAW itself is never touched.
///
/// Rules:
/// - Everything else in an existing sidecar (Camera Raw edits, other metadata) is kept.
/// - Without a rating (the default, organising only): title and keywords are written to every photo,
///   rated or not, and the user's rating and label are never touched. A rating TravelCut wrote in an
///   earlier version is cleared, unless the user has since changed it.
/// - With a rating: a photo the user already rated or colour-labelled is skipped entirely.
/// - Values TravelCut wrote before may be replaced on a re-run, unless the user has since changed
///   the rating. TravelCut remembers what it wrote in its own namespace to tell the two apart.
enum XMPSidecarWriter {
    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static let dcNS = "http://purl.org/dc/elements/1.1/"
    static let lrNS = "http://ns.adobe.com/lightroom/1.0/"
    static let rdfNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let tcNS = "https://github.com/nightfade/TravelCut/ns/1.0/"

    struct Fields: Equatable {
        let rating: Int?             // -1 rejected, 0 unrated, 1...5; nil leaves the rating alone
        let title: String
        let keywords: [[String]]     // hierarchical paths, e.g. ["TravelCut", "组", "组 0042"]
    }

    enum Outcome: String, Codable, Sendable {
        case written
        case skippedUserMarks
    }

    static func sidecarURL(for raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension("xmp")
    }

    @discardableResult
    static func apply(_ fields: Fields, to sidecar: URL) throws -> Outcome {
        let document: XMLDocument
        if FileManager.default.fileExists(atPath: sidecar.path) {
            document = try XMLDocument(contentsOf: sidecar, options: [.nodePreserveWhitespace])
        } else {
            document = try XMLDocument(xmlString: template, options: [])
        }
        let descriptions = (try document.nodes(forXPath: "//*[local-name()='Description']")) as? [XMLElement] ?? []
        guard let description = descriptions.first else {
            throw TravelCutError.invalidArguments("无法识别的 XMP 文件：\(sidecar.lastPathComponent)")
        }

        let currentRating = Int(value(of: "Rating", ns: xmpNS, in: descriptions) ?? "0") ?? 0
        let label = value(of: "Label", ns: xmpNS, in: descriptions) ?? ""
        let ourRating = value(of: "Rating", ns: tcNS, in: descriptions).flatMap(Int.init)
        if fields.rating != nil {
            if let ourRating {
                if currentRating != ourRating || !label.isEmpty { return .skippedUserMarks }
            } else if currentRating != 0 || !label.isEmpty {
                return .skippedUserMarks
            }
        }
        // Stored as a JSON array: XML normalizes newlines and tabs inside attribute values to spaces.
        let previousKeywords = (value(of: "Keywords", ns: tcNS, in: descriptions)?.data(using: .utf8))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []

        ensureNamespace("xmp", xmpNS, on: description)
        ensureNamespace("dc", dcNS, on: description)
        ensureNamespace("lr", lrNS, on: description)
        ensureNamespace("rdf", rdfNS, on: description)
        ensureNamespace("travelcut", tcNS, on: description)

        if let rating = fields.rating {
            setAttribute("Rating", prefix: "xmp", ns: xmpNS, value: String(rating), on: description, all: descriptions)
            setAttribute("Rating", prefix: "travelcut", ns: tcNS, value: String(rating), on: description, all: descriptions)
        } else if let ourRating {
            if currentRating == ourRating {
                setAttribute("Rating", prefix: "xmp", ns: xmpNS, value: "0", on: description, all: descriptions)
            }
            removeProperty("Rating", ns: tcNS, in: descriptions)
        }

        // Title: replace only an empty title or one TravelCut wrote.
        let existingTitle = altText(element: "title", ns: dcNS, in: descriptions)
        if existingTitle == nil || existingTitle!.isEmpty || existingTitle!.hasPrefix("组 ") {
            removeElements("title", ns: dcNS, in: descriptions)
            let alt = XMLElement(name: "rdf:Alt", uri: rdfNS)
            let item = XMLElement(name: "rdf:li", uri: rdfNS)
            item.stringValue = fields.title
            item.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as! XMLNode)
            alt.addChild(item)
            let title = XMLElement(name: "dc:title", uri: dcNS)
            title.addChild(alt)
            description.addChild(title)
        }

        // Keywords: drop the ones TravelCut wrote last time, keep the user's, add the new ones.
        let flat = fields.keywords.compactMap(\.last)
        let hierarchical = fields.keywords.map { $0.joined(separator: "|") }
        let previousFlat = Set(previousKeywords.compactMap { $0.split(separator: "|").last.map(String.init) })
        updateBag("subject", ns: dcNS, prefix: "dc", remove: previousFlat, add: flat, on: description, all: descriptions)
        updateBag("hierarchicalSubject", ns: lrNS, prefix: "lr", remove: Set(previousKeywords),
                  add: hierarchical, on: description, all: descriptions)
        let stored = (try? JSONEncoder().encode(hierarchical)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        setAttribute("Keywords", prefix: "travelcut", ns: tcNS, value: stored, on: description, all: descriptions)

        var text = document.xmlString(options: [.nodePrettyPrint])
        if text.hasPrefix("<?xml"), let end = text.range(of: "?>") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try Data((text + "\n").utf8).write(to: sidecar, options: .atomic)
        return .written
    }

    // MARK: - XML helpers

    private static let template = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="TravelCut">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""/>
     </rdf:RDF>
    </x:xmpmeta>
    """

    /// A simple property, written either as an attribute or as a child element.
    private static func value(of name: String, ns: String, in descriptions: [XMLElement]) -> String? {
        for description in descriptions {
            if let attribute = description.attribute(forLocalName: name, uri: ns) { return attribute.stringValue }
            if let element = description.elements(forLocalName: name, uri: ns).first {
                return element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func altText(element name: String, ns: String, in descriptions: [XMLElement]) -> String? {
        for description in descriptions {
            if let element = description.elements(forLocalName: name, uri: ns).first {
                return element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func ensureNamespace(_ prefix: String, _ uri: String, on element: XMLElement) {
        if element.resolveNamespace(forName: "\(prefix):x")?.stringValue == uri { return }
        element.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
    }

    private static func setAttribute(
        _ name: String, prefix: String, ns: String, value: String,
        on target: XMLElement, all descriptions: [XMLElement]
    ) {
        for description in descriptions {
            // The prefix may differ from ours, so find the attribute by namespace first.
            let matching = (description.attributes ?? []).filter { $0.localName == name && $0.uri == ns }
            for attribute in matching {
                if let qualified = attribute.name { description.removeAttribute(forName: qualified) }
            }
            for element in description.elements(forLocalName: name, uri: ns) { element.detach() }
        }
        target.addAttribute(XMLNode.attribute(withName: "\(prefix):\(name)", uri: ns, stringValue: value) as! XMLNode)
    }

    private static func removeProperty(_ name: String, ns: String, in descriptions: [XMLElement]) {
        for description in descriptions {
            let matching = (description.attributes ?? []).filter { $0.localName == name && $0.uri == ns }
            for attribute in matching {
                if let qualified = attribute.name { description.removeAttribute(forName: qualified) }
            }
            for element in description.elements(forLocalName: name, uri: ns) { element.detach() }
        }
    }

    private static func removeElements(_ name: String, ns: String, in descriptions: [XMLElement]) {
        for description in descriptions {
            for element in description.elements(forLocalName: name, uri: ns) { element.detach() }
        }
    }

    private static func updateBag(
        _ name: String, ns: String, prefix: String, remove: Set<String>, add: [String],
        on target: XMLElement, all descriptions: [XMLElement]
    ) {
        var kept: [String] = []
        for description in descriptions {
            for element in description.elements(forLocalName: name, uri: ns) {
                let items = (element.children ?? [])
                    .compactMap { $0 as? XMLElement }
                    .flatMap { ($0.children ?? []).compactMap { $0 as? XMLElement } }
                    .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                kept += items.filter { !remove.contains($0) }
                element.detach()
            }
        }
        let values = kept + add.filter { !kept.contains($0) }
        guard !values.isEmpty else { return }
        let bag = XMLElement(name: "rdf:Bag", uri: rdfNS)
        for value in values {
            let item = XMLElement(name: "rdf:li", uri: rdfNS)
            item.stringValue = value
            bag.addChild(item)
        }
        let element = XMLElement(name: "\(prefix):\(name)", uri: ns)
        element.addChild(bag)
        target.addChild(element)
    }
}
