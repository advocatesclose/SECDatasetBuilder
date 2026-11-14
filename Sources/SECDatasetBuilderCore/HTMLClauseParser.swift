import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum HTMLClauseParser {
    /// 16 pre-trained logistic regression weights matching AppJavaadica's `LearnedClauseSegmenter`.
    public static let defaultPretrainedWeights: [Double] = [
        -2.11970,  2.60026, -0.66379,  0.33981, -0.33113, -0.39880, -1.09092,  1.83357,
        -1.46693,  1.05025,  0.91436,  1.08254,  0.46311, -1.79861,  1.57045, -4.71171
    ]

    public struct ParsedHTMLDocument: Sendable {
        public let blocks: [CanonicalBlock]
        public let wordCount: Int
        public let sha256: String
    }

    // MARK: - Item 16 Exhibit Index Extraction

    public static func extractItem16Attachments(from html: String, relativeTo filingURL: URL?) -> [SECAttachment] {
        let cleaned = stripSECHeaderAndHiddenIX(html)
        #if !os(Linux)
        if cleaned.utf8.count <= 250_000,
           let doc = try? XMLDocument(xmlString: cleaned, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) {
            let baseHref = (try? doc.nodes(forXPath: "(//*[local-name()='base'][@href])[1]/@href"))?.first?.stringValue
            let baseURL = baseHref.flatMap { href in
                filingURL.flatMap { URL(string: href, relativeTo: $0)?.absoluteURL } ?? URL(string: href)
            } ?? filingURL

            var seenFiles: Set<String> = []
            var results: [SECAttachment] = []

            if let rows = try? doc.nodes(forXPath: "//*[local-name()='tr']") {
                for case let row as XMLElement in rows {
                    guard let links = try? row.nodes(forXPath: ".//*[local-name()='a'][@href]"),
                          let firstLink = links.first as? XMLElement,
                          let href = firstLink.attribute(forName: "href")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !href.isEmpty,
                          !href.hasPrefix("#") else {
                        continue
                    }

                    let resolvedURL: URL? = baseURL.flatMap { URL(string: href, relativeTo: $0)?.absoluteURL } ?? URL(string: href)
                    guard let url = canonicalURL(resolvedURL) else { continue }
                    let fileKey = url.lastPathComponent.lowercased()
                    guard fileKey.hasSuffix(".htm") || fileKey.hasSuffix(".html") else { continue }
                    if let mainFile = filingURL?.lastPathComponent.lowercased(), fileKey == mainFile { continue }
                    if fileKey.contains("ex-fee") || fileKey.contains("exfee") { continue }

                    let cells = (try? row.nodes(forXPath: "./*[local-name()='td' or local-name()='th']")) ?? []
                    let cellTexts = cells.map { normalizeWhitespace($0.stringValue ?? "") }.filter { !$0.isEmpty }
                    let firstCell = cellTexts.first ?? ""
                    let exhibitNo = sanitizeExhibitNo(firstCell)
                    let linkText = normalizeWhitespace(firstLink.stringValue ?? "")
                    let combinedDesc = linkText.isEmpty ? (cellTexts.last ?? fileKey) : linkText

                    if combinedDesc.lowercased().contains("included in exhibit") { continue }
                    guard seenFiles.insert(fileKey).inserted else { continue }

                    let displayName = !exhibitNo.isEmpty ? "Ex. \(exhibitNo) — \(combinedDesc)" : combinedDesc
                    results.append(SECAttachment(exhibitNo: exhibitNo, docName: displayName, docURL: url.absoluteString))
                }
            }
            if !results.isEmpty {
                return results
            }
        }
        #endif
        return extractItem16AttachmentsFastRegex(from: cleaned, relativeTo: filingURL)
    }

    private static func extractItem16AttachmentsFastRegex(from cleaned: String, relativeTo filingURL: URL?) -> [SECAttachment] {
        guard let trRegex = try? NSRegularExpression(pattern: #"<tr\b[^>]*>(.*?)</tr>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let aRegex = try? NSRegularExpression(pattern: #"<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let tdRegex = try? NSRegularExpression(pattern: #"<t[dh]\b[^>]*>(.*?)</t[dh]>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let ns = cleaned as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var seenFiles: Set<String> = []
        var results: [SECAttachment] = []

        trRegex.enumerateMatches(in: cleaned, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            let rowStr = ns.substring(with: match.range(at: 1))
            guard rowStr.range(of: "href", options: .caseInsensitive) != nil else { return }
            let rowNS = rowStr as NSString
            let rowRange = NSRange(location: 0, length: rowNS.length)
            guard let linkMatch = aRegex.firstMatch(in: rowStr, options: [], range: rowRange) else { return }

            let href = rowNS.substring(with: linkMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !href.hasPrefix("#") else { return }

            let resolvedURL: URL? = filingURL.flatMap { URL(string: href, relativeTo: $0)?.absoluteURL } ?? URL(string: href)
            guard let url = canonicalURL(resolvedURL) else { return }
            let fileKey = url.lastPathComponent.lowercased()
            guard fileKey.hasSuffix(".htm") || fileKey.hasSuffix(".html") else { return }
            if let mainFile = filingURL?.lastPathComponent.lowercased(), fileKey == mainFile { return }
            if fileKey.contains("ex-fee") || fileKey.contains("exfee") { return }

            let tdMatches = tdRegex.matches(in: rowStr, options: [], range: rowRange)
            let cellTexts = tdMatches.map { normalizeWhitespace(stripTags(rowNS.substring(with: $0.range(at: 1)))) }.filter { !$0.isEmpty }
            let firstCell = cellTexts.first ?? ""
            let exhibitNo = sanitizeExhibitNo(firstCell)
            let linkText = normalizeWhitespace(stripTags(rowNS.substring(with: linkMatch.range(at: 2))))
            let combinedDesc = linkText.isEmpty ? (cellTexts.last ?? fileKey) : linkText

            if combinedDesc.lowercased().contains("included in exhibit") { return }
            guard seenFiles.insert(fileKey).inserted else { return }

            let displayName = !exhibitNo.isEmpty ? "Ex. \(exhibitNo) — \(combinedDesc)" : combinedDesc
            results.append(SECAttachment(exhibitNo: exhibitNo, docName: displayName, docURL: url.absoluteString))
        }

        aRegex.enumerateMatches(in: cleaned, options: [], range: fullRange) { linkMatch, _, _ in
            guard let linkMatch else { return }
            let href = ns.substring(with: linkMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !href.hasPrefix("#") else { return }
            let resolvedURL: URL? = filingURL.flatMap { URL(string: href, relativeTo: $0)?.absoluteURL } ?? URL(string: href)
            guard let url = canonicalURL(resolvedURL) else { return }
            let fileKey = url.lastPathComponent.lowercased()
            if let mainFile = filingURL?.lastPathComponent.lowercased(), fileKey == mainFile { return }
            if fileKey.contains("ex-fee") || fileKey.contains("exfee") { return }
            let linkText = normalizeWhitespace(stripTags(ns.substring(with: linkMatch.range(at: 2))))
            if linkText.lowercased().contains("included in exhibit") { return }
            guard seenFiles.insert(fileKey).inserted else { return }
            results.append(SECAttachment(exhibitNo: "", docName: linkText.isEmpty ? url.lastPathComponent : linkText, docURL: url.absoluteString))
        }
        return results
    }

    private static func sanitizeExhibitNo(_ raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil else {
            return ""
        }
        return trimmed
    }

    // MARK: - Block Parsing & Cleaning

    public static func parseBlocks(fromHTML html: String, maxBlocks: Int = 360) -> ParsedHTMLDocument {
        let cleaned = stripSECHeaderAndHiddenIX(html)
        let hash = sha256Hex(cleaned)

        guard let doc = try? XMLDocument(xmlString: cleaned, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement() else {
            let plain = normalizeWhitespace(stripTags(cleaned))
            let blocks = plain.isEmpty ? [] : [CanonicalBlock(t: "p", x: String(plain.prefix(4000)))]
            return ParsedHTMLDocument(blocks: blocks, wordCount: countWords(plain), sha256: hash)
        }

        var blocks: [CanonicalBlock] = []
        blocks.reserveCapacity(min(maxBlocks, 128))
        var seenAdjacentText: String = ""

        func collect(from element: XMLElement) {
            if blocks.count >= maxBlocks { return }
            let tag = (element.localName ?? element.name ?? "").lowercased()
            if ["script", "style", "noscript", "head", "title", "ix:header", "ix:hidden"].contains(tag) {
                return
            }

            if tag == "table" {
                if let tblBlock = makeTableBlock(from: element) {
                    if tblBlock.x != seenAdjacentText {
                        blocks.append(tblBlock)
                        seenAdjacentText = tblBlock.x
                    }
                }
                return
            }

            if ["h1", "h2", "h3", "h4", "p"].contains(tag) {
                // Skip container elements that wrap child tables directly; recurse instead.
                let hasNestedTable = element.elements(forName: "table").isEmpty == false
                if !hasNestedTable {
                    let txt = normalizeBlockText(element.stringValue ?? "")
                    if isUsefulText(txt), txt != seenAdjacentText {
                        let styleHint = styleFlags(for: element, fallbackText: txt)
                        let blockType = tag.hasPrefix("h") ? "h" : "p"
                        blocks.append(CanonicalBlock(t: blockType, x: txt, s: styleHint))
                        seenAdjacentText = txt
                    }
                    return
                }
            }

            if tag == "div" {
                let childElements = element.children?.compactMap { $0 as? XMLElement } ?? []
                let hasBlockChildren = childElements.contains { child in
                    let cname = (child.localName ?? child.name ?? "").lowercased()
                    return ["div", "p", "table", "h1", "h2", "h3", "h4", "ul", "ol"].contains(cname)
                }
                if !hasBlockChildren {
                    let txt = normalizeBlockText(element.stringValue ?? "")
                    if isUsefulText(txt), txt != seenAdjacentText {
                        let styleHint = styleFlags(for: element, fallbackText: txt)
                        blocks.append(CanonicalBlock(t: "p", x: txt, s: styleHint))
                        seenAdjacentText = txt
                    }
                    return
                }
            }

            for child in element.children ?? [] {
                if blocks.count >= maxBlocks { break }
                if let childEl = child as? XMLElement {
                    collect(from: childEl)
                }
            }
        }

        let bodyNode = (try? doc.nodes(forXPath: "//*[local-name()='body']"))?.first as? XMLElement ?? root
        collect(from: bodyNode)

        let totalWords = blocks.reduce(0) { $0 + countWords($1.x) }
        return ParsedHTMLDocument(blocks: blocks, wordCount: totalWords, sha256: hash)
    }

    private static func makeTableBlock(from table: XMLElement) -> CanonicalBlock? {
        guard let trNodes = try? table.nodes(forXPath: ".//*[local-name()='tr']"), !trNodes.isEmpty else {
            return nil
        }

        var rowSummaries: [String] = []
        var htmlRows: [String] = []
        let maxRows = min(trNodes.count, 32)

        for idx in 0..<maxRows {
            guard let tr = trNodes[idx] as? XMLElement else { continue }
            let cells = (try? tr.nodes(forXPath: "./*[local-name()='td' or local-name()='th']")) ?? []
            var cellTexts: [String] = []
            var cellHTMLs: [String] = []

            for case let cell as XMLElement in cells {
                let txt = normalizeWhitespace(cell.stringValue ?? "")
                if !txt.isEmpty {
                    cellTexts.append(txt)
                }
                var attrs = ""
                if let colspan = cell.attribute(forName: "colspan")?.stringValue {
                    attrs += " colspan=\"\(escapeHTMLAttr(colspan))\""
                }
                if let rowspan = cell.attribute(forName: "rowspan")?.stringValue {
                    attrs += " rowspan=\"\(escapeHTMLAttr(rowspan))\""
                }
                let style = cell.attribute(forName: "style")?.stringValue?.lowercased() ?? ""
                var classes: [String] = []
                if style.contains("border-bottom") { classes.append("bb") }
                if style.contains("font-weight: bold") || style.contains("font-weight:bold") {
                    classes.append("b")
                }
                if !classes.isEmpty {
                    attrs += " class=\"\(classes.joined(separator: " "))\""
                }
                cellHTMLs.append("<td\(attrs)>\(escapeHTMLBody(txt))</td>")
            }

            if !cellTexts.isEmpty {
                rowSummaries.append(cellTexts.joined(separator: " | "))
                htmlRows.append("<tr>\(cellHTMLs.joined())</tr>")
            }
        }

        guard !rowSummaries.isEmpty else { return nil }
        let summary = "[TABLE]\n" + rowSummaries.joined(separator: "\n")
        let cleanHTML = "<table class=\"rw-sec-table\"><tbody>\(htmlRows.joined())</tbody></table>"
        return CanonicalBlock(t: "tbl", x: summary, h: cleanHTML)
    }

    // MARK: - S-1 Main Prospectus Splitter

    public struct ProspectusSectionSpec: Sendable {
        public let slug: String
        public let title: String
        public let badge: String
        public let category: String
        public let anchorPatterns: [String]
    }

    public static let s1SectionSpecs: [ProspectusSectionSpec] = [
        .init(slug: "s1-cover", title: "Form S-1 Registration Statement", badge: "S-1", category: "Form S-1 Registration Statement", anchorPatterns: ["FORM S-1"]),
        .init(slug: "s1-summary", title: "Prospectus Summary & The Offering", badge: "S-1", category: "Prospectus", anchorPatterns: ["PROSPECTUS SUMMARY"]),
        .init(slug: "s1-risk-factors", title: "Risk Factors", badge: "S-1", category: "Prospectus", anchorPatterns: ["RISK FACTORS"]),
        .init(slug: "s1-use-of-proceeds", title: "Use of Proceeds & Dilution", badge: "S-1", category: "Financial & Terms", anchorPatterns: ["USE OF PROCEEDS"]),
        .init(slug: "s1-business", title: "Proposed Business & Management", badge: "S-1", category: "Business & Governance", anchorPatterns: ["PROPOSED BUSINESS"]),
        .init(slug: "s1-underwriting", title: "Underwriting & Plan of Distribution", badge: "S-1", category: "Offering Mechanics", anchorPatterns: ["UNDERWRITING"]),
        .init(slug: "s1-part-ii", title: "Part II — Item 16 Exhibits & Undertakings", badge: "S-1", category: "Part II", anchorPatterns: ["PART II", "INFORMATION NOT REQUIRED IN PROSPECTUS"])
    ]

    public static func splitProspectusSections(fromBlocks blocks: [CanonicalBlock]) -> [(spec: ProspectusSectionSpec, blocks: [CanonicalBlock])] {
        guard !blocks.isEmpty else { return [] }

        var boundaries: [(spec: ProspectusSectionSpec, startIndex: Int)] = [
            (s1SectionSpecs[0], 0)
        ]

        // Locate clean heading/title blocks matching subsequent section anchors after the TOC.
        let tocSkip = min(15, blocks.count / 10)
        for spec in s1SectionSpecs.dropFirst() {
            let minSearchIdx = max(tocSkip, (boundaries.last?.startIndex ?? 0) + 2)
            guard minSearchIdx < blocks.count else { continue }
            for idx in minSearchIdx..<blocks.count {
                let text = blocks[idx].x.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count <= 96 else { continue }
                let upper = text.uppercased()
                if spec.anchorPatterns.contains(where: { upper == $0 || upper.hasPrefix($0 + "\n") || upper.hasPrefix($0 + " ") }) {
                    boundaries.append((spec, idx))
                    break
                }
            }
        }

        var slices: [(spec: ProspectusSectionSpec, blocks: [CanonicalBlock])] = []
        for i in 0..<boundaries.count {
            let start = boundaries[i].startIndex
            let end = (i + 1 < boundaries.count) ? boundaries[i + 1].startIndex : blocks.count
            guard start < end else { continue }
            let clipped = Array(blocks[start..<min(end, start + 180)])
            if !clipped.isEmpty {
                slices.append((boundaries[i].spec, clipped))
            }
        }
        return slices
    }

    // MARK: - LearnedClauseSegmenter (16-Weight Model Parity)

    public static func extractStructuredClauses(
        fromBlocks blocks: [CanonicalBlock],
        category: String,
        docSlug: String,
        maxClauses: Int = 60
    ) -> [CanonicalClause] {
        var clauses: [CanonicalClause] = []
        clauses.reserveCapacity(min(maxClauses, blocks.count))

        var currentHeading = "Preamble"
        var currentRole = "preamble"
        var currentScore = 0.0
        var buffer: [String] = []
        let total = max(1, blocks.count)
        let statuses = ["Approved", "In Review", "Draft"]

        func flushClause() {
            let content = buffer.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll(keepingCapacity: true)
            guard !content.isEmpty, clauses.count < maxClauses else { return }

            let idx = clauses.count + 1
            let cleanSlug = makeSlug("\(docSlug)-\(idx)-\(currentHeading)")
            let statusVal = statuses[(idx - 1) % statuses.count]
            let materiality = ((currentScore * 100.0).rounded() / 100.0)
            let requiresConsent = content.lowercased().contains("consent")
                || content.lowercased().contains("waiv")
                || currentRole == "signature"

            let fields: [String: CanonicalFieldValue] = [
                "status": .string(statusVal),
                "category": .string(category),
                "section": .string(currentHeading),
                "materiality": .number(max(0.1, min(1.0, materiality))),
                "requiresConsent": .bool(requiresConsent)
            ]

            clauses.append(
                CanonicalClause(
                    index: idx,
                    slug: cleanSlug,
                    heading: currentHeading,
                    content: content,
                    role: currentRole,
                    score: currentScore,
                    fields: fields
                )
            )
        }

        for (i, block) in blocks.enumerated() {
            if clauses.count >= maxClauses { break }
            let text = block.x.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let (isBoundary, prob, role) = classifyBoundary(
                text: text,
                blockType: block.t,
                styleFlags: block.s ?? "",
                positionRatio: Double(i) / Double(total)
            )

            if (isBoundary || block.t == "h") && (!buffer.isEmpty || i > 0) {
                flushClause()
                currentHeading = conciseHeading(from: text, fallbackIndex: clauses.count + 1)
                currentRole = role
                currentScore = prob
                buffer.append(text)
            } else {
                if currentHeading == "Preamble" && (block.t == "h" || (block.s ?? "").contains("b")) && text.count <= 96 {
                    currentHeading = conciseHeading(from: text, fallbackIndex: clauses.count + 1)
                    currentRole = role
                    currentScore = prob
                }
                buffer.append(text)
            }
        }
        flushClause()
        return clauses
    }

    public static func classifyBoundary(
        text: String,
        blockType: String,
        styleFlags: String,
        positionRatio: Double
    ) -> (isBoundary: Bool, probability: Double, role: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wc = Double(countWords(trimmed))
        let isBold = styleFlags.contains("b") || blockType == "h" ? 1.0 : 0.0
        let isUpper = (trimmed == trimmed.uppercased() && trimmed.rangeOfCharacter(from: .letters) != nil) ? 1.0 : 0.0
        let isCentered = styleFlags.contains("c") ? 1.0 : 0.0
        let endsPeriod = trimmed.hasSuffix(".") ? 1.0 : 0.0
        let endsColon = trimmed.hasSuffix(":") ? 1.0 : 0.0
        let hasSectionNum = trimmed.range(of: #"^(?:Section|Article|SECTION|ARTICLE|Clause|Item|\d+(?:\.\d+)*\.?)\s+"#, options: .regularExpression) != nil ? 1.0 : 0.0
        let hasExhibit = trimmed.range(of: #"^(?:EXHIBIT|Exhibit|SCHEDULE|Schedule)\b"#, options: .regularExpression) != nil ? 1.0 : 0.0
        let hasSignature = trimmed.range(of: #"(?:IN WITNESS WHEREOF|ACKNOWLEDGED AND AGREED|Authorized Signature)"#, options: .regularExpression) != nil ? 1.0 : 0.0
        let isShort = wc <= 12 ? 1.0 : 0.0
        let isMediumShort = wc <= 24 ? 1.0 : 0.0
        let startsRecital = trimmed.range(of: #"^(?:WHEREAS|RECITALS?|NOW,\s*THEREFORE|WITNESSETH)\b"#, options: .regularExpression) != nil ? 1.0 : 0.0
        let isTable = blockType == "tbl" ? 1.0 : 0.0
        let lenNorm = min(1.0, Double(trimmed.count) / 400.0)
        let titleCaseRatio = computeTitleCaseRatio(trimmed)

        let features: [Double] = [
            1.0,
            hasSectionNum,
            isBold,
            isUpper,
            isCentered,
            endsPeriod,
            endsColon,
            isShort,
            isMediumShort,
            lenNorm,
            titleCaseRatio,
            hasExhibit,
            hasSignature,
            startsRecital,
            isTable,
            positionRatio
        ]

        var z = 0.0
        for (f, w) in zip(features, defaultPretrainedWeights) {
            z += f * w
        }
        let prob = 1.0 / (1.0 + exp(-max(-30.0, min(30.0, z))))

        let role: String
        if hasSignature > 0 { role = "signature" }
        else if startsRecital > 0 { role = "recital" }
        else if hasSectionNum > 0 || isBold > 0 && isShort > 0 { role = "heading" }
        else if isTable > 0 { role = "schedule" }
        else { role = "operative" }

        let boundary = prob >= 0.5 || hasSectionNum > 0 || (isBold > 0 && wc <= 18 && endsPeriod == 0)
        return (boundary, prob, role)
    }

    // MARK: - String & Cleanup Helpers

    public static func stripSECHeaderAndHiddenIX(_ raw: String) -> String {
        var s = raw
        if let range = s.range(of: "(?is)<sec-header>.*?</sec-header>", options: .regularExpression) {
            s.removeSubrange(range)
        }
        s = s.replacingOccurrences(of: "(?is)<ix:hidden>.*?</ix:hidden>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<ix:header>.*?</ix:header>", with: "", options: .regularExpression)
        return s
    }

    public static func canonicalExhibitFilename(_ rawFilename: String) -> String {
        rawFilename.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
    }

    public static func sha256Hex(_ text: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return pureSwiftSHA256Hex(Array(text.utf8))
        #endif
    }

    private static func pureSwiftSHA256Hex(_ bytes: [UInt8]) -> String {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        var msg = bytes
        let bitLen = UInt64(bytes.count) * 8
        msg.append(0x80)
        while (msg.count % 64) != 56 { msg.append(0x00) }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> UInt64(shift)) & 0xff))
        }
        func ror(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j+1]) << 16) | (UInt32(msg[j+2]) << 8) | UInt32(msg[j+3])
            }
            for i in 16..<64 {
                let s0 = ror(w[i-15], 7) ^ ror(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = ror(w[i-2], 17) ^ ror(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    public static func makeSlug(_ input: String) -> String {
        let lowered = input.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(lowered.prefix(56))
    }

    public static func countWords(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func styleFlags(for element: XMLElement, fallbackText: String) -> String? {
        var flags: [String] = []
        let style = element.attribute(forName: "style")?.stringValue?.lowercased() ?? ""
        if style.contains("text-align: center") || style.contains("text-align:center") {
            flags.append("c")
        } else if style.contains("text-align: right") || style.contains("text-align:right") {
            flags.append("r")
        }
        if style.contains("font-weight: bold") || style.contains("font-weight:bold")
            || !(try? element.nodes(forXPath: ".//*[local-name()='b' or local-name()='strong']"))!.isEmpty
            || (fallbackText == fallbackText.uppercased() && fallbackText.count < 110 && fallbackText.rangeOfCharacter(from: .letters) != nil) {
            flags.append("b")
        }
        if style.contains("font-style: italic") || style.contains("font-style:italic") {
            flags.append("i")
        }
        return flags.isEmpty ? nil : flags.joined(separator: ",")
    }

    private static func isUsefulText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // Filter page footers like "1", "F-12", "Page 3 of 18"
        if text.range(of: #"^(?:[FS]-)?\d{1,3}$"#, options: .regularExpression) != nil { return false }
        if text.range(of: #"^Page\s+\d+\s+of\s+\d+$"#, options: .regularExpression) != nil { return false }
        if text.range(of: #"^\[\s*Signature Page Follows\s*\]$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return text.count >= 2
    }

    private static func normalizeBlockText(_ raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines)
            .map { normalizeWhitespace($0) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    public static func normalizeWhitespace(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func conciseHeading(from text: String, fallbackIndex: Int) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        let trimmed = normalizeWhitespace(firstLine)
        if trimmed.count <= 84 { return trimmed }
        if let sentenceEnd = trimmed.prefix(84).lastIndex(of: ".") {
            let cut = String(trimmed[..<sentenceEnd])
            if cut.count >= 12 { return cut }
        }
        return "Clause \(fallbackIndex) — \(trimmed.prefix(64))…"
    }

    private static func computeTitleCaseRatio(_ text: String) -> Double {
        let words = text.split { $0.isWhitespace }
        guard !words.isEmpty else { return 0 }
        let caps = words.filter { $0.first?.isUppercase == true }.count
        return Double(caps) / Double(words.count)
    }

    public static func canonicalSECEdgarURL(from raw: String) -> String? {
        canonicalURL(URL(string: raw))?.absoluteString
    }

    private static func canonicalURL(_ url: URL?) -> URL? {
        guard let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              ["www.sec.gov", "sec.gov", "edgar-mirror.sec-api.io"].contains(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // Resolve dot segments before checking the archive prefix. Viewer links point to
        // the actual document via ?doc=; never download the /ix viewer itself.
        var path = normalizedPath(components.path)
        if ["/ix", "/ixviewer/doc/action", "/ixviewer/ix.html"].contains(path) {
            guard let document = components.queryItems?.first(where: { $0.name == "doc" })?.value,
                  document.hasPrefix("/Archives/edgar/data/") else { return nil }
            path = normalizedPath(document)
        }
        if host == "edgar-mirror.sec-api.io", !path.hasPrefix("/Archives/edgar/data/") {
            path = "/Archives/edgar/data" + path
        }
        guard path.hasPrefix("/Archives/edgar/data/") else { return nil }
        let parts = path.dropFirst("/Archives/edgar/data/".count).split(separator: "/")
        guard parts.count == 3,
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }),
              parts[2].contains(".") else { return nil }

        components.path = path
        components.scheme = "https"
        components.host = "www.sec.gov"
        components.port = nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func normalizedPath(_ path: String) -> String {
        var segments: [Substring] = []
        for segment in path.split(separator: "/") {
            if segment == ".." {
                if !segments.isEmpty { segments.removeLast() }
            } else if segment != "." {
                segments.append(segment)
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func escapeHTMLBody(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttr(_ text: String) -> String {
        escapeHTMLBody(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
