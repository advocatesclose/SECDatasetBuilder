import Foundation

public struct DatasetBuildOutput: Sendable {
    public let bundle: CanonicalDealBundle
    public let catalog: SECFilingsCatalog
}

public enum DatasetCompilerError: LocalizedError {
    case directoryNotFound(String)
    case noFilingsFound(String)

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let p): return "Input directory not found: \(p)"
        case .noFilingsFound(let p): return "No CIK/accession SEC filings found under: \(p)"
        }
    }
}

public struct DatasetCompiler: Sendable {
    public init() {}

    public static let defaultRuntimeFields: [CanonicalRuntimeField] = [
        CanonicalRuntimeField(
            id: "status",
            name: "Status",
            type: .state,
            options: ["Draft", "In Review", "Approved"],
            defaultValue: .string("Draft")
        ),
        CanonicalRuntimeField(
            id: "category",
            name: "Category",
            type: .text,
            options: [],
            defaultValue: .string("General")
        ),
        CanonicalRuntimeField(
            id: "section",
            name: "Section",
            type: .text,
            options: [],
            defaultValue: .string("Preamble")
        ),
        CanonicalRuntimeField(
            id: "materiality",
            name: "MaterialityWeight",
            type: .number,
            options: [],
            defaultValue: .number(0.5)
        ),
        CanonicalRuntimeField(
            id: "requiresConsent",
            name: "RequiresConsent",
            type: .boolean,
            options: [],
            defaultValue: .bool(false)
        )
    ]

    public func compileFromLocal(
        rootDirectory: URL,
        metadataURL: URL?,
        primaryCIK: String = "2148245",
        peerCIK: String = "2143038"
    ) throws -> DatasetBuildOutput {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory.path) else {
            throw DatasetCompilerError.directoryNotFound(rootDirectory.path)
        }

        let metadataMap = loadMetadataLookup(from: metadataURL)
        let catalogEntries = try buildCatalogEntries(rootDirectory: rootDirectory, metadataMap: metadataMap)
        guard !catalogEntries.isEmpty else {
            throw DatasetCompilerError.noFilingsFound(rootDirectory.path)
        }

        let cikFilings = catalogEntries
            .filter { $0.cik == primaryCIK }
            .sorted { $0.filedAt > $1.filedAt }
        let latestPrimary = cikFilings.first ?? catalogEntries[0]
        let priorPrimaryFilings = Array(cikFilings.dropFirst())

        let primaryAccessionDir = rootDirectory
            .appendingPathComponent(latestPrimary.cik, isDirectory: true)
            .appendingPathComponent(latestPrimary.accessionNo, isDirectory: true)

        // Parse primary document.html -> Prospectus sections (folding prior filings as versions)
        let latestMainHTML = (try? String(
            contentsOf: primaryAccessionDir.appendingPathComponent("document.html"),
            encoding: .utf8
        )) ?? ""
        let latestParsedMain = HTMLClauseParser.parseBlocks(fromHTML: latestMainHTML, maxBlocks: 1600)
        let latestSections = HTMLClauseParser.splitProspectusSections(fromBlocks: latestParsedMain.blocks)

        // Parse prior filings' main document.html sections once so each S-1 section gets chronological versions
        var priorSectionsBySlug: [String: [CanonicalVersion]] = [:]
        for (priorIdx, prior) in priorPrimaryFilings.reversed().enumerated() {
            let pDir = rootDirectory
                .appendingPathComponent(prior.cik, isDirectory: true)
                .appendingPathComponent(prior.accessionNo, isDirectory: true)
            guard let priorHTML = try? String(
                contentsOf: pDir.appendingPathComponent("document.html"),
                encoding: .utf8
            ) else { continue }
            let parsed = HTMLClauseParser.parseBlocks(fromHTML: priorHTML, maxBlocks: 1600)
            for (spec, blocks) in HTMLClauseParser.splitProspectusSections(fromBlocks: parsed.blocks) {
                let ver = CanonicalVersion(
                    id: "\(prior.accessionNo).rtfd",
                    num: priorIdx + 1,
                    label: "\(prior.formType) (\(prior.filedAt.prefix(10)))",
                    createdAt: String(prior.filedAt.prefix(10)),
                    blocks: Array(blocks.prefix(140))
                )
                priorSectionsBySlug[spec.slug, default: []].append(ver)
            }
        }

        var docRecords: [CanonicalDocumentRecord] = []
        var usedTitles: Set<String> = []
        var usedEdgarFiles: Set<String> = []
        var usedHashes: Set<String> = []
        var nextDocId = 1

        var s1SectionCount = 0
        for sectionSlice in latestSections {
            let spec = sectionSlice.spec
            let trimmedBlocks = Array(sectionSlice.blocks.prefix(160))
            let sha = HTMLClauseParser.sha256Hex(trimmedBlocks.map(\.x).joined(separator: "\n"))
            guard usedTitles.insert(spec.title.lowercased()).inserted else { continue }
            usedHashes.insert(sha)

            var versions = priorSectionsBySlug[spec.slug] ?? []
            versions.append(
                CanonicalVersion(
                    id: "\(latestPrimary.accessionNo).rtfd",
                    num: versions.count + 1,
                    label: "\(latestPrimary.formType) Filed Baseline (\(latestPrimary.filedAt.prefix(10)))",
                    createdAt: String(latestPrimary.filedAt.prefix(10)),
                    blocks: trimmedBlocks
                )
            )
            // Keep most recent 2-3 versions cleanly ordered oldest -> newest
            let clauses = HTMLClauseParser.extractStructuredClauses(
                fromBlocks: trimmedBlocks,
                category: spec.category,
                docSlug: spec.slug
            )
            let wc = trimmedBlocks.reduce(0) { $0 + HTMLClauseParser.countWords($1.x) }

            docRecords.append(
                CanonicalDocumentRecord(
                    id: nextDocId,
                    slug: spec.slug,
                    title: spec.title,
                    badge: spec.badge,
                    category: spec.category,
                    edgarFile: "\(spec.slug).htm",
                    sha256: sha,
                    wordCount: wc,
                    focusedSeconds: max(300, min(3600, wc * 2)),
                    blocks: trimmedBlocks,
                    versions: versions,
                    clauses: clauses
                )
            )
            usedEdgarFiles.insert("\(spec.slug).htm")
            nextDocId += 1
            s1SectionCount += 1
        }

        // Parse primary Item 16 Exhibits from exhibits/ (strictly deduplicated by edgarFile + sha256 + title)
        let filingURL = URL(string: latestPrimary.linkToFilingDetails)
        let item16Index = HTMLClauseParser.extractItem16Attachments(from: latestMainHTML, relativeTo: filingURL)
        var attachmentMetaByFile: [String: SECAttachment] = [:]
        for item in item16Index {
            if let file = URL(string: item.docURL)?.lastPathComponent.lowercased() {
                attachmentMetaByFile[file] = item
            }
        }

        let exhibitsDir = primaryAccessionDir.appendingPathComponent("exhibits", isDirectory: true)
        let sortedExhibitFiles = orderedExhibitURLs(in: exhibitsDir)

        var exhibitCount = 0
        for fileURL in sortedExhibitFiles {
            let canonicalFile = HTMLClauseParser.canonicalExhibitFilename(fileURL.lastPathComponent)
            let lowerFile = canonicalFile.lowercased()
            if lowerFile.contains("ex-fee") || lowerFile.contains("exfee") { continue }
            guard usedEdgarFiles.insert(lowerFile).inserted else { continue }

            guard let rawHTML = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let parsed = HTMLClauseParser.parseBlocks(fromHTML: rawHTML, maxBlocks: 220)
            guard !parsed.blocks.isEmpty else { continue }
            guard usedHashes.insert(parsed.sha256).inserted else { continue }

            let meta = attachmentMetaByFile[lowerFile]
            let rawTitle = meta?.docName ?? inferExhibitTitle(fromFilename: canonicalFile)
            let uniqueTitle = deduplicateTitle(rawTitle, usedTitles: &usedTitles)
            let exhibitNo = meta?.exhibitNo.isEmpty == false
                ? meta!.exhibitNo
                : inferExhibitNumber(fromFilename: canonicalFile)
            let badge = exhibitNo.isEmpty ? "EX" : "EX-\(exhibitNo)"
            let category = categoryForExhibit(badge: badge, title: uniqueTitle)
            let slug = HTMLClauseParser.makeSlug(badge == "EX" ? canonicalFile : badge)

            // Collect prior accession versions of the exact same canonical edgarFile
            var versions: [CanonicalVersion] = []
            for prior in priorPrimaryFilings.reversed() {
                let pExhibitsDir = rootDirectory
                    .appendingPathComponent(prior.cik, isDirectory: true)
                    .appendingPathComponent(prior.accessionNo, isDirectory: true)
                    .appendingPathComponent("exhibits", isDirectory: true)
                if let priorFileURL = findExhibitFile(matchingCanonicalName: lowerFile, in: pExhibitsDir),
                   let pHTML = try? String(contentsOf: priorFileURL, encoding: .utf8) {
                    let pParsed = HTMLClauseParser.parseBlocks(fromHTML: pHTML, maxBlocks: 220)
                    if !pParsed.blocks.isEmpty && pParsed.sha256 != parsed.sha256 {
                        versions.append(
                            CanonicalVersion(
                                id: "\(prior.accessionNo)-\(slug).rtfd",
                                num: versions.count + 1,
                                label: "\(prior.formType) Prior Draft (\(prior.filedAt.prefix(10)))",
                                createdAt: String(prior.filedAt.prefix(10)),
                                blocks: pParsed.blocks
                            )
                        )
                    }
                }
            }
            versions.append(
                CanonicalVersion(
                    id: "\(latestPrimary.accessionNo)-\(slug).rtfd",
                    num: versions.count + 1,
                    label: "EDGAR \(badge) Filed Baseline (\(latestPrimary.filedAt.prefix(10)))",
                    createdAt: String(latestPrimary.filedAt.prefix(10)),
                    blocks: parsed.blocks
                )
            )

            let clauses = HTMLClauseParser.extractStructuredClauses(
                fromBlocks: parsed.blocks,
                category: category,
                docSlug: slug
            )

            docRecords.append(
                CanonicalDocumentRecord(
                    id: nextDocId,
                    slug: slug,
                    title: uniqueTitle,
                    badge: badge,
                    category: category,
                    edgarFile: canonicalFile,
                    sha256: parsed.sha256,
                    wordCount: parsed.wordCount,
                    focusedSeconds: max(240, min(2800, parsed.wordCount * 2)),
                    blocks: parsed.blocks,
                    versions: versions,
                    clauses: clauses
                )
            )
            nextDocId += 1
            exhibitCount += 1
        }

        // Add exactly one peer comparison precedent (Oceanhawk Acquisition II Corp Ex. 1.1) with unique title
        if let peerFiling = catalogEntries.first(where: { $0.cik == peerCIK }) {
            let peerExDir = rootDirectory
                .appendingPathComponent(peerFiling.cik, isDirectory: true)
                .appendingPathComponent(peerFiling.accessionNo, isDirectory: true)
                .appendingPathComponent("exhibits", isDirectory: true)
            if let peerFile = orderedExhibitURLs(in: peerExDir).first(where: {
                $0.lastPathComponent.lowercased().contains("ex1-1") || $0.lastPathComponent.lowercased().contains("ex1_1")
            }) ?? orderedExhibitURLs(in: peerExDir).first,
               let peerHTML = try? String(contentsOf: peerFile, encoding: .utf8) {
                let parsedPeer = HTMLClauseParser.parseBlocks(fromHTML: peerHTML, maxBlocks: 200)
                let peerCanonical = HTMLClauseParser.canonicalExhibitFilename(peerFile.lastPathComponent)
                let peerTitle = "Peer Ex. 1.1 — \(peerFiling.companyName)"
                if !parsedPeer.blocks.isEmpty && usedTitles.insert(peerTitle.lowercased()).inserted {
                    let clauses = HTMLClauseParser.extractStructuredClauses(
                        fromBlocks: parsedPeer.blocks,
                        category: "Peer Precedents",
                        docSlug: "peer-ex-1-1"
                    )
                    docRecords.append(
                        CanonicalDocumentRecord(
                            id: nextDocId,
                            slug: "peer-ex-1-1",
                            title: peerTitle,
                            badge: "PEER",
                            category: "Peer Precedents",
                            edgarFile: peerCanonical,
                            sha256: parsedPeer.sha256,
                            wordCount: parsedPeer.wordCount,
                            focusedSeconds: max(240, min(2400, parsedPeer.wordCount * 2)),
                            blocks: parsedPeer.blocks,
                            versions: [
                                CanonicalVersion(
                                    id: "\(peerFiling.accessionNo)-peer.rtfd",
                                    num: 1,
                                    label: "\(peerFiling.companyName) S-1 (\(peerFiling.filedAt.prefix(10)))",
                                    createdAt: String(peerFiling.filedAt.prefix(10)),
                                    blocks: parsedPeer.blocks
                                )
                            ],
                            clauses: clauses
                        )
                    )
                    nextDocId += 1
                    exhibitCount += 1
                }
            }
        }

        // Strict rootOrder deduplication and map construction
        var documentsDict: [String: CanonicalDocumentRecord] = [:]
        var rootOrder: [Int] = []
        var seenIds: Set<Int> = []
        for record in docRecords {
            guard seenIds.insert(record.id).inserted else { continue }
            rootOrder.append(record.id)
            documentsDict[String(record.id)] = record
        }

        func idForSlug(_ slug: String, fallback: Int) -> Int {
            docRecords.first(where: { $0.slug == slug })?.id ?? fallback
        }

        let firstId = rootOrder.first ?? 1
        let coverId = idForSlug("s1-cover", fallback: firstId)
        let summaryId = idForSlug("s1-summary", fallback: firstId)
        let riskId = idForSlug("s1-risk-factors", fallback: summaryId)
        let ex11Id = idForSlug("ex-1-1", fallback: riskId)
        let ex32Id = idForSlug("ex-3-2", fallback: ex11Id)

        let deal = CanonicalDealMetadata(
            name: "\(latestPrimary.companyName) — Form \(latestPrimary.formType)",
            bundleName: "NewIcelandArctic_S1A_\(latestPrimary.accessionNo).atlastext",
            cik: latestPrimary.cik.leftPadCIK(),
            accessionNumber: latestPrimary.accessionNo,
            filingDate: String(latestPrimary.filedAt.prefix(10)),
            secEdgarUrl: latestPrimary.linkToFilingDetails,
            issuerCounsel: "Hodgson Russ LLP · Walkers (Cayman) LLP",
            underwriter: "SEC EDGAR Sample Filing (\(latestPrimary.filedAt.prefix(10)))",
            documentCount: docRecords.count,
            s1SectionCount: s1SectionCount,
            exhibitCount: exhibitCount
        )

        let defaults = CanonicalDefaults(
            leftPaneDocId: riskId,
            rightPaneDocId: ex11Id,
            coverDocId: coverId,
            summaryDocId: summaryId,
            ex32DocId: ex32Id
        )

        let bundle = CanonicalDealBundle(
            deal: deal,
            rootOrder: rootOrder,
            defaults: defaults,
            runtimeFields: Self.defaultRuntimeFields,
            documents: documentsDict
        )

        let isoNow = ISO8601DateFormatter().string(from: Date())
        let catalog = SECFilingsCatalog(
            generatedAt: isoNow,
            source: "SECTESTFILE-3",
            primaryDealCik: latestPrimary.cik,
            primaryDealAccession: latestPrimary.accessionNo,
            filingCount: catalogEntries.count,
            filings: catalogEntries
        )

        return DatasetBuildOutput(bundle: bundle, catalog: catalog)
    }

    // MARK: - Helpers

    private func loadMetadataLookup(from url: URL?) -> [String: SECFilingMetadata] {
        guard let url, let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(SECQueryResponseBox.self, from: data) else {
            return [:]
        }
        var map: [String: SECFilingMetadata] = [:]
        for f in box.filings {
            map["\(f.cik)/\(f.accessionNo)"] = f
        }
        return map
    }

    private func buildCatalogEntries(
        rootDirectory: URL,
        metadataMap: [String: SECFilingMetadata]
    ) throws -> [SECFilingCatalogEntry] {
        let fm = FileManager.default
        let cikDirs = try fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [SECFilingCatalogEntry] = []
        for cikDir in cikDirs {
            let cik = cikDir.lastPathComponent
            guard cik.allSatisfy(\.isNumber) else { continue }
            let accDirs = (try? fm.contentsOfDirectory(
                at: cikDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for accDir in accDirs {
                let accession = accDir.lastPathComponent
                let docHTML = accDir.appendingPathComponent("document.html")
                guard fm.fileExists(atPath: docHTML.path) else { continue }

                let exhibitsDir = accDir.appendingPathComponent("exhibits", isDirectory: true)
                let exhibitFiles = orderedExhibitURLs(in: exhibitsDir).map(\.lastPathComponent)
                let meta = metadataMap["\(cik)/\(accession)"]

                entries.append(
                    SECFilingCatalogEntry(
                        cik: cik,
                        accessionNo: accession,
                        companyName: meta?.companyName ?? "CIK \(cik)",
                        ticker: meta?.ticker,
                        formType: meta?.formType ?? "S-1",
                        filedAt: meta?.filedAt ?? "2026-01-01",
                        exhibitCount: exhibitFiles.count,
                        linkToFilingDetails: meta?.linkToFilingDetails ?? "",
                        localExhibitFiles: exhibitFiles
                    )
                )
            }
        }
        return entries.sorted {
            if $0.filedAt != $1.filedAt { return $0.filedAt > $1.filedAt }
            return $0.accessionNo > $1.accessionNo
        }
    }

    private func orderedExhibitURLs(in exhibitsDir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: exhibitsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "htm" || ext == "html"
            }
            .sorted { a, b in
                let na = leadingOrderInt(a.lastPathComponent)
                let nb = leadingOrderInt(b.lastPathComponent)
                if na != nb { return na < nb }
                return a.lastPathComponent < b.lastPathComponent
            }
    }

    private func findExhibitFile(matchingCanonicalName lowerFile: String, in exhibitsDir: URL) -> URL? {
        orderedExhibitURLs(in: exhibitsDir).first {
            HTMLClauseParser.canonicalExhibitFilename($0.lastPathComponent).lowercased() == lowerFile
        }
    }

    private func leadingOrderInt(_ name: String) -> Int {
        guard let dash = name.firstIndex(of: "-"),
              let val = Int(name[..<dash]) else { return Int.max }
        return val
    }

    private func inferExhibitNumber(fromFilename name: String) -> String {
        guard let range = name.range(of: #"ex(\d+[-_]\d+|\d+)"#, options: [.regularExpression, .caseInsensitive]) else {
            return ""
        }
        let sub = name[range].dropFirst(2).replacingOccurrences(of: "-", with: ".").replacingOccurrences(of: "_", with: ".")
        return String(sub)
    }

    private func inferExhibitTitle(fromFilename name: String) -> String {
        let num = inferExhibitNumber(fromFilename: name)
        return num.isEmpty ? name : "Ex. \(num) — \(name)"
    }

    private func categoryForExhibit(badge: String, title: String) -> String {
        let b = badge.uppercased()
        let lower = title.lowercased()
        if b.contains("3.") || lower.contains("articles") || lower.contains("memorandum") { return "Constitutional" }
        if b.contains("4.") { return "Securities & Certificates" }
        if b.contains("5.") || lower.contains("opinion") { return "Legal Opinions" }
        if b.contains("1.") || b.contains("10.") { return "Material Contracts" }
        if b.contains("23.") || lower.contains("consent") { return "Consents" }
        if b.contains("14") || b.contains("99.") || lower.contains("charter") || lower.contains("ethics") {
            return "Governance & Policies"
        }
        return "Exhibits"
    }

    private func deduplicateTitle(_ raw: String, usedTitles: inout Set<String>) -> String {
        var candidate = HTMLClauseParser.normalizeWhitespace(raw)
        if candidate.isEmpty { candidate = "Untitled Exhibit" }
        if usedTitles.insert(candidate.lowercased()).inserted {
            return candidate
        }
        var n = 2
        while !usedTitles.insert("\(candidate) (\(n))".lowercased()).inserted {
            n += 1
        }
        return "\(candidate) (\(n))"
    }
}

private extension String {
    func leftPadCIK() -> String {
        count >= 10 ? self : String(repeating: "0", count: 10 - count) + self
    }
}
