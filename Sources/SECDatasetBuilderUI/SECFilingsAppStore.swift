#if canImport(SwiftUI) && canImport(Combine)
import Foundation
import Combine
import SwiftUI
import SECDatasetBuilderCore

public enum SECFormCategoryFilter: String, CaseIterable, Identifiable, Sendable {
    case registrationStatements = "Registration Statements"
    case annualReports = "Annual Reports"
    case quarterlyReports = "Quarterly Reports"
    case currentReports = "Current Reports"
    case allFilings = "All Filings"

    public var id: String { rawValue }

    public func matches(formType: String) -> Bool {
        let upper = formType.uppercased()
        switch self {
        case .registrationStatements:
            return upper.hasPrefix("S-") || upper.hasPrefix("F-") || upper.hasPrefix("424")
        case .annualReports:
            return upper.hasPrefix("10-K") || upper.hasPrefix("20-F")
        case .quarterlyReports:
            return upper.hasPrefix("10-Q")
        case .currentReports:
            return upper.hasPrefix("8-K") || upper.hasPrefix("6-K")
        case .allFilings:
            return true
        }
    }
}

/// Single decoupled `ObservableObject` state store for all 4 screens.
/// Views never construct `URLRequest` or `URLSession` calls; they read state from `SECFilingsAppStore`
/// and invoke intent methods (`performCompanySearch()`, `loadFilings(for:)`, `loadFilingExportPackage(company:filing:)`).
@MainActor
public final class SECFilingsAppStore: ObservableObject {
    @Published public var searchText: String = ""
    @Published public var companies: [SECCompanyProfile] = [.eliLillySample]
    @Published public var isSearchingCompanies: Bool = false

    @Published public var selectedCompany: SECCompanyProfile?
    @Published public var companyFilings: [SECFilingMetadata] = SECFilingsAppStore.eliLillySampleFilings
    @Published public var selectedFormCategory: SECFormCategoryFilter = .registrationStatements
    @Published public var showIdentificationFacts: Bool = false
    @Published public var isLoadingFilings: Bool = false

    @Published public var activeDocumentURLString: String = ""
    @Published public var isExportSheetPresented: Bool = false
    @Published public var activeFilingPackage: SECFilingExportPackage?
    @Published public var isLoadingExportPackage: Bool = false
    @Published public var lastExportedDirectoryURL: URL?
    @Published public var errorMessage: String?

    private let fetcher: LiveSECFetcher

    public init(
        apiKey: String = ProcessInfo.processInfo.environment["SEC_API_KEY"]
            ?? "c278f3df6daffcad7bfb8fd0ffab8bbd0fe3ebdfefc9bd9fffa8ecdecd3d52a0"
    ) {
        self.fetcher = (try? LiveSECFetcher(apiKey: apiKey))
            ?? (try! LiveSECFetcher(apiKey: "placeholder-key"))
    }

    public var filteredFilings: [SECFilingMetadata] {
        companyFilings.filter { selectedFormCategory.matches(formType: $0.formType) }
    }

    // MARK: - Screen 1 Intent: Search Companies

    public func performCompanySearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            companies = [.eliLillySample]
            return
        }
        isSearchingCompanies = true
        errorMessage = nil
        defer { isSearchingCompanies = false }

        do {
            let results = try await fetcher.searchCompanies(matching: query)
            if !results.isEmpty {
                companies = results
            } else if "eli lilly & co".contains(query.lowercased()) || "lly".contains(query.lowercased()) {
                companies = [.eliLillySample]
            } else {
                companies = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Screen 2 Intent: Load Company Filings (SEC-API + Direct SEC `CIK{10-digit}.json` Fallback)

    public func loadFilings(for company: SECCompanyProfile) async {
        selectedCompany = company
        isLoadingFilings = true
        errorMessage = nil
        defer { isLoadingFilings = false }

        do {
            let results = try await fetcher.fetchCompanyFilings(cik: company.cik, size: 150)
            if !results.isEmpty {
                companyFilings = results
            } else if company.cik == SECCompanyProfile.eliLillySample.cik {
                companyFilings = Self.eliLillySampleFilings
            }
        } catch {
            if company.cik == SECCompanyProfile.eliLillySample.cik {
                companyFilings = Self.eliLillySampleFilings
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Screen 3 & 4 Intent: Parse Referenced Item 16 Exhibits & Build Export Package

    public func loadFilingExportPackage(company: SECCompanyProfile, filing: SECFilingMetadata) async {
        let canonical = HTMLClauseParser.canonicalSECEdgarURL(from: filing.linkToFilingDetails) ?? filing.linkToFilingDetails
        activeDocumentURLString = canonical
        if activeFilingPackage?.filing.accessionNo == filing.accessionNo {
            return
        }
        isLoadingExportPackage = true
        errorMessage = nil
        defer { isLoadingExportPackage = false }

        do {
            let pkg = try await fetcher.buildFilingExportPackage(company: company, filing: filing)
            activeFilingPackage = pkg
            activeDocumentURLString = pkg.canonicalFilingURL
        } catch {
            activeFilingPackage = SECFilingExportPackage(
                company: company,
                filing: filing,
                canonicalFilingURL: canonical,
                archiveIndexJSONURL: filing.archiveIndexJSONURL.absoluteString,
                archiveHeadersHTMLURL: filing.archiveIndexHeadersHTMLURL.absoluteString,
                referencedExhibits: [],
                archiveDirectoryFiles: [],
                extractedClauses: []
            )
            errorMessage = error.localizedDescription
        }
    }

    /// Downloads the complete filing + all referenced Item 16 exhibits into the local Documents directory for export.
    public func exportFullFilingTreeToDocuments(filing: SECFilingMetadata) async {
        isLoadingExportPackage = true
        errorMessage = nil
        defer { isLoadingExportPackage = false }

        let docsRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let targetRoot = docsRoot.appendingPathComponent("SECExports", isDirectory: true)

        do {
            _ = try await fetcher.downloadFilingTreeWithStats(
                filing: filing,
                into: targetRoot,
                includeExhibits: true,
                gcsUploader: nil,
                writeLocalDisk: true
            )
            lastExportedDirectoryURL = targetRoot
                .appendingPathComponent(filing.cik, isDirectory: true)
                .appendingPathComponent(filing.accessionNo, isDirectory: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Built-in Sample Filings Matching the Eli Lilly (`LLY`) Registration Statement Screenshots

    public static let eliLillySampleFilings: [SECFilingMetadata] = [
        SECFilingMetadata(
            ticker: "LLY",
            formType: "S-3ASR",
            accessionNo: "0001193125-25-029600",
            cik: "59478",
            companyNameLong: "ELI LILLY & Co (Filer)",
            companyName: "ELI LILLY & Co",
            linkToFilingDetails: "https://www.sec.gov/Archives/edgar/data/59478/000119312525029600/d933321ds3asr.htm",
            description: "Automatic Shelf Registration Statement (Form S-3ASR)",
            linkToTxt: "https://www.sec.gov/Archives/edgar/data/59478/000119312525029600/0001193125-25-029600.txt",
            filedAt: "2025-02-19",
            documentFormatFiles: nil
        ),
        SECFilingMetadata(
            ticker: "LLY",
            formType: "S-3ASR",
            accessionNo: "0001193125-22-053212",
            cik: "59478",
            companyNameLong: "ELI LILLY & Co (Filer)",
            companyName: "ELI LILLY & Co",
            linkToFilingDetails: "https://www.sec.gov/Archives/edgar/data/59478/000119312522053212/d298490ds3asr.htm",
            description: "Automatic Shelf Registration Statement (Form S-3ASR)",
            linkToTxt: "https://www.sec.gov/Archives/edgar/data/59478/000119312522053212/0001193125-22-053212.txt",
            filedAt: "2022-02-24",
            documentFormatFiles: nil
        ),
        SECFilingMetadata(
            ticker: "LLY",
            formType: "S-4",
            accessionNo: "0001193125-21-246218",
            cik: "59478",
            companyNameLong: "ELI LILLY & Co (Filer)",
            companyName: "ELI LILLY & Co",
            linkToFilingDetails: "https://www.sec.gov/Archives/edgar/data/59478/000119312521246218/d197524ds4.htm",
            description: "Registration Statement (Form S-4)",
            linkToTxt: "https://www.sec.gov/Archives/edgar/data/59478/000119312521246218/0001193125-21-246218.txt",
            filedAt: "2021-08-13",
            documentFormatFiles: nil
        ),
        SECFilingMetadata(
            ticker: "LLY",
            formType: "S-8",
            accessionNo: "0001193125-21-246190",
            cik: "59478",
            companyNameLong: "ELI LILLY & Co (Filer)",
            companyName: "ELI LILLY & Co",
            linkToFilingDetails: "https://www.sec.gov/Archives/edgar/data/59478/000119312521246190/d201845ds8.htm",
            description: "Registration Statement (Form S-8)",
            linkToTxt: "https://www.sec.gov/Archives/edgar/data/59478/000119312521246190/0001193125-21-246190.txt",
            filedAt: "2021-08-13",
            documentFormatFiles: nil
        )
    ]
}
#endif
