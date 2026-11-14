import Foundation

// MARK: - Runtime Keys / Schema

public enum CanonicalFieldType: String, Codable, Sendable, CaseIterable {
    case state
    case text
    case number
    case boolean
}

public struct CanonicalRuntimeField: Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var type: CanonicalFieldType
    public var options: [String]
    public var defaultValue: CanonicalFieldValue

    public init(
        id: String,
        name: String,
        type: CanonicalFieldType,
        options: [String] = [],
        defaultValue: CanonicalFieldValue
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.options = options
        self.defaultValue = defaultValue
    }
}

public enum CanonicalFieldValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .number(doubleVal)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        }
    }
}

// MARK: - Canonical Document & Clause Schema

public struct CanonicalBlock: Codable, Hashable, Sendable {
    public let t: String
    public let x: String
    public let s: String?
    public let h: String?

    public init(t: String, x: String, s: String? = nil, h: String? = nil) {
        self.t = t
        self.x = x
        self.s = s
        self.h = h
    }
}

public struct CanonicalVersion: Codable, Hashable, Sendable {
    public let id: String
    public let num: Int
    public let label: String
    public let createdAt: String
    public let blocks: [CanonicalBlock]

    public init(id: String, num: Int, label: String, createdAt: String, blocks: [CanonicalBlock]) {
        self.id = id
        self.num = num
        self.label = label
        self.createdAt = createdAt
        self.blocks = blocks
    }
}

public struct CanonicalClause: Codable, Hashable, Sendable {
    public let index: Int
    public let slug: String
    public let heading: String
    public let content: String
    public let role: String
    public let score: Double
    public var fields: [String: CanonicalFieldValue]

    public init(
        index: Int,
        slug: String,
        heading: String,
        content: String,
        role: String,
        score: Double,
        fields: [String: CanonicalFieldValue] = [:]
    ) {
        self.index = index
        self.slug = slug
        self.heading = heading
        self.content = content
        self.role = role
        self.score = score
        self.fields = fields
    }
}

public struct CanonicalDocumentRecord: Codable, Hashable, Sendable {
    public let id: Int
    public let slug: String
    public let title: String
    public let badge: String
    public let category: String
    public let edgarFile: String
    public let sha256: String
    public let wordCount: Int
    public let focusedSeconds: Int
    public let blocks: [CanonicalBlock]
    public let versions: [CanonicalVersion]
    public let clauses: [CanonicalClause]

    public init(
        id: Int,
        slug: String,
        title: String,
        badge: String,
        category: String,
        edgarFile: String,
        sha256: String,
        wordCount: Int,
        focusedSeconds: Int,
        blocks: [CanonicalBlock],
        versions: [CanonicalVersion],
        clauses: [CanonicalClause]
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.badge = badge
        self.category = category
        self.edgarFile = edgarFile
        self.sha256 = sha256
        self.wordCount = wordCount
        self.focusedSeconds = focusedSeconds
        self.blocks = blocks
        self.versions = versions
        self.clauses = clauses
    }
}

public struct CanonicalDealMetadata: Codable, Hashable, Sendable {
    public let name: String
    public let bundleName: String
    public let cik: String
    public let accessionNumber: String
    public let filingDate: String
    public let secEdgarUrl: String
    public let issuerCounsel: String
    public let underwriter: String
    public let documentCount: Int
    public let s1SectionCount: Int
    public let exhibitCount: Int

    public init(
        name: String,
        bundleName: String,
        cik: String,
        accessionNumber: String,
        filingDate: String,
        secEdgarUrl: String,
        issuerCounsel: String,
        underwriter: String,
        documentCount: Int,
        s1SectionCount: Int,
        exhibitCount: Int
    ) {
        self.name = name
        self.bundleName = bundleName
        self.cik = cik
        self.accessionNumber = accessionNumber
        self.filingDate = filingDate
        self.secEdgarUrl = secEdgarUrl
        self.issuerCounsel = issuerCounsel
        self.underwriter = underwriter
        self.documentCount = documentCount
        self.s1SectionCount = s1SectionCount
        self.exhibitCount = exhibitCount
    }
}

public struct CanonicalDefaults: Codable, Hashable, Sendable {
    public let leftPaneDocId: Int
    public let rightPaneDocId: Int
    public let coverDocId: Int
    public let summaryDocId: Int
    public let ex32DocId: Int

    public init(
        leftPaneDocId: Int,
        rightPaneDocId: Int,
        coverDocId: Int,
        summaryDocId: Int,
        ex32DocId: Int
    ) {
        self.leftPaneDocId = leftPaneDocId
        self.rightPaneDocId = rightPaneDocId
        self.coverDocId = coverDocId
        self.summaryDocId = summaryDocId
        self.ex32DocId = ex32DocId
    }
}

public struct CanonicalDealBundle: Codable, Sendable {
    public let deal: CanonicalDealMetadata
    public let rootOrder: [Int]
    public let defaults: CanonicalDefaults
    public let runtimeFields: [CanonicalRuntimeField]
    public let documents: [String: CanonicalDocumentRecord]

    public init(
        deal: CanonicalDealMetadata,
        rootOrder: [Int],
        defaults: CanonicalDefaults,
        runtimeFields: [CanonicalRuntimeField],
        documents: [String: CanonicalDocumentRecord]
    ) {
        self.deal = deal
        self.rootOrder = rootOrder
        self.defaults = defaults
        self.runtimeFields = runtimeFields
        self.documents = documents
    }
}

// MARK: - SEC Metadata & Catalog

public struct SECDocumentFormatFile: Codable, Hashable, Sendable {
    public let sequence: String?
    public let size: String?
    public let documentUrl: String?
    public let description: String?
    public let type: String?
}

public struct SECFilingMetadata: Codable, Hashable, Sendable {
    public let ticker: String?
    public let formType: String
    public let accessionNo: String
    public let cik: String
    public let companyNameLong: String?
    public let companyName: String
    public let linkToFilingDetails: String
    public let description: String?
    public let linkToTxt: String?
    public let filedAt: String
    public let documentFormatFiles: [SECDocumentFormatFile]?

    public init(
        ticker: String? = nil,
        formType: String,
        accessionNo: String,
        cik: String,
        companyNameLong: String? = nil,
        companyName: String,
        linkToFilingDetails: String,
        description: String? = nil,
        linkToTxt: String? = nil,
        filedAt: String,
        documentFormatFiles: [SECDocumentFormatFile]? = nil
    ) {
        self.ticker = ticker
        self.formType = formType
        self.accessionNo = accessionNo
        self.cik = cik
        self.companyNameLong = companyNameLong
        self.companyName = companyName
        self.linkToFilingDetails = linkToFilingDetails
        self.description = description
        self.linkToTxt = linkToTxt
        self.filedAt = filedAt
        self.documentFormatFiles = documentFormatFiles
    }

    public var filingDateOnly: String {
        String(filedAt.prefix(10))
    }
}

public struct SECQueryResponseBox: Codable, Sendable {
    public struct Total: Codable, Sendable {
        public let value: Int
        public let relation: String
    }

    public struct QueryInfo: Codable, Sendable {
        public let from: Int
        public let size: Int
    }

    public let total: Total
    public let query: QueryInfo
    public let filings: [SECFilingMetadata]
}

public struct SECAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: String { docURL }
    public let exhibitNo: String
    public let docName: String
    public let docURL: String

    public init(exhibitNo: String = "", docName: String, docURL: String) {
        self.exhibitNo = exhibitNo
        self.docName = docName
        self.docURL = docURL
    }
}

public struct SECFilingCatalogEntry: Codable, Hashable, Sendable {
    public let cik: String
    public let accessionNo: String
    public let companyName: String
    public let ticker: String?
    public let formType: String
    public let filedAt: String
    public let exhibitCount: Int
    public let linkToFilingDetails: String
    public let localExhibitFiles: [String]
}

public struct SECFilingsCatalog: Codable, Sendable {
    public let generatedAt: String
    public let source: String
    public let primaryDealCik: String
    public let primaryDealAccession: String
    public let filingCount: Int
    public let filings: [SECFilingCatalogEntry]
}
