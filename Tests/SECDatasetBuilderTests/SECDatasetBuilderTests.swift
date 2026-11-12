import Foundation
import Testing
@testable import SECDatasetBuilderCore

@Suite("SECDatasetBuilder Core Tests")
struct SECDatasetBuilderTests {

    @Test("Exhibit filename prefix stripping and Item 16 deduplication excludes ex-fee and duplicates")
    func deduplicateItem16AndStripPrefixes() {
        let html = """
        <html><body>
        <table>
          <tr><td>Exhibit No.</td><td>Description</td></tr>
          <tr><td>1.1**</td><td><a href="https://www.sec.gov/Archives/edgar/data/2148245/000118518526004748/newicelandex1-1.htm">Form of Underwriting Agreement</a></td></tr>
          <tr><td>5.1</td><td><a href="https://www.sec.gov/Archives/edgar/data/2148245/000118518526004748/newicelandex5-1.htm">Opinion of Hodgson Russ LLP</a></td></tr>
          <tr><td>23.2</td><td><a href="https://www.sec.gov/Archives/edgar/data/2148245/000118518526004748/newicelandex5-1.htm">Consent of Hodgson Russ LLP (included in Exhibit 5.1)</a></td></tr>
          <tr><td>107</td><td><a href="https://www.sec.gov/Archives/edgar/data/2148245/000118518526004748/newicelandex-fee.htm">Filing Fee Table</a></td></tr>
        </table>
        </body></html>
        """
        let baseURL = URL(string: "https://www.sec.gov/Archives/edgar/data/2148245/000118518526004748/newiceland.htm")
        let attachments = HTMLClauseParser.extractItem16Attachments(from: html, relativeTo: baseURL)

        #expect(attachments.count == 2)
        #expect(attachments.map(\.exhibitNo) == ["1.1", "5.1"])
        #expect(HTMLClauseParser.canonicalExhibitFilename("12-newicelandex10-1.htm") == "newicelandex10-1.htm")
    }

    @Test("Compiler folds chronological versions and emits zero duplicate titles or rootOrder IDs")
    func compilerFoldsVersionsAndDeduplicates() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let priorDir = tempRoot.appendingPathComponent("2148245/0001185185-26-004057/exhibits", isDirectory: true)
        let latestDir = tempRoot.appendingPathComponent("2148245/0001185185-26-004748/exhibits", isDirectory: true)
        let peerDir = tempRoot.appendingPathComponent("2143038/0001185185-26-004010/exhibits", isDirectory: true)
        try FileManager.default.createDirectory(at: priorDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: latestDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: peerDir, withIntermediateDirectories: true)

        let mainV1 = """
        <html><body>
        <p style="font-weight:bold">FORM S-1</p>
        <p>New Iceland Arctic Acquisition Corp.</p>
        <p style="font-weight:bold">RISK FACTORS</p>
        <p>Initial risk factor v1 disclosure.</p>
        </body></html>
        """
        let mainV2 = """
        <html><body>
        <p style="font-weight:bold">FORM S-1</p>
        <p>New Iceland Arctic Acquisition Corp.</p>
        <p style="font-weight:bold">RISK FACTORS</p>
        <p>Updated risk factor v2 disclosure with SEC comments addressed.</p>
        <table><tr><td>1.1</td><td><a href="http://www.sec.gov/Archives/edgar/data/2148245/000118518526004748/ex1-1.htm">Form of Underwriting Agreement</a></td></tr></table>
        </body></html>
        """

        try mainV1.write(to: priorDir.deletingLastPathComponent().appendingPathComponent("document.html"), atomically: true, encoding: .utf8)
        try mainV2.write(to: latestDir.deletingLastPathComponent().appendingPathComponent("document.html"), atomically: true, encoding: .utf8)
        try "<html><body><p>Prior Underwriting Agreement v1.</p></body></html>"
            .write(to: priorDir.appendingPathComponent("1-ex1-1.htm"), atomically: true, encoding: .utf8)
        try "<html><body><p><b>Section 1.</b> Updated Underwriting Agreement v2.</p></body></html>"
            .write(to: latestDir.appendingPathComponent("1-ex1-1.htm"), atomically: true, encoding: .utf8)
        try "<html><body><p>FILING FEE TABLE</p></body></html>"
            .write(to: latestDir.appendingPathComponent("2-ex-fee.htm"), atomically: true, encoding: .utf8)

        try "<html><body><p>Oceanhawk Acquisition II Corp.</p></body></html>"
            .write(to: peerDir.deletingLastPathComponent().appendingPathComponent("document.html"), atomically: true, encoding: .utf8)
        try "<html><body><p>Peer Underwriting Agreement.</p></body></html>"
            .write(to: peerDir.appendingPathComponent("1-oceanacq2ex1-1.htm"), atomically: true, encoding: .utf8)

        let output = try DatasetCompiler().compileFromLocal(rootDirectory: tempRoot, metadataURL: nil)
        let bundle = output.bundle

        #expect(Set(bundle.rootOrder).count == bundle.rootOrder.count)
        let titles = bundle.rootOrder.compactMap { bundle.documents[String($0)]?.title }
        #expect(Set(titles.map { $0.lowercased() }).count == titles.count)
        #expect(!titles.contains(where: { $0.lowercased().contains("fee") }))

        let ex11 = bundle.documents.values.first { $0.slug == "ex-1-1" }
        #expect(ex11 != nil)
        #expect(ex11?.versions.count == 2)
        #expect(!(ex11?.clauses.isEmpty ?? true))
        #expect(bundle.runtimeFields.first(where: { $0.id == "status" })?.options.count ?? 0 >= 2)
    }
}
