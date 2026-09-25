import Foundation
import CoreGraphics
import PDFKit

public struct NativeOutputVerifier: OutputVerifying, Sendable {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func verify(
        output: URL,
        expected: RenderedPart,
        profile: PrintProfile
    ) async throws -> VerificationReport {
        var checks: [VerificationCheck] = []
        func add(_ code: String, _ passed: Bool, _ detail: String) {
            checks.append(VerificationCheck(code: code, passed: passed, detail: detail))
        }

        let exists = FileManager.default.fileExists(atPath: output.path)
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        add("file.nonempty", exists && bytes > 0, "bytes=\(bytes)")
        add("path.notSource", output.standardizedFileURL != expected.sourceURL.standardizedFileURL, "distinct paths")

        guard exists,
              let cg = CGPDFDocument(output as CFURL),
              let pdfKit = PDFDocument(url: output)
        else {
            add("parser.cgpdf", false, "CGPDFDocument could not open output")
            add("parser.pdfkit", false, "PDFDocument could not open output")
            return VerificationReport(pass: false, checks: checks, verifiedAt: now())
        }
        add("parser.cgpdf", true, "opened")
        add("parser.pdfkit", true, "opened")
        add("encryption.none", !cg.isEncrypted && !pdfKit.isEncrypted, "output must be unencrypted")
        add(
            "pages.count",
            cg.numberOfPages == expected.pageIndexes.count && pdfKit.pageCount == expected.pageIndexes.count,
            "actual=\(cg.numberOfPages), expected=\(expected.pageIndexes.count)"
        )
        add("profile.bytes", bytes <= profile.maxBytesPerFile, "limit=\(profile.maxBytesPerFile)")
        add("profile.pages", cg.numberOfPages <= profile.maxPagesPerFile, "limit=\(profile.maxPagesPerFile)")

        var boxesPass = cg.numberOfPages == expected.expectedPageBoxes.count
        var actualBoxes: [CGRect] = []
        if boxesPass {
            for pageIndex in 0 ..< cg.numberOfPages {
                guard let page = cg.page(at: pageIndex + 1) else {
                    boxesPass = false
                    break
                }
                let actual = page.getBoxRect(.mediaBox)
                actualBoxes.append(actual)
                let target = expected.expectedPageBoxes[pageIndex].cgRect
                if !actual.isFiniteAndPositive ||
                    abs(actual.width - target.width) > 0.5 ||
                    abs(actual.height - target.height) > 0.5 {
                    boxesPass = false
                    break
                }
            }
        }
        add("pages.dimensions", boxesPass, "tolerance=0.5pt")
        let inferredPaper = actualBoxes.compactMap { PrintGeometry.inferredPaper(for: $0) }
        let supportedPaper = inferredPaper.count == actualBoxes.count &&
            inferredPaper.allSatisfy(profile.allowedPaper.contains)
        add("profile.paper", supportedPaper, "all pages must match an allowed A4/B5 target")
        let sizeKeys = Set(actualBoxes.map {
            "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))"
        })
        let uniform = !profile.requiresUniformPaperSize || sizeKeys.count <= 1
        add("profile.uniformPaper", uniform, "uniquePageSizes=\(sizeKeys.count)")

        let samples = sampleIndexes(pageCount: cg.numberOfPages)
        var rendersPass = true
        for pageIndex in samples {
            guard let page = cg.page(at: pageIndex + 1),
                  PDFContentBoundsDetector.detect(page: page, cropBox: page.getBoxRect(.cropBox)) != nil
            else {
                rendersPass = false
                break
            }
        }
        add("pages.sampleRender", rendersPass, "sampled=\(samples.map { $0 + 1 })")

        let pass = checks.allSatisfy(\.passed)
        return VerificationReport(pass: pass, checks: checks, verifiedAt: now())
    }

    private func sampleIndexes(pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        var values = Set([0, pageCount - 1])
        for index in stride(from: 9, to: pageCount, by: 10) { values.insert(index) }
        return values.sorted()
    }
}
