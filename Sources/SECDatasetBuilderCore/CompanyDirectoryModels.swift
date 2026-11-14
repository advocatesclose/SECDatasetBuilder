import Foundation

// MARK: - Company Identification & Directory Models (Decoupled Data Layer)

public struct SECCompanyIdentificationFact: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let key: String
    public let value: String
    public let indented: Bool

    public init(id: String, key: String, value: String, indented: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.indented = indented
    }
}

public struct SECCompanyProfile: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let ticker: String
    public let cik: String
    public let cusip: String
    public let exchange: String
    public let isDelisted: Bool?
    public let category: String
    public let sector: String
    public let industry: String
    public let sic: String
    public let sicSector: String
    public let sicIndustry: String
    public let famaSector: String
    public let famaIndustry: String
    public let currency: String
    public let location: String
    public let id: String

    public init(
        name: String,
        ticker: String,
        cik: String,
        cusip: String = "",
        exchange: String = "",
        isDelisted: Bool? = false,
        category: String = "",
        sector: String = "",
        industry: String = "",
        sic: String = "",
        sicSector: String = "",
        sicIndustry: String = "",
        famaSector: String = "",
        famaIndustry: String = "",
        currency: String = "USD",
        location: String = "",
        id: String? = nil
    ) {
        self.name = name
        self.ticker = ticker
        self.cik = cik.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        self.cusip = cusip
        self.exchange = exchange
        self.isDelisted = isDelisted
        self.category = category
        self.sector = sector
        self.industry = industry
        self.sic = sic
        self.sicSector = sicSector
        self.sicIndustry = sicIndustry
        self.famaSector = famaSector
        self.famaIndustry = famaIndustry
        self.currency = currency
        self.location = location
        self.id = id ?? "\(cik)-\(ticker)"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = (try? c.decode(String.self, forKey: .name)) ?? ""
        let rawTicker = (try? c.decode(String.self, forKey: .ticker)) ?? ""
        let rawCik = (try? c.decode(String.self, forKey: .cik)) ?? ""
        self.name = rawName
        self.ticker = rawTicker
        self.cik = rawCik.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        self.cusip = (try? c.decode(String.self, forKey: .cusip)) ?? ""
        self.exchange = (try? c.decode(String.self, forKey: .exchange)) ?? ""
        self.isDelisted = try? c.decode(Bool.self, forKey: .isDelisted)
        self.category = (try? c.decode(String.self, forKey: .category)) ?? ""
        self.sector = (try? c.decode(String.self, forKey: .sector)) ?? ""
        self.industry = (try? c.decode(String.self, forKey: .industry)) ?? ""
        self.sic = (try? c.decode(String.self, forKey: .sic)) ?? ""
        self.sicSector = (try? c.decode(String.self, forKey: .sicSector)) ?? ""
        self.sicIndustry = (try? c.decode(String.self, forKey: .sicIndustry)) ?? ""
        self.famaSector = (try? c.decode(String.self, forKey: .famaSector)) ?? ""
        self.famaIndustry = (try? c.decode(String.self, forKey: .famaIndustry)) ?? ""
        self.currency = (try? c.decode(String.self, forKey: .currency)) ?? "USD"
        self.location = (try? c.decode(String.self, forKey: .location)) ?? ""
        self.id = (try? c.decode(String.self, forKey: .id)) ?? "\(rawCik)-\(rawTicker)-\(rawName)"
    }

    /// Ten-digit zero-padded CIK used by `https://data.sec.gov/submissions/CIK{10-digit-cik}.json`
    public var tenDigitCIK: String {
        let digits = cik.filter(\.isNumber)
        return digits.count >= 10 ? digits : String(repeating: "0", count: 10 - digits.count) + digits
    }

    /// CIK stripped of leading zeros for `https://www.sec.gov/Archives/edgar/data/{cikWithoutLeadingZeros}/`
    public var unpaddedCIK: String {
        let stripped = cik.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        return stripped.isEmpty ? "0" : stripped
    }

    /// Structured key-value facts (from `TO_Z_MOOON_LA` / `CompanyIdentifications.swift`)
    public var companyIdentificationFacts: [SECCompanyIdentificationFact] {
        [
            SECCompanyIdentificationFact(id: "companyName", key: "Name", value: name),
            SECCompanyIdentificationFact(id: "ticker", key: "Ticker", value: ticker),
            SECCompanyIdentificationFact(id: "cik", key: "CIK", value: tenDigitCIK),
            SECCompanyIdentificationFact(id: "cusip", key: "CUSIP", value: cusip),
            SECCompanyIdentificationFact(id: "exchange", key: "Exchange", value: exchange),
            SECCompanyIdentificationFact(id: "sector", key: "Sector", value: sector),
            SECCompanyIdentificationFact(id: "industry", key: "Industry", value: industry),
            SECCompanyIdentificationFact(id: "sic", key: "SIC", value: sic),
            SECCompanyIdentificationFact(id: "sicIndustry", key: "SIC Industry", value: sicIndustry),
            SECCompanyIdentificationFact(id: "currency", key: "Currency", value: currency),
            SECCompanyIdentificationFact(id: "location", key: "Domicile", value: location)
        ].filter { !$0.value.isEmpty }
    }

    public static let eliLillySample = SECCompanyProfile(
        name: "ELI LILLY & Co",
        ticker: "LLY",
        cik: "59478",
        cusip: "532457108",
        exchange: "NYSE",
        isDelisted: false,
        category: "Domestic Common Stock",
        sector: "Healthcare",
        industry: "Drug Manufacturers - General",
        sic: "2834",
        sicSector: "Manufacturing",
        sicIndustry: "Pharmaceutical Preparations",
        famaSector: "Healthcare",
        famaIndustry: "Pharmaceutical Products",
        currency: "USD",
        location: "Indiana; U.S.A",
        id: "0000059478-LLY"
    )
}

// MARK: - SEC EDGAR Direct Submissions (`CIK{10-digit}.json`) & Archive `index.json` Models

/// Decodes `https://data.sec.gov/submissions/CIK{10-digit-cik}.json` (the SEC's `submissions.json` per-CIK file).
/// Because the SEC does not publish form-specific JSON files, `filings.recent` stores parallel columnar arrays
/// (`accessionNumber`, `filingDate`, `form`, `primaryDocument`), which we zip and filter by form prefix (e.g. `S-1`, `S-3ASR`, `10-K`).
public struct SECSubmissionsEnvelope: Codable, Sendable {
    public struct FilingsContainer: Codable, Sendable {
        public let recent: RecentParallelArrays
    }

    public struct RecentParallelArrays: Codable, Sendable {
        public let accessionNumber: [String]
        public let filingDate: [String]
        public let reportDate: [String]?
        public let form: [String]
        public let primaryDocument: [String]
        public let primaryDocDescription: [String]?
    }

    public let cik: String
    public let entityType: String?
    public let sic: String?
    public let sicDescription: String?
    public let name: String
    public let tickers: [String]?
    public let exchanges: [String]?
    public let stateOfIncorporation: String?
    public let filings: FilingsContainer

    /// Zips the columnar `filings.recent` arrays into `[SECFilingMetadata]` and constructs canonical `sec.gov/Archives/edgar/data/...` URLs.
    public func extractFilings(matchingFormPrefix prefix: String? = nil) -> [SECFilingMetadata] {
        let cleanCIK = cik.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        let primaryTicker = tickers?.first
        let recent = filings.recent
        let count = min(
            recent.accessionNumber.count,
            min(recent.filingDate.count, min(recent.form.count, recent.primaryDocument.count))
        )

        var results: [SECFilingMetadata] = []
        results.reserveCapacity(count)

        for i in 0..<count {
            let formType = recent.form[i]
            if let prefix, !prefix.isEmpty {
                if !formType.uppercased().hasPrefix(prefix.uppercased()) {
                    continue
                }
            }
            let accessionWithHyphens = recent.accessionNumber[i]
            let accessionNoHyphens = accessionWithHyphens.replacingOccurrences(of: "-", with: "")
            let primaryDoc = recent.primaryDocument[i]
            let filedAt = recent.filingDate[i]
            let desc = recent.primaryDocDescription?.indices.contains(i) == true
                ? recent.primaryDocDescription?[i]
                : formType

            // Canonical EDGAR URL rule:
            // https://www.sec.gov/Archives/edgar/data/<cik-without-leading-zeros>/<accession-without-hyphens>/<primaryDocument>
            let filingDetailsURL = "https://www.sec.gov/Archives/edgar/data/\(cleanCIK)/\(accessionNoHyphens)/\(primaryDoc)"
            let txtURL = "https://www.sec.gov/Archives/edgar/data/\(cleanCIK)/\(accessionNoHyphens)/\(accessionWithHyphens).txt"

            results.append(
                SECFilingMetadata(
                    ticker: primaryTicker,
                    formType: formType,
                    accessionNo: accessionWithHyphens,
                    cik: cleanCIK,
                    companyNameLong: name,
                    companyName: name,
                    linkToFilingDetails: filingDetailsURL,
                    description: desc,
                    linkToTxt: txtURL,
                    filedAt: filedAt,
                    documentFormatFiles: nil
                )
            )
        }
        return results
    }
}

/// Decodes `https://www.sec.gov/Archives/edgar/data/<cik-without-leading-zeros>/<accession-no-hyphens>/index.json`
public struct SECArchiveIndexDirectory: Codable, Hashable, Sendable {
    public struct Directory: Codable, Hashable, Sendable {
        public let item: [ArchiveItem]
        public let name: String
        public let parentDir: String?

        enum CodingKeys: String, CodingKey {
            case item
            case name
            case parentDir = "parent-dir"
        }
    }

    public struct ArchiveItem: Codable, Hashable, Identifiable, Sendable {
        public var id: String { name }
        public let lastModified: String?
        public let name: String
        public let size: String?
        public let type: String?

        enum CodingKeys: String, CodingKey {
            case lastModified = "last-modified"
            case name
            case size
            case type
        }
    }

    public let directory: Directory
}

// MARK: - Deterministic EDGAR Archive URL Builder & Export Package

public extension SECFilingMetadata {
    /// Unpadded CIK (`0000059478` -> `59478`)
    var unpaddedCIK: String {
        let stripped = cik.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        return stripped.isEmpty ? "0" : stripped
    }

    /// Accession number with hyphens removed (`0001193125-25-029600` -> `000119312525029600`)
    var accessionWithoutHyphens: String {
        accessionNo.replacingOccurrences(of: "-", with: "")
    }

    /// Base directory URL on `sec.gov/Archives/edgar/data/<cik>/<accession>/`
    var archiveBaseDirectoryURL: URL {
        URL(string: "https://www.sec.gov/Archives/edgar/data/\(unpaddedCIK)/\(accessionWithoutHyphens)/")!
    }

    /// Always-present `index.json` URL for this filing
    var archiveIndexJSONURL: URL {
        archiveBaseDirectoryURL.appendingPathComponent("index.json")
    }

    /// Always-present `index.html` URL for this filing
    var archiveIndexHTMLURL: URL {
        archiveBaseDirectoryURL.appendingPathComponent("index.html")
    }

    /// Always-present `<accession-with-hyphens>-index-headers.html` URL for this filing
    var archiveIndexHeadersHTMLURL: URL {
        archiveBaseDirectoryURL.appendingPathComponent("\(accessionNo)-index-headers.html")
    }

    /// Human-readable category matching the 4-screen iOS navigation
    var formCategoryTitle: String {
        let upper = formType.uppercased()
        if upper.hasPrefix("S-") || upper.hasPrefix("F-") || upper.hasPrefix("424") {
            return "Registration Statements"
        } else if upper.hasPrefix("10-K") || upper.hasPrefix("20-F") {
            return "Annual Reports"
        } else if upper.hasPrefix("10-Q") {
            return "Quarterly Reports"
        } else if upper.hasPrefix("8-K") || upper.hasPrefix("6-K") {
            return "Current Reports"
        }
        return formType
    }
}

/// Complete exportable package for Screen 3 & Screen 4:
/// Contains the filing metadata, canonical `sec.gov` URLs, the Item 16 Exhibits extracted directly from the filing's HTML
/// (as opposed to merely `index.json`), and the parsed `CanonicalClause` list.
public struct SECFilingExportPackage: Codable, Hashable, Sendable {
    public let company: SECCompanyProfile
    public let filing: SECFilingMetadata
    public let canonicalFilingURL: String
    public let archiveIndexJSONURL: String
    public let archiveHeadersHTMLURL: String
    public let referencedExhibits: [SECAttachment]
    public let archiveDirectoryFiles: [String]
    public let extractedClauses: [CanonicalClause]
    public let exportedAt: String

    public init(
        company: SECCompanyProfile,
        filing: SECFilingMetadata,
        canonicalFilingURL: String,
        archiveIndexJSONURL: String,
        archiveHeadersHTMLURL: String,
        referencedExhibits: [SECAttachment],
        archiveDirectoryFiles: [String],
        extractedClauses: [CanonicalClause],
        exportedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.company = company
        self.filing = filing
        self.canonicalFilingURL = canonicalFilingURL
        self.archiveIndexJSONURL = archiveIndexJSONURL
        self.archiveHeadersHTMLURL = archiveHeadersHTMLURL
        self.referencedExhibits = referencedExhibits
        self.archiveDirectoryFiles = archiveDirectoryFiles
        self.extractedClauses = extractedClauses
        self.exportedAt = exportedAt
    }
}
