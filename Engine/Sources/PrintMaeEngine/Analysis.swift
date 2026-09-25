import Foundation
import CoreGraphics
import PDFKit

public struct NativePreflightAnalyser: PreflightAnalysing, Sendable {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func analyse(
        document: StagedDocument,
        profile: PrintProfile,
        target: PaperSpec
    ) async throws -> PreflightReport {
        guard let pdf = PDFDocument(url: document.url) else {
            throw AppError(.corruptPDF, retryable: false)
        }
        if pdf.isEncrypted {
            guard let password = document.unlockPassword else {
                throw AppError(.protectedPDF)
            }
            guard pdf.unlock(withPassword: password) else {
                throw AppError(.wrongPassword)
            }
        }
        guard pdf.pageCount > 0 else { throw AppError(.emptyPDF, retryable: false) }
        guard let cgDocument = CGPDFDocument(document.url as CFURL) else {
            throw AppError(.corruptPDF, retryable: false)
        }
        if cgDocument.isEncrypted {
            guard let password = document.unlockPassword else { throw AppError(.protectedPDF) }
            guard password.withCString({ cgDocument.unlockWithPassword($0) }) else {
                throw AppError(.wrongPassword)
            }
        }

        var pageAnalyses: [PageAnalysis] = []
        var unsafePages = IndexSet()
        for index in 0 ..< pdf.pageCount {
            guard let page = cgDocument.page(at: index + 1) else {
                throw AppError(.corruptPDF, retryable: false)
            }
            let media = page.getBoxRect(.mediaBox)
            let crop = page.getBoxRect(.cropBox)
            guard media.isFiniteAndPositive, crop.isFiniteAndPositive else {
                throw AppError(.corruptPDF, retryable: false)
            }
            let rotation = normalizedPDFRotation(page.rotationAngle)
            let contentBounds = PDFContentBoundsDetector.detect(page: page, cropBox: crop)
            let safe = try PrintGeometry.safeRectangle(
                paper: crop,
                profileInsets: profile.safeInsetMillimetres
            )
            if let contentBounds, !safe.contains(contentBounds) {
                unsafePages.insert(index)
            }
            pageAnalyses.append(
                PageAnalysis(
                    index: index,
                    mediaBox: RectPoints(media),
                    cropBox: RectPoints(crop),
                    rotationDegrees: rotation,
                    orientationPortrait: PrintGeometry.orientationPortrait(box: crop, rotationDegrees: rotation),
                    inferredPaper: PrintGeometry.inferredPaper(for: crop),
                    visibleContentBounds: contentBounds.map(RectPoints.init),
                    effectiveImageDPI: document.descriptor.effectiveImageDPIByPage[index]
                )
            )
        }

        var issues: [PreflightIssue] = []
        if document.descriptor.byteCount > profile.maxBytesPerFile {
            issues.append(issue(.byteLimitExceeded, .blocking, fix: .compress(CompressionPolicy())))
        }
        if pdf.pageCount > profile.maxPagesPerFile {
            issues.append(issue(
                .pageLimitExceeded,
                .blocking,
                fix: .split(maxPages: profile.maxPagesPerFile, maxBytes: profile.maxBytesPerFile)
            ))
        }
        if !profile.allowedPaper.contains(target) {
            issues.append(issue(.unsupportedPaper, .blocking, fix: .normalizePaper(.a4Portrait)))
        }

        let sizeKeys = Set(pageAnalyses.map { analysis in
            let rect = analysis.cropBox.cgRect
            return "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
        })
        if sizeKeys.count > 1 {
            issues.append(issue(
                .mixedPaperSizes,
                profile.requiresUniformPaperSize ? .blocking : .review,
                fix: .normalizePaper(target)
            ))
        }
        if Set(pageAnalyses.map(\.orientationPortrait)).count > 1 {
            issues.append(issue(.mixedOrientations, .review, fix: .normalizePaper(target)))
        }
        if !unsafePages.isEmpty {
            issues.append(issue(
                .contentOutsideSafeArea,
                .review,
                pages: unsafePages,
                fix: .fitInsideSafeArea(profile.safeInsetMillimetres)
            ))
        }
        let lowDPI = IndexSet(pageAnalyses.compactMap { analysis in
            guard let dpi = analysis.effectiveImageDPI, dpi < 150 else { return nil }
            return analysis.index
        })
        if !lowDPI.isEmpty {
            issues.append(issue(.lowImageResolution, .review, pages: lowDPI, fix: nil))
        }
        if hasInteractiveFeatures(pdf) {
            issues.append(issue(.flatteningRequired, .review, fix: .flattenForPrint))
        }

        let readiness: ReadinessLevel
        if issues.contains(where: { $0.severity == .blocking }) {
            readiness = .blocked
        } else if issues.contains(where: { $0.severity == .review }) {
            readiness = .review
        } else {
            readiness = .ready
        }
        return PreflightReport(
            profileID: profile.id,
            readiness: readiness,
            pageCount: pdf.pageCount,
            inputBytes: document.descriptor.byteCount,
            pages: pageAnalyses,
            issues: issues.sorted { $0.severity > $1.severity },
            analysedAt: now()
        )
    }

    private func normalizedPDFRotation(_ value: Int32) -> Int {
        PrintGeometry.normalizedQuarterTurns(Int(value) / 90) * 90
    }

    private func hasInteractiveFeatures(_ pdf: PDFDocument) -> Bool {
        if pdf.outlineRoot != nil { return true }
        return (0 ..< pdf.pageCount).contains { index in
            guard let page = pdf.page(at: index) else { return false }
            return !page.annotations.isEmpty
        }
    }

    private func issue(
        _ code: IssueCode,
        _ severity: IssueSeverity,
        pages: IndexSet? = nil,
        fix: FixAction?
    ) -> PreflightIssue {
        PreflightIssue(
            code: code,
            severity: severity,
            pages: pages.map(PageRange.init),
            titleKey: "issue.\(code.rawValue).title",
            consequenceKey: "issue.\(code.rawValue).consequence",
            suggestedFix: fix
        )
    }
}

enum PDFContentBoundsDetector {
    static func detect(page: CGPDFPage, cropBox: CGRect, maximumDimension: Int = 1024) -> CGRect? {
        let scale = min(
            1,
            CGFloat(maximumDimension) / max(cropBox.width, cropBox.height)
        )
        let width = max(1, Int((cropBox.width * scale).rounded(.up)))
        let height = max(1, Int((cropBox.height * scale).rounded(.up)))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let bitmapRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bitmapRect)
        let transform = page.getDrawingTransform(
            .cropBox,
            rect: bitmapRect,
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        context.drawPDFPage(page)

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * 4
                let nonWhite = pixels[offset] < 248 || pixels[offset + 1] < 248 || pixels[offset + 2] < 248
                if nonWhite {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: cropBox.minX + CGFloat(minX) / CGFloat(width) * cropBox.width,
            y: cropBox.minY + CGFloat(minY) / CGFloat(height) * cropBox.height,
            width: CGFloat(maxX - minX + 1) / CGFloat(width) * cropBox.width,
            height: CGFloat(maxY - minY + 1) / CGFloat(height) * cropBox.height
        )
    }
}
