import Foundation
import CoreGraphics

public enum PrintGeometry {
    public static func safeRectangle(
        paper: CGRect,
        profileInsets: EdgeInsetsMM,
        additionalMargins: EdgeInsetsMM = EdgeInsetsMM(top: 0, leading: 0, bottom: 0, trailing: 0)
    ) throws -> CGRect {
        let values = [
            profileInsets.top, profileInsets.leading, profileInsets.bottom, profileInsets.trailing,
            additionalMargins.top, additionalMargins.leading,
            additionalMargins.bottom, additionalMargins.trailing
        ]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw AppError(.invalidGeometry, retryable: false)
        }
        let top = (profileInsets.top + additionalMargins.top).pdfPoints
        let left = (profileInsets.leading + additionalMargins.leading).pdfPoints
        let bottom = (profileInsets.bottom + additionalMargins.bottom).pdfPoints
        let right = (profileInsets.trailing + additionalMargins.trailing).pdfPoints
        let rect = CGRect(
            x: paper.minX + left,
            y: paper.minY + bottom,
            width: paper.width - left - right,
            height: paper.height - top - bottom
        )
        guard rect.isFiniteAndPositive else { throw AppError(.invalidGeometry, retryable: false) }
        return rect
    }

    public static func aspectFitScale(source: CGSize, destination: CGRect) throws -> CGFloat {
        guard source.isFiniteAndPositive, destination.isFiniteAndPositive else {
            throw AppError(.invalidGeometry, retryable: false)
        }
        return min(destination.width / source.width, destination.height / source.height)
    }

    public static func centredAspectFitRect(source: CGSize, destination: CGRect) throws -> CGRect {
        let scale = try aspectFitScale(source: source, destination: destination)
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: destination.midX - fitted.width / 2,
            y: destination.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    public static func normalizedQuarterTurns(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder >= 0 ? remainder : remainder + 4
    }

    public static func rotatedSize(_ size: CGSize, quarterTurnsClockwise: Int) throws -> CGSize {
        guard size.isFiniteAndPositive else { throw AppError(.invalidGeometry, retryable: false) }
        return normalizedQuarterTurns(quarterTurnsClockwise).isMultiple(of: 2)
            ? size
            : CGSize(width: size.height, height: size.width)
    }

    public static func inferredPaper(for box: CGRect, tolerancePoints: CGFloat = 1.0) -> PaperSpec? {
        PaperSpec.allCases.first { candidate in
            let expected = candidate.points
            return abs(box.width - expected.width) <= tolerancePoints &&
                abs(box.height - expected.height) <= tolerancePoints
        }
    }

    public static func orientationPortrait(box: CGRect, rotationDegrees: Int) -> Bool {
        let quarterTurns = normalizedQuarterTurns(rotationDegrees / 90)
        let size = quarterTurns.isMultiple(of: 2)
            ? box.size
            : CGSize(width: box.height, height: box.width)
        return size.height >= size.width
    }
}

extension CGRect {
    var isFiniteAndPositive: Bool {
        [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite) &&
        width > 0 && height > 0
    }
}

extension CGSize {
    var isFiniteAndPositive: Bool {
        [width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}
