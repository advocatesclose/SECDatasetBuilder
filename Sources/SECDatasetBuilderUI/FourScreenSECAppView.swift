#if canImport(SwiftUI) && canImport(WebKit)
import SwiftUI
import WebKit
import SECDatasetBuilderCore

// MARK: - Root Entry Point (Screen 1 -> Screen 2 -> Screen 3 -> Screen 4)

public struct FourScreenSECAppView: View {
    @ObservedObject private var store: SECFilingsAppStore

    public init(store: SECFilingsAppStore = SECFilingsAppStore()) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            CompanySearchScreen(store: store)
        }
    }
}

// MARK: - SCREEN 1: Company Search Screen

public struct CompanySearchScreen: View {
    @ObservedObject var store: SECFilingsAppStore

    public init(store: SECFilingsAppStore) {
        self.store = store
    }

    public var body: some View {
        List {
            if store.isSearchingCompanies {
                HStack {
                    ProgressView()
                    Text("Searching SEC directory…")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Operating Companies") {
                ForEach(store.companies) { company in
                    NavigationLink(value: company) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(company.ticker.isEmpty ? "CIK \(company.unpaddedCIK)" : company.ticker)
                                    .font(.headline.weight(.bold))
                                Text(company.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                            }
                            Text(company.sicIndustry.isEmpty ? company.industry : company.sicIndustry)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(
            text: $store.searchText,
            prompt: "Search by company name or ticker (e.g., LLY)"
        )
        .onSubmit(of: .search) {
            Task {
                await store.performCompanySearch()
            }
        }
        .navigationDestination(for: SECCompanyProfile.self) { company in
            CompanyFilingsListScreen(company: company, store: store)
        }
    }
}

// MARK: - SCREEN 2: Company Filings List Screen (Matches Screenshot 1: LLY / ELI LILLY & Co / Registration Statements)

public struct CompanyFilingsListScreen: View {
    public let company: SECCompanyProfile
    @ObservedObject var store: SECFilingsAppStore

    public init(company: SECCompanyProfile, store: SECFilingsAppStore) {
        self.company = company
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header matching Screenshot 1 ("LLY", "ELI LILLY & Co", "Pharmaceutical Preparations")
                VStack(alignment: .leading, spacing: 8) {
                    Text(company.ticker.isEmpty ? company.tenDigitCIK : company.ticker)
                        .font(.system(size: 34, weight: .bold))

                    Text(company.name)
                        .font(.title2.weight(.bold))

                    Text(company.sicIndustry.isEmpty ? company.industry : company.sicIndustry)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Category selector + CompanyIdentificationFacts toggle
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(SECFormCategoryFilter.allCases) { category in
                                Button {
                                    store.selectedFormCategory = category
                                } label: {
                                    Text(category.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            store.selectedFormCategory == category
                                                ? Color.primary.opacity(0.14)
                                                : Color.secondary.opacity(0.08),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                store.showIdentificationFacts.toggle()
                            } label: {
                                Label("Company Facts", systemImage: "info.circle")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }

                    if store.showIdentificationFacts {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(company.companyIdentificationFacts) { fact in
                                HStack {
                                    Text(fact.key)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(fact.value)
                                        .font(.caption.monospaced())
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Divider()

                // Section Title + Rounded Filing Cards matching Screenshot 1
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(store.selectedFormCategory.rawValue)
                            .font(.headline.weight(.semibold))
                        Spacer()
                        if store.isLoadingFilings {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    ForEach(store.filteredFilings, id: \.accessionNo) { filing in
                        NavigationLink {
                            FilingWebReaderScreen(
                                company: company,
                                filing: filing,
                                store: store
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(filing.filingDateOnly)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    Text(filing.formCategoryTitle)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)

                                    Text("\(filing.formType) • Accession \(filing.accessionNo)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .background(
                                Color.secondary.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 24)
        }
        .task(id: company.id) {
            await store.loadFilings(for: company)
        }
    }
}

// MARK: - SCREEN 3: Filing WebView + Referenced Item 16 Exhibits Bar (Matches Screenshot 2)

public struct FilingWebReaderScreen: View {
    public let company: SECCompanyProfile
    public let filing: SECFilingMetadata
    @ObservedObject var store: SECFilingsAppStore

    public init(company: SECCompanyProfile, filing: SECFilingMetadata, store: SECFilingsAppStore) {
        self.company = company
        self.filing = filing
        self.store = store
    }

    private var currentURLString: String {
        if !store.activeDocumentURLString.isEmpty {
            return store.activeDocumentURLString
        }
        return HTMLClauseParser.canonicalSECEdgarURL(from: filing.linkToFilingDetails) ?? filing.linkToFilingDetails
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Referenced Item 16 Exhibits switcher (extracted directly from the registration statement HTML)
            if let pkg = store.activeFilingPackage, !pkg.referencedExhibits.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            store.activeDocumentURLString = pkg.canonicalFilingURL
                        } label: {
                            Text("\(filing.formType) Main")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    currentURLString == pkg.canonicalFilingURL
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.secondary.opacity(0.10),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)

                        ForEach(pkg.referencedExhibits) { ex in
                            Button {
                                store.activeDocumentURLString = ex.docURL
                            } label: {
                                Text(ex.exhibitNo.isEmpty ? ex.docName : "EX-\(ex.exhibitNo)")
                                    .font(.caption.monospaced())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        currentURLString == ex.docURL
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.secondary.opacity(0.10),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                Divider()
            }

            // Primary WebView rendering the SEC Filing or selected Item 16 Exhibit
            PlatformSECWebView(urlString: currentURLString)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Filing")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.isExportSheetPresented = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export Filing and Exhibits")
            }
        }
        .sheet(isPresented: $store.isExportSheetPresented) {
            FilingExportSheet(
                company: company,
                filing: filing,
                store: store
            )
            .presentationDetents([.medium, .large])
        }
        .task(id: filing.accessionNo) {
            await store.loadFilingExportPackage(company: company, filing: filing)
        }
    }
}

// MARK: - SCREEN 4: Export & Share Functionality (Matches & Upgrades Screenshot 3)

public struct FilingExportSheet: View {
    public let company: SECCompanyProfile
    public let filing: SECFilingMetadata
    @ObservedObject var store: SECFilingsAppStore

    public init(company: SECCompanyProfile, filing: SECFilingMetadata, store: SECFilingsAppStore) {
        self.company = company
        self.filing = filing
        self.store = store
    }

    private var exportJSONString: String {
        guard let pkg = store.activeFilingPackage else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pkg) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public var body: some View {
        NavigationStack {
            List {
                // Header card matching Screenshot 3 ("S-3ASR / sec.gov")
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title2)
                            .frame(width: 48, height: 48)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(filing.formType)
                                .font(.headline)
                            Text("sec.gov • \(company.name)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Accession \(filing.accessionNo)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Share & Export Actions
                Section("Share & Export") {
                    if let url = URL(string: filing.linkToFilingDetails) {
                        ShareLink(
                            item: url,
                            subject: Text("\(company.name) — \(filing.formType)"),
                            message: Text("SEC Filing \(filing.formType) (\(filing.filingDateOnly))")
                        ) {
                            Label("Share SEC.gov Filing Link", systemImage: "link")
                        }
                    }

                    ShareLink(
                        item: exportJSONString,
                        preview: SharePreview("\(company.ticker)-\(filing.formType)-\(filing.accessionNo).json")
                    ) {
                        Label(
                            "Export Filing + Item 16 Exhibits Manifest (.json)",
                            systemImage: "curlybraces.square"
                        )
                    }

                    Button {
                        Task {
                            await store.exportFullFilingTreeToDocuments(filing: filing)
                        }
                    } label: {
                        HStack {
                            Label(
                                "Download Complete Filing + Exhibit Tree",
                                systemImage: "arrow.down.doc.fill"
                            )
                            Spacer()
                            if store.isLoadingExportPackage {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }

                    if let exportedDir = store.lastExportedDirectoryURL {
                        Text("Saved to: \(exportedDir.path)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                // Deterministic SEC Archive Endpoints (<cik>/<accession>/index.json & headers)
                Section("Canonical SEC EDGAR Archive Endpoints") {
                    LabeledContent("Primary HTML", value: filing.linkToFilingDetails)
                        .font(.caption2.monospaced())
                    LabeledContent("Archive index.json", value: filing.archiveIndexJSONURL.absoluteString)
                        .font(.caption2.monospaced())
                    LabeledContent("Index Headers HTML", value: filing.archiveIndexHeadersHTMLURL.absoluteString)
                        .font(.caption2.monospaced())
                }

                // Referenced Item 16 Exhibits (Extracted from the HTML, beyond index.json)
                if let pkg = store.activeFilingPackage {
                    Section("Referenced Item 16 Exhibits (\(pkg.referencedExhibits.count))") {
                        if pkg.referencedExhibits.isEmpty {
                            Text(store.isLoadingExportPackage ? "Parsing filing HTML…" : "No external exhibit links found in primary HTML.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(pkg.referencedExhibits) { ex in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ex.exhibitNo.isEmpty ? ex.docName : "EX-\(ex.exhibitNo) — \(ex.docName)")
                                        .font(.caption.weight(.semibold))
                                    Text(ex.docURL)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Export Filing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        store.isExportSheetPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Cross-Platform WKWebView Wrapper (iOS & macOS)

#if os(iOS)
private struct PlatformSECWebView: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url = URL(string: urlString), webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#elseif os(macOS)
private struct PlatformSECWebView: NSViewRepresentable {
    let urlString: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url = URL(string: urlString), webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#endif

#endif
