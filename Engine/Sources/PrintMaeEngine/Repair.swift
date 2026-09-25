import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct NativePDFRepairer: PrintRepairing, Sendable {
    public init() {}

    public func render(
        document: StagedDocument,
        recipe: EditRecipe,
        profile: PrintProfile,
        target: PaperSpec,
        destination: URL
    ) async throws -> RenderManifest {
        guard destination.standardizedFileURL != document.url.standardizedFileURL else {
            throw AppError(
                .renderFailed,
                localizationKey: "error.sourceOverwriteRefused",
                retryable: false
            )
        }
        guard let pdf = PDFDocument(url: document.url) else { throw AppError(.corruptPDF, retryable: false) }
        if pdf.isEncrypted {
            guard let password = document.unlockPassword, pdf.unlock(withPassword: password) else {
                throw AppError(.wrongPassword)
            }
        }
        guard pdf.pageCount > 0,
              let source = CGPDFDocument(document.url as CFURL)
        else { throw AppError(.emptyPDF, retryable: false) }
        if source.isEncrypted {
            guard let password = document.unlockPassword,
                  password.withCString({ source.unlockWithPassword($0) })
            else { throw AppError(.wrongPassword) }
        }

        let hasInteractiveFeatures = pdf.outlineRoot != nil ||
            (0 ..< pdf.pageCount).contains { !(pdf.page(at: $0)?.annotations.isEmpty ?? true) }
        let flattenApproved = recipe.actions.contains(.flattenForPrint)
        if hasInteractiveFeatures, !flattenApproved, recipe.actions.isEmpty {
            guard pdf.pageCount <= profile.maxPagesPerFile,
                  document.descriptor.byteCount <= profile.maxBytesPerFile else {
                throw AppError(.renderFailed, localizationKey: "error.flatteningApprovalRequired")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: document.url, to: destination)
            try SecureFileProtection.applyCompleteProtection(to: destination)
            let boxes = (0 ..< pdf.pageCount).compactMap { index in
                pdf.page(at: index).map { RectPoints($0.bounds(for: .mediaBox)) }
            }
            guard boxes.count == pdf.pageCount else { throw AppError(.renderFailed) }
            return RenderManifest(
                parts: [RenderedPart(
                    temporaryURL: destination,
                    pageIndexes: Array(0 ..< pdf.pageCount),
                    expectedPageBoxes: boxes,
                    sourceURL: document.url
                )],
                flattened: false,
                recipeRevision: recipe.revision
            )
        }
        guard !hasInteractiveFeatures || flattenApproved else {
            throw AppError(.renderFailed, localizationKey: "error.flatteningApprovalRequired")
        }

        let split = recipe.actions.reversed().compactMap { action -> (Int, Int64)? in
            if case .split(let maxPages, let maxBytes) = action { return (maxPages, maxBytes) }
            return nil
        }.first
        let compression = recipe.actions.reversed().compactMap { action -> CompressionPolicy? in
            if case .compress(let policy) = action { return policy }
            return nil
        }.first
        if let compression, !compression.isValid {
            throw AppError(.renderFailed, localizationKey: "error.invalidCompressionPolicy", retryable: false)
        }

        let maxPages = min(split?.0 ?? pdf.pageCount, profile.maxPagesPerFile)
        let maxBytes = min(split?.1 ?? profile.maxBytesPerFile, profile.maxBytesPerFile)
        guard maxPages > 0, maxBytes > 0 else {
            throw AppError(.renderFailed, retryable: false)
        }
        if split == nil, pdf.pageCount > profile.maxPagesPerFile {
            throw AppError(.renderFailed, localizationKey: "error.splitApprovalRequired")
        }

        var groups = stride(from: 0, to: pdf.pageCount, by: maxPages).map {
            Array($0 ..< min($0 + maxPages, pdf.pageCount))
        }
        var rendered: [(URL, [Int], [RectPoints])] = []
        var index = 0
        while index < groups.count {
            let group = groups[index]
            let trial = temporaryPartURL(base: destination, part: index, count: groups.count)
            let qualities: [Double?] = compression?.jpegQualitySteps.map(Optional.some) ?? [nil]
            var boxes: [RectPoints] = []
            var byteCount: Int64 = 0
            for quality in qualities {
                try? FileManager.default.removeItem(at: trial)
                boxes = try renderGroup(
                    source: source,
                    pdfKit: pdf,
                    pageIndexes: group,
                    recipe: recipe,
                    target: target,
                    flattenApproved: flattenApproved,
                    compression: compression,
                    compressionQuality: quality,
                    destination: trial
                )
                byteCount = try self.byteCount(at: trial)
                if byteCount <= maxBytes { break }
            }
            if byteCount > maxBytes, group.count > 1, split != nil {
                try? FileManager.default.removeItem(at: trial)
                let midpoint = group.count / 2
                groups.replaceSubrange(index ... index, with: [Array(group[..<midpoint]), Array(group[midpoint...])])
                continue
            }
            if byteCount > maxBytes {
                try? FileManager.default.removeItem(at: trial)
                throw AppError(.verificationFailed, localizationKey: "error.singlePageExceedsProfile")
            }
            rendered.append((trial, group, boxes))
            index += 1
        }

        if rendered.count > 1 {
            for itemIndex in rendered.indices {
                let desired = temporaryPartURL(base: destination, part: itemIndex, count: rendered.count)
                if rendered[itemIndex].0 != desired {
                    try? FileManager.default.removeItem(at: desired)
                    try FileManager.default.moveItem(at: rendered[itemIndex].0, to: desired)
                    rendered[itemIndex].0 = desired
                }
            }
        }

        return RenderManifest(
            parts: rendered.map { item in
                RenderedPart(
                    temporaryURL: item.0,
                    pageIndexes: item.1,
                    expectedPageBoxes: item.2,
                    sourceURL: document.url
                )
            },
            flattened: flattenApproved || compression != nil,
            recipeRevision: recipe.revision
        )
    }

    private func renderGroup(
        source: CGPDFDocument,
        pdfKit: PDFDocument,
        pageIndexes: [Int],
        recipe: EditRecipe,
        target: PaperSpec,
        flattenApproved: Bool,
        compression: CompressionPolicy?,
        compressionQuality: Double?,
        destination: URL
    ) throws -> [RectPoints] {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        guard let consumer = CGDataConsumer(url: destination as CFURL) else {
            throw AppError(.renderFailed)
        }
        let auxiliary: CFDictionary? = compression.map { _ in
            let values: [CFString: Any] = [
                kCGPDFContextCreator: "PrintMae",
                kCGPDFContextTitle: "印刷用PDF"
            ]
            return values as CFDictionary
        }
        guard let context = CGContext(consumer: consumer, mediaBox: nil, auxiliary) else {
            throw AppError(.renderFailed)
        }

        let normalizedPaper = recipe.actions.reversed().compactMap { action -> PaperSpec? in
            if case .normalizePaper(let paper) = action { return paper }
            return nil
        }.first
        let margins = recipe.actions.reversed().compactMap { action -> EdgeInsetsMM? in
            if case .addMargins(let insets) = action { return insets }
            return nil
        }.first ?? EdgeInsetsMM(top: 0, leading: 0, bottom: 0, trailing: 0)
        let fitInsets = recipe.actions.reversed().compactMap { action -> EdgeInsetsMM? in
            if case .fitInsideSafeArea(let insets) = action { return insets }
            return nil
        }.first

        var expected: [RectPoints] = []
        for sourceIndex in pageIndexes {
            guard let page = source.page(at: sourceIndex + 1) else { throw AppError(.corruptPDF) }
            let sourceBox = page.getBoxRect(.cropBox)
            let targetSize = normalizedPaper?.points ?? target.points
            let targetRect = CGRect(origin: .zero, size: targetSize)
            let contentRect = try PrintGeometry.safeRectangle(
                paper: targetRect,
                profileInsets: fitInsets ?? EdgeInsetsMM(top: 0, leading: 0, bottom: 0, trailing: 0),
                additionalMargins: margins
            )
            let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: targetRect]
            context.beginPDFPage(pageInfo as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(targetRect)

            let extraTurns = recipe.actions.reduce(0) { partial, action in
                guard case .rotate(let pages, let turns) = action, pages.contains(sourceIndex) else { return partial }
                return partial + turns
            }
            let rotation = PrintGeometry.normalizedQuarterTurns(extraTurns) * 90
            if let compression {
                guard let pdfPage = pdfKit.page(at: sourceIndex) else { throw AppError(.corruptPDF) }
                let image = try rasterize(
                    page: page,
                    pdfPage: pdfPage,
                    targetRect: targetRect,
                    contentRect: contentRect,
                    rotation: rotation,
                    dpi: compression.rasterDPI,
                    jpegQuality: compressionQuality ?? compression.jpegQualitySteps.last ?? 0.6
                )
                context.interpolationQuality = .high
                context.draw(image, in: targetRect)
            } else if flattenApproved {
                guard let pdfPage = pdfKit.page(at: sourceIndex) else { throw AppError(.corruptPDF) }
                let image = try rasterize(
                    page: page,
                    pdfPage: pdfPage,
                    targetRect: targetRect,
                    contentRect: contentRect,
                    rotation: rotation,
                    dpi: 300,
                    jpegQuality: 0.95
                )
                context.interpolationQuality = .high
                context.draw(image, in: targetRect)
            } else {
                context.saveGState()
                let transform = page.getDrawingTransform(
                    .cropBox,
                    rect: contentRect,
                    rotate: Int32(rotation),
                    preserveAspectRatio: true
                )
                context.concatenate(transform)
                context.drawPDFPage(page)
                context.restoreGState()
            }
            context.endPDFPage()
            expected.append(RectPoints(targetRect))
        }
        context.closePDF()
        try SecureFileProtection.applyCompleteProtection(to: destination)
        return expected
    }

    private func rasterize(
        page: CGPDFPage,
        pdfPage: PDFPage,
        targetRect: CGRect,
        contentRect: CGRect,
        rotation: Int,
        dpi: Double,
        jpegQuality: Double
    ) throws -> CGImage {
        let scale = dpi / 72.0
        let width = max(1, Int((targetRect.width * scale).rounded(.up)))
        let height = max(1, Int((targetRect.height * scale).rounded(.up)))
        guard width <= 10_000, height <= 10_000,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw AppError(.renderFailed) }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(targetRect)
        let transform = page.getDrawingTransform(
            .cropBox,
            rect: contentRect,
            rotate: Int32(rotation),
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        pdfPage.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw AppError(.renderFailed) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw AppError(.renderFailed) }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil),
              let compressed = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw AppError(.renderFailed) }
        return compressed
    }

    private func temporaryPartURL(base: URL, part: Int, count: Int) -> URL {
        guard count > 1 else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".partial", with: "")
        let suffix = String(format: "_part_%02d_of_%02d.partial.pdf", part + 1, count)
        return base.deletingLastPathComponent().appendingPathComponent(stem + suffix)
    }

    private func byteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}
