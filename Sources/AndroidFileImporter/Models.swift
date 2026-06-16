import Foundation

struct DeviceInfo: Sendable, Equatable {
    let name: String
    let serial: String
}

struct MTPStorageInfo: Identifiable, Sendable, Hashable {
    let id: UInt32
    let name: String
    let capacity: UInt64
    let freeSpace: UInt64
}

struct MTPItem: Identifiable, Sendable, Hashable {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let size: UInt64
    let modificationDate: Date
    let isFolder: Bool

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isPreviewable: Bool {
        ["jpg", "jpeg", "png", "webp", "heic", "gif"].contains(fileExtension)
    }
}

enum MTPClientError: LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let value): value }
    }
}

protocol MTPClient: Sendable {
    var maxConcurrentDownloads: Int { get }
    func connect() async throws -> DeviceInfo
    func disconnect() async
    func storages() async throws -> [MTPStorageInfo]
    func children(storageID: UInt32, parentID: UInt32) async throws -> [MTPItem]
    func thumbnail(for objectID: UInt32) async throws -> Data
    func download(
        objectID: UInt32,
        to destination: URL,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws
}

extension MTPClient {
    var maxConcurrentDownloads: Int { 1 }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(DeviceInfo)
    case failed(String)
}

enum ConflictChoice: String, CaseIterable, Identifiable, Sendable {
    case replace = "Replace"
    case skip = "Skip"
    case keepBoth = "Keep Both"
    var id: String { rawValue }
}

struct ImportProgress: Sendable, Equatable {
    var currentName = ""
    var completedBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var completedFiles = 0
    var totalFiles = 0
    var skippedFiles = 0
    var failedFiles = 0
    var isRunning = false
    var failure: String?

    var fraction: Double {
        guard totalBytes > 0 else { return totalFiles == 0 ? 0 : Double(completedFiles) / Double(totalFiles) }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}
