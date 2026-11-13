import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

public struct FilingTransferStats: Sendable {
    public let directory: URL
    public let exhibitCount: Int
    public let totalBytes: Int
}

/// High-concurrency SEC filing search & EDGAR mirror fetcher with a multi-session pool to avoid Linux libcurl lock contention.
public struct LiveSECFetcher: Sendable {
    private let apiKey: String
    private let sessions: [URLSession]
    private let userAgent: String

    public static func makeHighThroughputSession(maxConnectionsPerHost: Int = 64) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    public static func makeSessionPool(size: Int = 16, maxConnectionsPerHost: Int = 32) -> [URLSession] {
        (0..<max(1, size)).map { _ in makeHighThroughputSession(maxConnectionsPerHost: maxConnectionsPerHost) }
    }

    public init(
        apiKey: String? = ProcessInfo.processInfo.environment["SEC_API_KEY"],
        session: URLSession = LiveSECFetcher.makeHighThroughputSession(),
        sessionPool: [URLSession]? = nil,
        userAgent: String = "RedlinerResearch/1.0 (dataset@redliner.app)"
    ) throws {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw LiveSECFetchError.missingAPIKey
        }
        self.apiKey = key
        if let pool = sessionPool, !pool.isEmpty {
            self.sessions = pool
        } else {
            self.sessions = [session]
        }
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

        let data = try await fetchWithRetry(request: request, sessionIndex: 0)
        return try JSONDecoder().decode(SECQueryResponseBox.self, from: data)
    }

    public func downloadEDGARMirror(documentURL: String, sessionIndex: Int = 0) async throws -> Data {
        let mirrored = try Self.mirrorURL(for: documentURL)
        var request = URLRequest(url: mirrored)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await fetchWithRetry(request: request, sessionIndex: sessionIndex)
    }

    public func downloadFilingTree(
        filing: SECFilingMetadata,
        into rootDirectory: URL,
        includeExhibits: Bool = true,
        gcsUploader: GCSDirectUploader? = nil
    ) async throws -> URL {
        let stats = try await downloadFilingTreeWithStats(
            filing: filing,
            into: rootDirectory,
            includeExhibits: includeExhibits,
            gcsUploader: gcsUploader,
            writeLocalDisk: gcsUploader == nil
        )
        return stats.directory
    }

    public func downloadFilingTreeWithStats(
        filing: SECFilingMetadata,
        into rootDirectory: URL,
        includeExhibits: Bool = true,
        gcsUploader: GCSDirectUploader? = nil,
        writeLocalDisk: Bool = false,
        workerIndex: Int = 0
    ) async throws -> FilingTransferStats {
        let accessionDir = rootDirectory
            .appendingPathComponent(filing.cik, isDirectory: true)
            .appendingPathComponent(filing.accessionNo, isDirectory: true)
        let exhibitsDir = accessionDir.appendingPathComponent("exhibits", isDirectory: true)
        if writeLocalDisk {
            try FileManager.default.createDirectory(at: exhibitsDir, withIntermediateDirectories: true)
        }

        let relPrefix = "\(filing.cik)/\(filing.accessionNo)"
        let linkData = filing.linkToFilingDetails.data(using: .utf8) ?? Data()
        if writeLocalDisk, !linkData.isEmpty {
            try? linkData.write(to: accessionDir.appendingPathComponent("link.txt"), options: .atomic)
        }

        // Download primary document.html immediately using worker's dedicated URLSession slot
        let mainData = try await downloadEDGARMirror(documentURL: filing.linkToFilingDetails, sessionIndex: workerIndex)
        if writeLocalDisk {
            let mainURL = accessionDir.appendingPathComponent("document.html")
            try mainData.write(to: mainURL, options: .atomic)
        }

        let attachments: [SECAttachment]
        if includeExhibits {
            let mainHTML = String(data: mainData, encoding: .utf8)
                ?? String(decoding: mainData, as: UTF8.self)
            let filingDetailURL = URL(string: filing.linkToFilingDetails)
            attachments = HTMLClauseParser.extractItem16Attachments(from: mainHTML, relativeTo: filingDetailURL)
        } else {
            attachments = []
        }

        // Overlap GCS upload of document.html & link.txt with parallel exhibit downloads + GCS uploads!
        let (exhibitCount, exhibitBytes) = await withTaskGroup(of: (Int, Int).self) { group in
            if let gcsUploader {
                if !linkData.isEmpty {
                    group.addTask {
                        try? await gcsUploader.upload(
                            data: linkData,
                            relativeObjectPath: "\(relPrefix)/link.txt",
                            contentType: "text/plain; charset=utf-8",
                            sessionIndex: workerIndex
                        )
                        return (0, 0)
                    }
                }
                group.addTask {
                    try? await gcsUploader.upload(
                        data: mainData,
                        relativeObjectPath: "\(relPrefix)/document.html",
                        contentType: "text/html; charset=utf-8",
                        sessionIndex: workerIndex + 1
                    )
                    return (0, 0)
                }
            }

            for (idx, attachment) in attachments.enumerated() {
                let slot = workerIndex &+ idx &+ 2
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let data = try await self.downloadEDGARMirror(documentURL: attachment.docURL, sessionIndex: slot)
                        guard let parsed = URL(string: attachment.docURL) else { return (0, 0) }
                        let safeName = parsed.lastPathComponent
                            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted)
                            .joined(separator: "_")
                        let targetName = "\(idx + 1)-\(safeName.isEmpty ? "exhibit.htm" : safeName)"
                        if writeLocalDisk {
                            try data.write(to: exhibitsDir.appendingPathComponent(targetName), options: .atomic)
                        }
                        if let gcsUploader {
                            try? await gcsUploader.upload(
                                data: data,
                                relativeObjectPath: "\(relPrefix)/exhibits/\(targetName)",
                                contentType: "text/html; charset=utf-8",
                                sessionIndex: slot
                            )
                        }
                        return (1, data.count)
                    } catch {
                        return (0, 0)
                    }
                }
            }

            var savedCount = 0
            var bytes = 0
            for await (c, b) in group {
                savedCount += c
                bytes += b
            }
            return (savedCount, bytes)
        }

        return FilingTransferStats(
            directory: accessionDir,
            exhibitCount: exhibitCount,
            totalBytes: mainData.count + linkData.count + exhibitBytes
        )
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

    private func fetchWithRetry(request: URLRequest, sessionIndex: Int = 0, maxAttempts: Int = 3) async throws -> Data {
        let activeSession = sessions[abs(sessionIndex) % sessions.count]
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await activeSession.data(for: request)
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

/// Streams downloaded files directly to a Google Cloud Storage bucket over GCP's internal network using a dedicated URLSession pool.
public struct GCSDirectUploader: Sendable {
    public let bucket: String
    public let prefix: String
    private let accessToken: String
    private let sessions: [URLSession]

    public init(
        bucket: String,
        prefix: String = "",
        accessToken: String,
        sessionPool: [URLSession] = LiveSECFetcher.makeSessionPool(size: 16, maxConnectionsPerHost: 32)
    ) {
        self.bucket = bucket
        self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.accessToken = accessToken
        self.sessions = sessionPool.isEmpty ? [LiveSECFetcher.makeHighThroughputSession()] : sessionPool
    }

    public static func resolveAccessToken(session: URLSession = .shared) async throws -> String {
        if let envToken = ProcessInfo.processInfo.environment["GCS_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envToken.isEmpty {
            return envToken
        }
        guard let url = URL(string: "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue("Google", forHTTPHeaderField: "Metadata-Flavor")
        req.timeoutInterval = 5
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
        struct TokenResponse: Decodable { let access_token: String }
        return try JSONDecoder().decode(TokenResponse.self, from: data).access_token
    }

    public func upload(data: Data, relativeObjectPath: String, contentType: String, sessionIndex: Int = 0) async throws {
        let cleanRel = relativeObjectPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullObjectName = prefix.isEmpty ? cleanRel : "\(prefix)/\(cleanRel)"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=/?#")
        guard let encodedName = fullObjectName.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://storage.googleapis.com/upload/storage/v1/b/\(bucket)/o?uploadType=media&name=\(encodedName)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let activeSession = sessions[abs(sessionIndex) % sessions.count]
        let (_, response) = try await activeSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.cannotWriteToFile)
        }
    }
}
