import Foundation
import Synchronization

struct ImportCandidate: Sendable, Equatable {
    let item: MTPItem
    let relativePath: String
    let selectionID: UInt32

    init(item: MTPItem, relativePath: String, selectionID: UInt32? = nil) {
        self.item = item
        self.relativePath = relativePath
        self.selectionID = selectionID ?? item.id
    }
}

struct ImportFailure: Sendable, Equatable {
    let selectionID: UInt32
    let name: String
    let message: String
}

struct ImportResult: Sendable, Equatable {
    var importedFiles = 0
    var skippedFiles = 0
    var failures: [ImportFailure] = []

    var failedSelectionIDs: Set<UInt32> { Set(failures.map(\.selectionID)) }
}

private struct PreparedTransfer: Sendable {
    let index: Int
    let candidate: ImportCandidate
    let finalURL: URL
    let partialURL: URL
}

private struct TransferOutcome: Sendable {
    let transfer: PreparedTransfer
    let errorMessage: String?
    let wasCancelled: Bool
}

private struct SendableFileManager: @unchecked Sendable {
    let value: FileManager
}

private final class ImportProgressReporter: @unchecked Sendable {
    private struct State {
        var completedBytes: UInt64
        var activeBytes: [Int: UInt64] = [:]
        var completedFiles: Int
        var skippedFiles: Int
        var failedFiles: Int
    }

    private let state: Mutex<State>
    private let totalBytes: UInt64
    private let totalFiles: Int
    private let progress: @Sendable (ImportProgress) -> Void

    init(
        totalBytes: UInt64,
        totalFiles: Int,
        completedBytes: UInt64,
        completedFiles: Int,
        skippedFiles: Int,
        failedFiles: Int,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.progress = progress
        state = Mutex(State(
            completedBytes: completedBytes,
            completedFiles: completedFiles,
            skippedFiles: skippedFiles,
            failedFiles: failedFiles
        ))
    }

    func started(_ transfer: PreparedTransfer) {
        publish(currentName: transfer.candidate.item.name, isRunning: true)
    }

    func updated(_ transfer: PreparedTransfer, bytes: UInt64) {
        let value = state.withLock { state in
            state.activeBytes[transfer.index] = min(bytes, transfer.candidate.item.size)
            return snapshot(state: state, currentName: transfer.candidate.item.name, isRunning: true)
        }
        progress(value)
    }

    func completed(_ transfer: PreparedTransfer, failed: Bool) {
        let value = state.withLock { state in
            state.activeBytes.removeValue(forKey: transfer.index)
            state.completedBytes += transfer.candidate.item.size
            state.completedFiles += 1
            if failed { state.failedFiles += 1 }
            return snapshot(state: state, currentName: transfer.candidate.item.name, isRunning: true)
        }
        progress(value)
    }

    func finished() {
        publish(currentName: "", isRunning: false)
    }

    private func publish(currentName: String, isRunning: Bool) {
        let value = state.withLock { snapshot(state: $0, currentName: currentName, isRunning: isRunning) }
        progress(value)
    }

    private func snapshot(state: State, currentName: String, isRunning: Bool) -> ImportProgress {
        ImportProgress(
            currentName: currentName,
            completedBytes: state.completedBytes + state.activeBytes.values.reduce(0, +),
            totalBytes: totalBytes,
            completedFiles: state.completedFiles,
            totalFiles: totalFiles,
            skippedFiles: state.skippedFiles,
            failedFiles: state.failedFiles,
            isRunning: isRunning
        )
    }
}

actor ImportEngine {
    typealias ConflictResolver = @Sendable (URL) async -> ConflictChoice

    private let client: any MTPClient
    private let fileManager: FileManager
    private let cancelled = Mutex(false)

    init(client: any MTPClient, fileManager: FileManager = .default) {
        self.client = client
        self.fileManager = fileManager
    }

    func cancel() { cancelled.withLock { $0 = true } }

    func expand(_ selections: [MTPItem]) async throws -> [ImportCandidate] {
        var output: [ImportCandidate] = []
        for item in selections {
            try await append(item, relativePath: sanitized(item.name), selectionID: item.id, to: &output)
        }
        return output
    }

    func run(
        candidates: [ImportCandidate],
        destination: URL,
        conflictResolver: @escaping ConflictResolver,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> ImportResult {
        cancelled.withLock { $0 = false }
        let totalBytes = candidates.reduce(UInt64(0)) { $0 + $1.item.size }
        var result = ImportResult()
        var prepared: [PreparedTransfer] = []
        var reservedPaths: Set<String> = []
        var preflightBytes: UInt64 = 0

        for (index, candidate) in candidates.enumerated() {
            if isCancelled { throw CancellationError() }
            do {
                let desiredURL = destination.appending(path: candidate.relativePath)
                try fileManager.createDirectory(at: desiredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let finalURL = await resolvedDestination(
                    desiredURL,
                    reservedPaths: reservedPaths,
                    conflictResolver: conflictResolver
                ) else {
                    result.skippedFiles += 1
                    preflightBytes += candidate.item.size
                    continue
                }
                reservedPaths.insert(reservationKey(for: finalURL))
                prepared.append(PreparedTransfer(
                    index: index,
                    candidate: candidate,
                    finalURL: finalURL,
                    partialURL: finalURL.appendingPathExtension("part")
                ))
            } catch {
                result.failures.append(failure(for: candidate, error: error))
                preflightBytes += candidate.item.size
            }
        }

        let reporter = ImportProgressReporter(
            totalBytes: totalBytes,
            totalFiles: candidates.count,
            completedBytes: preflightBytes,
            completedFiles: result.skippedFiles + result.failures.count,
            skippedFiles: result.skippedFiles,
            failedFiles: result.failures.count,
            progress: progress
        )

        var nextTransfer = 0
        var wasCancelled = false
        let concurrency = max(1, min(client.maxConcurrentDownloads, prepared.count))
        let transferFileManager = SendableFileManager(value: fileManager)
        await withTaskGroup(of: TransferOutcome.self) { group in
            func addNext() {
                guard nextTransfer < prepared.count, !isCancelled else { return }
                let transfer = prepared[nextTransfer]
                nextTransfer += 1
                reporter.started(transfer)
                group.addTask { [client, transferFileManager] in
                    await Self.perform(
                        transfer,
                        client: client,
                        fileManager: transferFileManager,
                        reporter: reporter,
                        isCancelled: { self.isCancelled || Task.isCancelled }
                    )
                }
            }

            for _ in 0..<concurrency { addNext() }
            while let outcome = await group.next() {
                if outcome.wasCancelled {
                    wasCancelled = true
                    group.cancelAll()
                } else if let errorMessage = outcome.errorMessage {
                    result.failures.append(ImportFailure(
                        selectionID: outcome.transfer.candidate.selectionID,
                        name: outcome.transfer.candidate.item.name,
                        message: errorMessage
                    ))
                    reporter.completed(outcome.transfer, failed: true)
                } else {
                    result.importedFiles += 1
                    reporter.completed(outcome.transfer, failed: false)
                }
                if !wasCancelled { addNext() }
            }
        }

        if wasCancelled || isCancelled { throw CancellationError() }
        reporter.finished()
        return result
    }

    nonisolated private var isCancelled: Bool { cancelled.withLock { $0 } }

    private func append(
        _ item: MTPItem,
        relativePath: String,
        selectionID: UInt32,
        to output: inout [ImportCandidate]
    ) async throws {
        if item.isFolder {
            let children = try await client.children(storageID: item.storageID, parentID: item.id)
            for child in children {
                try await append(
                    child,
                    relativePath: relativePath + "/" + sanitized(child.name),
                    selectionID: selectionID,
                    to: &output
                )
            }
        } else {
            output.append(ImportCandidate(item: item, relativePath: relativePath, selectionID: selectionID))
        }
    }

    private func resolvedDestination(
        _ url: URL,
        reservedPaths: Set<String>,
        conflictResolver: ConflictResolver
    ) async -> URL? {
        if reservedPaths.contains(reservationKey(for: url)) {
            return availableSibling(for: url, reservedPaths: reservedPaths)
        }
        guard fileManager.fileExists(atPath: url.path) else { return url }
        switch await conflictResolver(url) {
        case .skip: return nil
        case .replace: return url
        case .keepBoth: return availableSibling(for: url, reservedPaths: reservedPaths)
        }
    }

    private func availableSibling(for url: URL, reservedPaths: Set<String>) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let candidate = directory.appending(path: name)
            if !reservedPaths.contains(reservationKey(for: candidate)), !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func sanitized(_ name: String) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        let replaced = String(normalized.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = replaced.isEmpty || replaced == "." || replaced == ".." ? "Untitled" : replaced
        return lengthLimited(valid, maxUTF8Bytes: 220)
    }

    private func lengthLimited(_ name: String, maxUTF8Bytes: Int) -> String {
        guard name.utf8.count > maxUTF8Bytes else { return name }
        let value = name as NSString
        let ext = value.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        guard suffix.utf8.count < maxUTF8Bytes else {
            return utf8Prefix(of: name, maxBytes: maxUTF8Bytes)
        }
        let stem = ext.isEmpty ? name : value.deletingPathExtension
        let stemBudget = max(1, maxUTF8Bytes - suffix.utf8.count)
        let output = utf8Prefix(of: stem, maxBytes: stemBudget)
        return (output.isEmpty ? "Untitled" : output) + suffix
    }

    private func utf8Prefix(of value: String, maxBytes: Int) -> String {
        var output = ""
        for character in value {
            if output.utf8.count + String(character).utf8.count > maxBytes { break }
            output.append(character)
        }
        return output
    }

    private func reservationKey(for url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func failure(for candidate: ImportCandidate, error: any Error) -> ImportFailure {
        ImportFailure(
            selectionID: candidate.selectionID,
            name: candidate.item.name,
            message: error.localizedDescription
        )
    }

    nonisolated private static func perform(
        _ transfer: PreparedTransfer,
        client: any MTPClient,
        fileManager: SendableFileManager,
        reporter: ImportProgressReporter,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> TransferOutcome {
        try? fileManager.value.removeItem(at: transfer.partialURL)
        do {
            try await client.download(
                objectID: transfer.candidate.item.id,
                to: transfer.partialURL,
                progress: { current, _ in reporter.updated(transfer, bytes: current) },
                isCancelled: isCancelled
            )
            if fileManager.value.fileExists(atPath: transfer.finalURL.path) {
                try fileManager.value.removeItem(at: transfer.finalURL)
            }
            try fileManager.value.moveItem(at: transfer.partialURL, to: transfer.finalURL)
            try? fileManager.value.setAttributes(
                [.modificationDate: transfer.candidate.item.modificationDate],
                ofItemAtPath: transfer.finalURL.path
            )
            return TransferOutcome(transfer: transfer, errorMessage: nil, wasCancelled: false)
        } catch is CancellationError {
            try? fileManager.value.removeItem(at: transfer.partialURL)
            return TransferOutcome(transfer: transfer, errorMessage: nil, wasCancelled: true)
        } catch {
            try? fileManager.value.removeItem(at: transfer.partialURL)
            return TransferOutcome(transfer: transfer, errorMessage: error.localizedDescription, wasCancelled: false)
        }
    }
}
