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
                fputs("Unknown subcommand: \(subcommand)\n", stderr)
                printUsage()
                Foundation.exit(2)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
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
        let opts = parseOptions(args)
        let query = opts["--query"] ?? #"formType:"S-1" AND Acquisition"#
        let size = Int(opts["--size"] ?? "50") ?? 50
        let outDirPath = opts["--out-dir"] ?? "./fetched"
        let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let fetcher = try LiveSECFetcher()
        let box = try await fetcher.searchFilings(query: query, from: 0, size: size)
        print("SEC-API returned \(box.filings.count) filings (total matching: \(box.total.value))")

        let metaData = try JSONEncoder().encode(box)
        let metaURL = outDir.appendingPathComponent("sec-metadata.json")
        try metaData.write(to: metaURL, options: .atomic)

        for filing in box.filings {
            let dir = try await fetcher.downloadFilingTree(filing: filing, into: outDir)
            print("Fetched \(filing.companyName) [\(filing.accessionNo)] -> \(dir.path)")
        }
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
          fetch --query <lucene-query> [--size <N>] [--out-dir <dir>]  (reads SEC_API_KEY env var)
        """)
    }
}
