import Foundation
import Synchronization
import Testing
@testable import AndroidFileImporter

actor FakeMTPClient: MTPClient {
    let contents: [UInt32: [MTPItem]]
    let payloads: [UInt32: Data]

    init(contents: [UInt32: [MTPItem]] = [:], payloads: [UInt32: Data] = [:]) {
        self.contents = contents
        self.payloads = payloads
    }

    func connect() async throws -> DeviceInfo { DeviceInfo(name: "Android device", serial: "test") }
    func disconnect() async { }
    func storages() async throws -> [MTPStorageInfo] { [] }
    func children(storageID: UInt32, parentID: UInt32) async throws -> [MTPItem] { contents[parentID] ?? [] }
    func thumbnail(for objectID: UInt32) async throws -> Data { Data() }
    func download(
        objectID: UInt32,
        to destination: URL,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        if isCancelled() { throw CancellationError() }
        let data = payloads[objectID] ?? Data()
        try data.write(to: destination)
        progress(UInt64(data.count), UInt64(data.count))
    }
}

actor FailingMTPClient: MTPClient {
    let failedID: UInt32

    init(failedID: UInt32) { self.failedID = failedID }

    func connect() async throws -> DeviceInfo { DeviceInfo(name: "Android device", serial: "test") }
    func disconnect() async { }
    func storages() async throws -> [MTPStorageInfo] { [] }
    func children(storageID: UInt32, parentID: UInt32) async throws -> [MTPItem] { [] }
    func thumbnail(for objectID: UInt32) async throws -> Data { Data() }
    func download(
        objectID: UInt32,
        to destination: URL,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        if objectID == failedID { throw MTPClientError.message("Invalid destination name") }
        try Data("ok".utf8).write(to: destination)
        progress(2, 2)
    }
}

final class ConcurrentMTPClient: MTPClient, @unchecked Sendable {
    let maxConcurrentDownloads = 2
    private let activity = Mutex((active: 0, maximum: 0))

    var maximumObservedDownloads: Int { activity.withLock(\.maximum) }

    func connect() async throws -> DeviceInfo { DeviceInfo(name: "Android device", serial: "test") }
    func disconnect() async { }
    func storages() async throws -> [MTPStorageInfo] { [] }
    func children(storageID: UInt32, parentID: UInt32) async throws -> [MTPItem] { [] }
    func thumbnail(for objectID: UInt32) async throws -> Data { Data() }
    func download(
        objectID: UInt32,
        to destination: URL,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        activity.withLock {
            $0.active += 1
            $0.maximum = max($0.maximum, $0.active)
        }
        defer { activity.withLock { $0.active -= 1 } }
        try await Task.sleep(for: .milliseconds(50))
        try Data("\(objectID)".utf8).write(to: destination)
        progress(1, 1)
    }
}

@Suite("Import engine")
struct ImportEngineTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Expands folders while preserving hierarchy")
    func expandsFolders() async throws {
        let file = item(id: 2, parent: 1, name: "photo.jpg", size: 3)
        let folder = item(id: 1, parent: 0, name: "Camera", isFolder: true)
        let engine = ImportEngine(client: FakeMTPClient(contents: [1: [file]]))

        let result = try await engine.expand([folder])

        #expect(result == [ImportCandidate(item: file, relativePath: "Camera/photo.jpg", selectionID: folder.id)])
    }

    @Test("Keep both selects a numbered sibling and removes partial files")
    func keepBoth() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appending(path: "photo.jpg"))

        let file = item(id: 2, parent: 0, name: "photo.jpg", size: 3)
        let engine = ImportEngine(client: FakeMTPClient(payloads: [2: Data("new".utf8)]))
        let candidates = try await engine.expand([file])
        _ = try await engine.run(candidates: candidates, destination: root, conflictResolver: { _ in .keepBoth }, progress: { _ in })

        #expect(try Data(contentsOf: root.appending(path: "photo 2.jpg")) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "photo 2.jpg.part").path))
    }

    @Test("Skip leaves an existing file unchanged")
    func skip() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "photo.jpg")
        try Data("old".utf8).write(to: target)

        let file = item(id: 2, parent: 0, name: "photo.jpg", size: 3)
        let engine = ImportEngine(client: FakeMTPClient(payloads: [2: Data("new".utf8)]))
        let candidates = try await engine.expand([file])
        _ = try await engine.run(candidates: candidates, destination: root, conflictResolver: { _ in .skip }, progress: { _ in })

        #expect(try Data(contentsOf: target) == Data("old".utf8))
    }

    @Test("One failed file does not stop the remaining queue")
    func continuesAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = item(id: 1, parent: 0, name: "bad.jpg", size: 2)
        let good = item(id: 2, parent: 0, name: "good.jpg", size: 2)
        let engine = ImportEngine(client: FailingMTPClient(failedID: failed.id))

        let result = try await engine.run(
            candidates: [ImportCandidate(item: failed, relativePath: failed.name), ImportCandidate(item: good, relativePath: good.name)],
            destination: root,
            conflictResolver: { _ in .keepBoth },
            progress: { _ in }
        )

        #expect(result.importedFiles == 1)
        #expect(result.failures.map(\.name) == [failed.name])
        #expect(try Data(contentsOf: root.appending(path: good.name)) == Data("ok".utf8))
    }

    @Test("Sanitizes invalid and oversized destination names")
    func sanitizesNames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let longName = String(repeating: "a", count: 300) + ":photo.jpg"
        let file = item(id: 3, parent: 0, name: longName, size: 2)
        let engine = ImportEngine(client: FakeMTPClient(payloads: [file.id: Data("ok".utf8)]))

        let candidates = try await engine.expand([file])
        let result = try await engine.run(
            candidates: candidates,
            destination: root,
            conflictResolver: { _ in .keepBoth },
            progress: { _ in }
        )

        #expect(result.failures.isEmpty)
        #expect(candidates[0].relativePath.utf8.count <= 220)
        #expect(!candidates[0].relativePath.contains(":"))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: candidates[0].relativePath).path))
    }

    @Test("Uses the client concurrency limit")
    func boundedConcurrency() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ConcurrentMTPClient()
        let engine = ImportEngine(client: client)
        let candidates = (1...4).map { id in
            let file = item(id: UInt32(id), parent: 0, name: "\(id).jpg", size: 1)
            return ImportCandidate(item: file, relativePath: file.name)
        }

        let result = try await engine.run(
            candidates: candidates,
            destination: root,
            conflictResolver: { _ in .keepBoth },
            progress: { _ in }
        )

        #expect(result.importedFiles == 4)
        #expect(client.maximumObservedDownloads == 2)
    }

    @Test("Reserves duplicate destinations before concurrent transfers")
    func reservesDuplicateDestinations() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = item(id: 1, parent: 0, name: "photo.jpg", size: 1)
        let second = item(id: 2, parent: 0, name: "PHOTO.JPG", size: 1)
        let client = ConcurrentMTPClient()
        let engine = ImportEngine(client: client)

        let result = try await engine.run(
            candidates: [
                ImportCandidate(item: first, relativePath: first.name),
                ImportCandidate(item: second, relativePath: second.name),
            ],
            destination: root,
            conflictResolver: { _ in .keepBoth },
            progress: { _ in }
        )

        #expect(result.importedFiles == 2)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "photo.jpg").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "PHOTO 2.JPG").path))
    }

    private func item(
        id: UInt32,
        parent: UInt32,
        name: String,
        size: UInt64 = 0,
        isFolder: Bool = false
    ) -> MTPItem {
        MTPItem(
            id: id,
            parentID: parent,
            storageID: 10,
            name: name,
            size: size,
            modificationDate: date,
            isFolder: isFolder
        )
    }
}
