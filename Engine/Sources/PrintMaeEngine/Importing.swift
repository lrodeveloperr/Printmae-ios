import Foundation
import CoreGraphics
import CoreImage
import PDFKit
import UniformTypeIdentifiers

public actor LocalDocumentImporter: DocumentImporter {
    private let stagingRoot: URL
    private let fileManager: FileManager

    public init(stagingRoot: URL, fileManager: FileManager = .default) {
        self.stagingRoot = stagingRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    public func stage(_ sourceURL: URL) async throws -> StagedDocument {
        let type = UTType(filenameExtension: sourceURL.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            return try stagePDF(sourceURL)
        }
        if type?.conforms(to: .image) == true {
            return try await stageImages([sourceURL], target: .a4Portrait)
        }
        throw AppError(.unsupportedFormat, retryable: false)
    }

    public func stageImages(_ sourceURLs: [URL], target: PaperSpec) async throws -> StagedDocument {
        guard !sourceURLs.isEmpty else { throw AppError(.unsupportedFormat, retryable: false) }
        try createProtectedDirectory(stagingRoot)

        var images: [(CGImage, String)] = []
        for sourceURL in sourceURLs {
            let access = sourceURL.startAccessingSecurityScopedResource()
            defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
            guard let type = UTType(filenameExtension: sourceURL.pathExtension.lowercased()),
                  type.conforms(to: .image),
                  [UTType.jpeg, .png, .heic].contains(where: { type.conforms(to: $0) })
            else { throw AppError(.unsupportedFormat, retryable: false) }

            guard let ciImage = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
                throw AppError(.unsupportedFormat, retryable: false)
            }
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                throw AppError(.stagingFailed)
            }
            images.append((cgImage, sourceURL.lastPathComponent))
        }

        let id = UUID()
        let partial = stagingRoot.appendingPathComponent(".\(id.uuidString).partial.pdf")
        let final = stagingRoot.appendingPathComponent("\(id.uuidString).pdf")
        let paperRect = CGRect(origin: .zero, size: target.points)
        let safeRect = try PrintGeometry.safeRectangle(
            paper: paperRect,
            profileInsets: .conservative
        )
        let effectiveDPI = try ImagePDFBuilder.write(
            images: images.map(\.0),
            paperRect: paperRect,
            contentRect: safeRect,
            destination: partial
        )
        try AtomicFileMover.replaceItem(at: final, with: partial)
        try SecureFileProtection.applyCompleteProtection(to: final)

        let attributes = try fileManager.attributesOfItem(atPath: final.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let descriptor = SourceDescriptor(
            kind: .imagePDF,
            stagedRelativePath: final.lastPathComponent,
            originalDisplayName: sourceURLs.count == 1
                ? sourceURLs[0].lastPathComponent
                : "\(sourceURLs.count)_images.pdf",
            byteCount: bytes,
            sha256: try FileHash.sha256(of: final),
            effectiveImageDPIByPage: Dictionary(uniqueKeysWithValues: effectiveDPI.enumerated().map { ($0.offset, $0.element) })
        )
        return StagedDocument(descriptor: descriptor, url: final)
    }

    public func unlock(_ document: StagedDocument, password: String) async throws -> StagedDocument {
        guard document.descriptor.isEncrypted,
              let pdf = PDFDocument(url: document.url),
              pdf.isEncrypted else { return document }
        guard pdf.unlock(withPassword: password) else { throw AppError(.wrongPassword) }
        let partial = document.url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).unlocked.partial.pdf")
        guard pdf.write(to: partial),
              let proof = PDFDocument(url: partial),
              !proof.isEncrypted,
              proof.pageCount > 0 else {
            try? fileManager.removeItem(at: partial)
            throw AppError(.stagingFailed)
        }
        try AtomicFileMover.replaceItem(at: document.url, with: partial)
        try SecureFileProtection.applyCompleteProtection(to: document.url)
        let attributes = try fileManager.attributesOfItem(atPath: document.url.path)
        let descriptor = SourceDescriptor(
            kind: document.descriptor.kind,
            stagedRelativePath: document.descriptor.stagedRelativePath,
            originalDisplayName: document.descriptor.originalDisplayName,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            sha256: try FileHash.sha256(of: document.url),
            isEncrypted: false,
            effectiveImageDPIByPage: document.descriptor.effectiveImageDPIByPage
        )
        return StagedDocument(descriptor: descriptor, url: document.url)
    }

    private func stagePDF(_ sourceURL: URL) throws -> StagedDocument {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw AppError(.securityScopeDenied)
        }

        let originalHash = try FileHash.sha256(of: sourceURL)
        guard try hasPDFMagic(sourceURL) else {
            throw AppError(.unsupportedFormat, retryable: false)
        }
        try createProtectedDirectory(stagingRoot)
        let id = UUID()
        let partial = stagingRoot.appendingPathComponent(".\(id.uuidString).partial.pdf")
        let final = stagingRoot.appendingPathComponent("\(id.uuidString).pdf")

        do {
            try fileManager.copyItem(at: sourceURL, to: partial)
            guard try FileHash.sha256(of: partial) == originalHash,
                  try FileHash.sha256(of: sourceURL) == originalHash else {
                throw AppError(.stagingFailed, retryable: false)
            }
            try AtomicFileMover.replaceItem(at: final, with: partial)
            try SecureFileProtection.applyCompleteProtection(to: final)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw AppError.map(error)
        }

        let attributes = try fileManager.attributesOfItem(atPath: final.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let encrypted = CGPDFDocument(final as CFURL)?.isEncrypted ?? false
        return StagedDocument(
            descriptor: SourceDescriptor(
                kind: .pdf,
                stagedRelativePath: final.lastPathComponent,
                originalDisplayName: sourceURL.lastPathComponent,
                byteCount: bytes,
                sha256: originalHash,
                isEncrypted: encrypted
            ),
            url: final
        )
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try SecureFileProtection.applyCompleteProtection(to: url)
    }

    private func hasPDFMagic(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 5) ?? Data()
        return header == Data("%PDF-".utf8)
    }
}

public enum ImagePDFBuilder {
    @discardableResult
    public static func write(
        images: [CGImage],
        paperRect: CGRect,
        contentRect: CGRect,
        destination: URL
    ) throws -> [Double] {
        guard !images.isEmpty,
              let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw AppError(.renderFailed) }

        var effectiveDPI: [Double] = []
        for image in images {
            let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: paperRect]
            context.beginPDFPage(pageInfo as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(paperRect)
            let source = CGSize(width: image.width, height: image.height)
            let destinationRect = try PrintGeometry.centredAspectFitRect(source: source, destination: contentRect)
            context.interpolationQuality = .high
            context.draw(image, in: destinationRect)
            context.endPDFPage()
            let horizontalDPI = Double(image.width) / (destinationRect.width / 72.0)
            let verticalDPI = Double(image.height) / (destinationRect.height / 72.0)
            effectiveDPI.append(min(horizontalDPI, verticalDPI))
        }
        context.closePDF()
        return effectiveDPI
    }
}
