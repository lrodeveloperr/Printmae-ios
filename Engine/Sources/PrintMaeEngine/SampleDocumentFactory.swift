import Foundation
import CoreGraphics

public enum SampleDocumentFactory {
    public static func makeA4PDF(at url: URL, pageCount: Int = 2) throws {
        guard pageCount > 0 else { throw AppError(.emptyPDF, retryable: false) }
        try makePDF(
            at: url,
            papers: Array(repeating: .a4Portrait, count: pageCount),
            contentTouchesEdge: false
        )
    }

    public static func makePDF(
        at url: URL,
        papers: [PaperSpec],
        contentTouchesEdge: Bool
    ) throws {
        guard !papers.isEmpty,
              let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw AppError(.renderFailed) }
        for (index, paper) in papers.enumerated() {
            let page = CGRect(origin: .zero, size: paper.points)
            let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: page]
            context.beginPDFPage(pageInfo as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(page)
            context.setFillColor(CGColor(red: 0.11, green: 0.18, blue: 0.38, alpha: 1))
            let edge = contentTouchesEdge ? 0.5 : 42
            context.fill(CGRect(x: edge, y: page.height - 100, width: page.width - edge * 2, height: 28))
            context.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
            context.setLineWidth(2)
            context.stroke(CGRect(x: 42, y: 64 + CGFloat(index * 2), width: page.width - 84, height: page.height - 190))
            context.endPDFPage()
        }
        context.closePDF()
    }
}
