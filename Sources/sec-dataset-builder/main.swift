import Foundation
import SECDatasetBuilderCore

@main
struct SECDatasetBuilderCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = args.first else {
            printUsage()
            return
        }

        do {
            switch subcommand {
            case "build":
                try runBuild(args: Array(args.dropFirst()))
            case "fetch":
                try await runFetch(args: Array(args.dropFirst()))
            case "--help", "-h", "help":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown subcommand: \(subcommand)\n".utf8))
                printUsage()
                Foundation.exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func logLine(_ message: String, since startTime: Date, taskLabel: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        let ms = Int((now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1000)
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: now)
        let stamp = String(
            format: "%02d:%02d:%02d.%03dZ | +%06.3fs | %@",
            comps.hour ?? 0,
            comps.minute ?? 0,
            comps.second ?? 0,
            ms,
            elapsed,
            taskLabel
        )
        let line = "[\(stamp)] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private static func runBuild(args: [String]) throws {
        let opts = parseOptions(args)
        guard let fromLocal = opts["--from-local"] else {
            throw NSError(
                domain: "SECDatasetBuilderCLI",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing --from-local <dir> argument."]
            )
        }
        let outDirPath = opts["--out-dir"] ?? "./out"
        let metadataURL = opts["--metadata"].map { URL(fileURLWithPath: $0) }
        let primaryCIK = opts["--primary-cik"] ?? "2148245"
        let peerCIK = opts["--peer-cik"] ?? "2143038"

        let compiler = DatasetCompiler()
        let result = try compiler.compileFromLocal(
            rootDirectory: URL(fileURLWithPath: fromLocal),
            metadataURL: metadataURL,
            primaryCIK: primaryCIK,
            peerCIK: peerCIK
        )

        let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let bundleURL = outDir.appendingPathComponent("canonical-sample-bundle.json")
        let bundleData = try encoder.encode(result.bundle)
        try bundleData.write(to: bundleURL, options: .atomic)

        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        let catalogURL = outDir.appendingPathComponent("sec-filings-catalog.json")
        let catalogData = try prettyEncoder.encode(result.catalog)
        try catalogData.write(to: catalogURL, options: .atomic)

        print("Built canonical-sample-bundle.json (\(bundleData.count) bytes, \(result.bundle.rootOrder.count) documents)")
        print("Built sec-filings-catalog.json (\(result.catalog.filingCount) filings)")
    }

    private static func runFetch(args: [String]) async throws {
        let startTime = Date()
        let env = ProcessInfo.processInfo.environment
        let opts = parseOptions(args)
        let query = opts["--query"] ?? env["SEC_QUERY"] ?? #"formType:"S-1" AND Acquisition"#
        let size = Int(opts["--size"] ?? env["SEC_SIZE"] ?? "50") ?? 50
        let concurrency = max(1, Int(opts["--concurrency"] ?? env["SEC_CONCURRENCY"] ?? "50") ?? 50)
        let skipExhibits = (opts["--skip-exhibits"] == "true" || args.contains("--skip-exhibits"))
        let includeExhibits = !skipExhibits
        let keepLocal = (opts["--keep-local"] == "true" || args.contains("--keep-local"))
        let outDirPath = opts["--out-dir"] ?? env["OUT_DIR"] ?? "./fetched"
        let gcsBucket = opts["--gcs-bucket"] ?? env["GCS_BUCKET"]
        let gcsPrefix = opts["--gcs-prefix"] ?? env["GCS_PREFIX"] ?? "sec-s1-50-sharded"

        let taskIndex = max(0, Int(env["CLOUD_RUN_TASK_INDEX"] ?? opts["--task-index"] ?? "0") ?? 0)
        let taskCount = max(1, Int(env["CLOUD_RUN_TASK_COUNT"] ?? opts["--task-count"] ?? "1") ?? 1)
        let taskLabel = "Task \(taskIndex + 1)/\(taskCount)"

        let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
        let writeLocalDisk = (gcsBucket == nil || gcsBucket?.isEmpty == true || keepLocal)
        if writeLocalDisk {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        }

        let secPool = LiveSECFetcher.makeSessionPool(size: 16, maxConnectionsPerHost: 32)
        let gcsPool = LiveSECFetcher.makeSessionPool(size: 16, maxConnectionsPerHost: 32)

        var gcsUploader: GCSDirectUploader? = nil
        if let bucket = gcsBucket, !bucket.isEmpty {
            let token = try await GCSDirectUploader.resolveAccessToken(session: gcsPool[0])
            gcsUploader = GCSDirectUploader(bucket: bucket, prefix: gcsPrefix, accessToken: token, sessionPool: gcsPool)
            logLine("Configured 16-session direct GCS streaming to gs://\(bucket)/\(gcsPrefix) (in-memory pipeline)", since: startTime, taskLabel: taskLabel)
        }

        let fetcher = try LiveSECFetcher(sessionPool: secPool)
        let box = try await fetcher.searchFilings(query: query, from: 0, size: size)

        // Partition filings across Cloud Run Job tasks
        let allFilings = Array(box.filings.enumerated())
        let assignedFilings = allFilings.filter { ($0.offset % taskCount) == taskIndex }

        logLine(
            "SEC-API returned \(box.filings.count) filings (total matching: \(box.total.value)); assigned \(assignedFilings.count) filings to \(taskLabel)",
            since: startTime,
            taskLabel: taskLabel
        )

        if taskIndex == 0 {
            let metaData = try JSONEncoder().encode(box)
            if writeLocalDisk {
                let metaURL = outDir.appendingPathComponent("sec-metadata.json")
                try metaData.write(to: metaURL, options: .atomic)
            }
            if let gcsUploader {
                try? await gcsUploader.upload(data: metaData, relativeObjectPath: "sec-metadata.json", contentType: "application/json", sessionIndex: 0)
            }
        }

        let downloadStart = Date()
        var completed = 0
        var totalExhibits = 0
        var totalBytes = 0
        let uploader = gcsUploader

        try await withThrowingTaskGroup(of: (Int, SECFilingMetadata, FilingTransferStats, TimeInterval).self) { group in
            var nextIdx = 0
            let initialCount = min(concurrency, assignedFilings.count)

            for _ in 0..<initialCount {
                let item = assignedFilings[nextIdx]
                nextIdx += 1
                group.addTask {
                    let filingStart = Date()
                    let stats = try await fetcher.downloadFilingTreeWithStats(
                        filing: item.element,
                        into: outDir,
                        includeExhibits: includeExhibits,
                        gcsUploader: uploader,
                        writeLocalDisk: writeLocalDisk,
                        workerIndex: item.offset * 4
                    )
                    return (item.offset + 1, item.element, stats, Date().timeIntervalSince(filingStart))
                }
            }

            while let (globalIdx, filing, stats, filingElapsed) = try await group.next() {
                completed += 1
                totalExhibits += stats.exhibitCount
                totalBytes += stats.totalBytes
                let mb = Double(stats.totalBytes) / (1024.0 * 1024.0)
                logLine(
                    String(
                        format: "[%d/%d] Fetched #%d %@ [%@] (%d exhibits, %.2f MB in %.2fs)",
                        completed,
                        assignedFilings.count,
                        globalIdx,
                        filing.companyName,
                        filing.accessionNo,
                        stats.exhibitCount,
                        mb,
                        filingElapsed
                    ),
                    since: startTime,
                    taskLabel: taskLabel
                )

                if nextIdx < assignedFilings.count {
                    let nextItem = assignedFilings[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        let filingStart = Date()
                        let stats = try await fetcher.downloadFilingTreeWithStats(
                            filing: nextItem.element,
                            into: outDir,
                            includeExhibits: includeExhibits,
                            gcsUploader: uploader,
                            writeLocalDisk: writeLocalDisk,
                            workerIndex: nextItem.offset * 4
                        )
                        return (nextItem.offset + 1, nextItem.element, stats, Date().timeIntervalSince(filingStart))
                    }
                }
            }
        }

        let downloadElapsed = Date().timeIntervalSince(downloadStart)
        let totalElapsed = Date().timeIntervalSince(startTime)
        let totalMB = Double(totalBytes) / (1024.0 * 1024.0)
        logLine(
            String(
                format: "COMPLETED %d/%d filings (%d exhibits, %.2f MB) in %.2fs (total with search: %.2fs)",
                completed,
                assignedFilings.count,
                totalExhibits,
                totalMB,
                downloadElapsed,
                totalElapsed
            ),
            since: startTime,
            taskLabel: taskLabel
        )
    }

    private static func parseOptions(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < args.count {
            let key = args[i]
            if key.hasPrefix("--"), i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                result[key] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private static func printUsage() {
        print("""
        sec-dataset-builder — Canonical SEC S-1 Dataset Compiler & Fetcher
        Commands:
          build --from-local <dir> [--metadata <sample-json.json>] [--out-dir <dir>] [--primary-cik <cik>] [--peer-cik <cik>]
          fetch --query <lucene-query> [--size <N>] [--out-dir <dir>] [--gcs-bucket <bucket>] [--gcs-prefix <prefix>]
        """)
    }
}
