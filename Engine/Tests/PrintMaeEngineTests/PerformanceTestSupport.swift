import Foundation
import CoreFoundation
import CoreGraphics
import PrintMaeEngine

enum PerformanceTestSupport {
    static func makeRasterPDF(at url: URL, pageCount: Int, pixelWidth: Int, seed: UInt64) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw AppError(.renderFailed)
        }

        var random = seed
        for pageIndex in 0 ..< pageCount {
            var pixels = [UInt8](repeating: 255, count: pixelWidth * pixelWidth * 4)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                pixels[offset] = UInt8(truncatingIfNeeded: random >> 32)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: random >> 40)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: random >> 48)
                pixels[offset + 3] = 255
            }
            let data = Data(pixels)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                    width: pixelWidth,
                    height: pixelWidth,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: pixelWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                  ) else {
                throw AppError(.renderFailed)
            }

            var mediaBox = pageRect
            let mediaBoxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: mediaBoxData] as CFDictionary)
            context.draw(image, in: pageRect)
            context.setFillColor(CGColor(red: 0.11, green: 0.18, blue: 0.38, alpha: 1))
            context.fill(CGRect(x: 42, y: 64 + CGFloat(pageIndex % 20), width: pageRect.width - 84, height: 16))
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func recursiveSize(_ directory: URL) throws -> Int64 {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        )
        return try files.reduce(Int64(0)) { total, url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { return total + Int64(values.fileSize ?? 0) }
            if values.isDirectory == true { return total + (try recursiveSize(url)) }
            return total
        }
    }

    static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }
}
