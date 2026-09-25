import Foundation

public actor FileJobRepository: JobRepository {
    public nonisolated let root: URL
    public nonisolated let stagingRoot: URL
    public nonisolated let jobsRoot: URL
    public nonisolated let outputsRoot: URL
    private let fileManager: FileManager
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    private var pendingSnapshots: [UUID: PrintJobSnapshot] = [:]
    private let reducer = JobStateReducer()

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root.standardizedFileURL
        self.stagingRoot = root.appendingPathComponent("Staging", isDirectory: true)
        self.jobsRoot = root.appendingPathComponent("Jobs", isDirectory: true)
        self.outputsRoot = root.appendingPathComponent("Outputs", isDirectory: true)
        self.fileManager = fileManager
        for directory in [self.root, stagingRoot, jobsRoot, outputsRoot] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try SecureFileProtection.applyCompleteProtection(to: directory)
        }
    }

    public func saveImmediately(_ job: PrintJobSnapshot) async throws {
        pendingSaves[job.id]?.cancel()
        pendingSaves[job.id] = nil
        pendingSnapshots[job.id] = nil
        var normalized = job
        normalized.updatedAt = max(job.updatedAt, job.createdAt)
        let data = try ISO8601Milliseconds.encoder().encode(normalized)
        try AtomicFileMover.write(data, atomicallyTo: jobURL(job.id))
        try SecureFileProtection.applyCompleteProtection(to: jobURL(job.id))
        try AtomicFileMover.write(Data(job.id.uuidString.utf8), atomicallyTo: activeJobURL)
        try SecureFileProtection.applyCompleteProtection(to: activeJobURL)
    }

    public func saveDebounced(_ job: PrintJobSnapshot) async {
        pendingSaves[job.id]?.cancel()
        pendingSnapshots[job.id] = job
        pendingSaves[job.id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                try await self?.saveImmediately(job)
            } catch {
                // The caller's next foreground/recovery pass will retry. Never log document data.
            }
        }
    }

    public func flushPendingSave(for id: UUID) async throws {
        guard let snapshot = pendingSnapshots[id] else { return }
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        pendingSnapshots[id] = nil
        try await saveImmediately(snapshot)
    }

    public func require(_ id: UUID) async throws -> PrintJobSnapshot {
        let url = jobURL(id)
        guard fileManager.fileExists(atPath: url.path) else { throw AppError(.jobNotFound, retryable: false) }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try ISO8601Milliseconds.decoder().decode(PrintJobSnapshot.self, from: data)
            guard decoded.schemaVersion <= PrintJobSnapshot.currentSchemaVersion else {
                throw AppError(.persistenceFailed, retryable: false)
            }
            return decoded
        } catch let appError as AppError {
            throw appError
        } catch {
            throw AppError(.persistenceFailed, retryable: false)
        }
    }

    public func activeJob() async throws -> PrintJobSnapshot? {
        guard let data = try? Data(contentsOf: activeJobURL),
              let raw = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        let stored = try await require(id)
        let recovered = reducer.recoveredAfterUncleanTermination(stored)
        if recovered != stored {
            try await saveImmediately(recovered)
            await deleteIncompleteOutputs(for: id)
        }
        return recovered
    }

    public func stagedDocument(for id: UUID) async throws -> StagedDocument {
        let job = try await require(id)
        guard let descriptor = job.source,
              descriptor.stagedRelativePath == URL(fileURLWithPath: descriptor.stagedRelativePath).lastPathComponent
        else { throw AppError(.jobNotFound, retryable: false) }
        let url = stagingRoot.appendingPathComponent(descriptor.stagedRelativePath)
        guard fileManager.fileExists(atPath: url.path) else { throw AppError(.jobNotFound, retryable: false) }
        guard try FileHash.sha256(of: url) == descriptor.sha256 else {
            throw AppError(
                .stagingFailed,
                localizationKey: "error.stagedCopyIntegrityFailed",
                retryable: false
            )
        }
        return StagedDocument(descriptor: descriptor, url: url)
    }

    public func registerStagedDocument(_ document: StagedDocument, for id: UUID) async throws {
        let expectedParent = stagingRoot.resolvingSymlinksInPath().standardizedFileURL
        let actualParent = document.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard expectedParent == actualParent,
              document.descriptor.stagedRelativePath == document.url.lastPathComponent,
              try FileHash.sha256(of: document.url) == document.descriptor.sha256 else {
            throw AppError(.stagingFailed, retryable: false)
        }
        try SecureFileProtection.applyCompleteProtection(to: document.url)
    }

    public func deleteIncompleteOutputs(for id: UUID) async {
        let prefix = ".\(id.uuidString)"
        guard let files = try? fileManager.contentsOfDirectory(
            at: outputsRoot,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) || file.lastPathComponent.contains(".partial") {
            try? fileManager.removeItem(at: file)
        }
    }

    public func cleanupCompletedJobs(olderThan cutoff: Date) async throws -> Int {
        let jobFiles = try fileManager.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        var cleaned = 0
        for file in jobFiles {
            guard let data = try? Data(contentsOf: file),
                  let job = try? ISO8601Milliseconds.decoder().decode(PrintJobSnapshot.self, from: data),
                  job.phase == .completed,
                  !job.keepProject,
                  job.updatedAt <= cutoff else { continue }
            if let source = job.source,
               source.stagedRelativePath == URL(fileURLWithPath: source.stagedRelativePath).lastPathComponent {
                try? fileManager.removeItem(at: stagingRoot.appendingPathComponent(source.stagedRelativePath))
            }
            try? fileManager.removeItem(at: outputsRoot.appendingPathComponent(job.id.uuidString))
            try? fileManager.removeItem(at: file)
            cleaned += 1
        }
        return cleaned
    }

    public func deleteAllDocumentsAndJobs() async throws {
        pendingSaves.values.forEach { $0.cancel() }
        pendingSaves.removeAll()
        pendingSnapshots.removeAll()
        for directory in [stagingRoot, jobsRoot, outputsRoot] {
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for item in contents { try fileManager.removeItem(at: item) }
        }
        try? fileManager.removeItem(at: activeJobURL)
    }

    /// The repository and importer must share a staging root for staged-document verification
    /// to succeed; this builds an importer that is guaranteed to match this repository's root
    /// instead of relying on the caller to wire the two together correctly by convention.
    public func makeImporter(fileManager: FileManager = .default) -> LocalDocumentImporter {
        LocalDocumentImporter(stagingRoot: stagingRoot, fileManager: fileManager)
    }

    public func outputDirectory(for id: UUID) throws -> URL {
        let directory = outputsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try SecureFileProtection.applyCompleteProtection(to: directory)
        return directory
    }

    private var activeJobURL: URL { root.appendingPathComponent("active_job") }
    private func jobURL(_ id: UUID) -> URL { jobsRoot.appendingPathComponent("\(id.uuidString).json") }
}

public struct PrintPreset: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var profileID: String
    public var targetPaper: PaperSpec
    public var recipe: EditRecipe
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        profileID: String,
        targetPaper: PaperSpec,
        recipe: EditRecipe,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.targetPaper = targetPaper
        self.recipe = recipe
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public actor FilePresetRepository {
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func all() throws -> [PrintPreset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try ISO8601Milliseconds.decoder().decode([PrintPreset].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ preset: PrintPreset) throws {
        var values = try all()
        if let index = values.firstIndex(where: { $0.id == preset.id }) {
            values[index] = preset
        } else {
            values.append(preset)
        }
        try AtomicFileMover.write(try ISO8601Milliseconds.encoder().encode(values), atomicallyTo: fileURL)
        try SecureFileProtection.applyCompleteProtection(to: fileURL)
    }

    public func delete(_ id: UUID) throws {
        let values = try all().filter { $0.id != id }
        try AtomicFileMover.write(try ISO8601Milliseconds.encoder().encode(values), atomicallyTo: fileURL)
    }
}
