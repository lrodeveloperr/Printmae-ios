import Foundation
import CryptoKit

public enum FileHash {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AtomicFileMover {
    public static func replaceItem(at destination: URL, with source: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: source)
        } else {
            try manager.moveItem(at: source, to: destination)
        }
    }

    public static func write(_ data: Data, atomicallyTo destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: temporary, options: .atomic)
            try replaceItem(at: destination, with: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

public enum SecureFileProtection {
    public static func applyCompleteProtection(to url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #else
        _ = url
        #endif
    }
}

public enum StorageBudget {
    public static func estimatedRequiredFreeBytes(inputBytes: Int64) -> Int64 {
        max(1_000_000, inputBytes.multipliedReportingOverflow(by: 3).overflow ? Int64.max : inputBytes * 3)
    }

    public static func assertAvailable(at directory: URL, inputBytes: Int64) throws {
        let required = estimatedRequiredFreeBytes(inputBytes: inputBytes)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage,
           available < required {
            throw AppError(.insufficientStorage, requiredFreeBytes: required)
        }
    }
}

public struct ISO8601Milliseconds {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let ordinary = ISO8601DateFormatter()
            ordinary.formatOptions = [.withInternetDateTime]
            if let date = ordinary.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public actor PrivacySafeDiagnosticLog {
    public enum Event: String, Codable, Sendable {
        case transitionRejected
        case importFailed
        case analysisFailed
        case renderFailed
        case verificationFailed
        case persistenceFailed
        case entitlementDenied
    }

    public struct Entry: Codable, Hashable, Sendable {
        public let event: Event
        public let errorCode: AppErrorCode?
        public let jobToken: String?
        public let occurredAt: Date
    }

    private var entries: [Entry] = []
    private let capacity: Int

    public init(capacity: Int = 200) { self.capacity = max(1, capacity) }

    public func record(_ event: Event, error: AppError? = nil, jobID: UUID? = nil) {
        let token = jobID.map { String(FileHash.sha256(of: Data($0.uuidString.utf8)).prefix(12)) }
        entries.append(Entry(event: event, errorCode: error?.code, jobToken: token, occurredAt: Date()))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func snapshot() -> [Entry] { entries }
}
