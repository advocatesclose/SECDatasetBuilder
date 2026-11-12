import Foundation

public enum LiveSECFetchError: LocalizedError {
    case missingAPIKey
    case invalidURL(String)
    case httpStatus(Int, retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "SEC_API_KEY environment variable is required for live fetching."
        case .invalidURL(let raw):
            return "Invalid SEC/EDGAR URL: \(raw)"
        case .httpStatus(let code, _):
            return "SEC fetch failed with HTTP status \(code)."
        }
    }
}

/// Ports the MyTool SEC filing search & EDGAR mirror fetcher with strict env-var API key handling.
public actor LiveSECFetcher {
    private let apiKey: String
    private let session: URLSession
    private let userAgent: String

    public init(
        apiKey: String? = ProcessInfo.processInfo.environment["SEC_API_KEY"],
        session: URLSession = .shared,
        userAgent: String = "RedlinerResearch/1.0 (dataset@redliner.app)"
    ) throws {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw LiveSECFetchError.missingAPIKey
        }
        self.apiKey = key
        self.session = session
        self.userAgent = userAgent
    }

    public func searchFilings(
        query: String = #"formType:"S-1" AND Acquisition"#,
        from: Int = 0,
        size: Int = 50
    ) async throws -> SECQueryResponseBox {
        struct Payload: Encodable {
            struct FiledAtSort: Encodable { let order: String }
            struct SortItem: Encodable { let filedAt: FiledAtSort }
            let query: String
            let from: String
            let size: String
            let sort: [SortItem]
        }

        guard let endpoint = URL(string: "https://api.sec-api.io") else {
            throw LiveSECFetchError.invalidURL("https://api.sec-api.io")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let payload = Payload(
            query: query,
            from: String(from),
            size: String(size),
            sort: [.init(filedAt: .init(order: "desc"))]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await fetchWithRetry(request: request)
        return try JSONDecoder().decode(SECQueryResponseBox.self, from: data)
    }

    public func downloadEDGARMirror(documentURL: String) async throws -> Data {
        let mirrored = try Self.mirrorURL(for: documentURL)
        var request = URLRequest(url: mirrored)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await fetchWithRetry(request: request)
    }

    public func downloadFilingTree(filing: SECFilingMetadata, into rootDirectory: URL) async throws -> URL {
        let accessionDir = rootDirectory
            .appendingPathComponent(filing.cik, isDirectory: true)
            .appendingPathComponent(filing.accessionNo, isDirectory: true)
        let exhibitsDir = accessionDir.appendingPathComponent("exhibits", isDirectory: true)
        try FileManager.default.createDirectory(at: exhibitsDir, withIntermediateDirectories: true)

        let mainData = try await downloadEDGARMirror(documentURL: filing.linkToFilingDetails)
        let mainURL = accessionDir.appendingPathComponent("document.html")
        try mainData.write(to: mainURL, options: .atomic)

        let mainHTML = String(data: mainData, encoding: .utf8)
            ?? String(decoding: mainData, as: UTF8.self)
        let filingDetailURL = URL(string: filing.linkToFilingDetails)
        let attachments = HTMLClauseParser.extractItem16Attachments(from: mainHTML, relativeTo: filingDetailURL)

        for (idx, attachment) in attachments.enumerated() {
            do {
                try Task.checkCancellation()
                let data = try await downloadEDGARMirror(documentURL: attachment.docURL)
                guard let parsed = URL(string: attachment.docURL) else { continue }
                let safeName = parsed.lastPathComponent
                    .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted)
                    .joined(separator: "_")
                let targetName = "\(idx + 1)-\(safeName.isEmpty ? "exhibit.htm" : safeName)"
                try data.write(to: exhibitsDir.appendingPathComponent(targetName), options: .atomic)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Individual exhibit download failures must not abort the filing scrape.
                continue
            }
        }
        return accessionDir
    }

    public static func mirrorURL(for documentURL: String) throws -> URL {
        guard let sourceURL = URL(string: documentURL)?.standardized,
              let scheme = sourceURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = sourceURL.host?.lowercased(),
              host == "www.sec.gov" || host == "sec.gov",
              sourceURL.path.hasPrefix("/Archives/edgar/data/"),
              var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            throw LiveSECFetchError.invalidURL(documentURL)
        }
        components.scheme = "https"
        components.host = "edgar-mirror.sec-api.io"
        components.path = String(sourceURL.path.dropFirst("/Archives/edgar/data".count))
        components.port = nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw LiveSECFetchError.invalidURL(documentURL)
        }
        return url
    }

    private func fetchWithRetry(request: URLRequest, maxAttempts: Int = 3) async throws -> Data {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw LiveSECFetchError.httpStatus(http.statusCode, retryAfter: Self.retryDelay(from: http))
                }
                return data
            } catch {
                try Task.checkCancellation()
                var delay = Double(attempt)
                let shouldRetry: Bool
                if case LiveSECFetchError.httpStatus(let code, let retryAfter) = error {
                    shouldRetry = [408, 429, 500, 502, 503, 504].contains(code)
                    delay = max(delay, retryAfter ?? 0)
                } else if let urlErr = error as? URLError {
                    shouldRetry = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(urlErr.code)
                } else {
                    shouldRetry = false
                }
                guard shouldRetry, attempt < maxAttempts else { throw error }
                try await Task.sleep(for: .seconds(delay))
                attempt += 1
            }
        }
    }

    private static func retryDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return seconds }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return fmt.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
    }
}
