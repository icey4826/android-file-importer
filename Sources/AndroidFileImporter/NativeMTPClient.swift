@preconcurrency import CMTPBridge
import Foundation
import Synchronization

private final class TransferControl: @unchecked Sendable {
    let progress: @Sendable (UInt64, UInt64) -> Void
    let isCancelled: @Sendable () -> Bool

    init(
        progress: @escaping @Sendable (UInt64, UInt64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.progress = progress
        self.isCancelled = isCancelled
    }
}

private let nativeProgress: @convention(c) (UInt64, UInt64, UnsafeMutableRawPointer?) -> Int32 = {
    completed, total, pointer in
    guard let pointer else { return 0 }
    let control = Unmanaged<TransferControl>.fromOpaque(pointer).takeUnretainedValue()
    control.progress(completed, total)
    return control.isCancelled() ? 1 : 0
}

final class NativeMTPClient: MTPClient, @unchecked Sendable {
    private let context: OpaquePointer
    private let lock = Mutex(())

    init?() {
        guard let context = mtp_context_create() else { return nil }
        self.context = context
    }

    deinit { mtp_context_destroy(context) }

    func connect() async throws -> DeviceInfo {
        try lock.withLock { _ in
        var error = [CChar](repeating: 0, count: 1024)
        let result = error.withUnsafeMutableBufferPointer {
            mtp_connect(context, $0.baseAddress!, $0.count)
        }
        try check(result, error: error)
        return DeviceInfo(
            name: copiedString(mtp_copy_device_name(context)) ?? "Android device",
            serial: copiedString(mtp_copy_device_serial(context)) ?? "unknown"
        )
        }
    }

    func disconnect() async { lock.withLock { _ in mtp_disconnect(context) } }

    func storages() async throws -> [MTPStorageInfo] {
        try lock.withLock { _ in
        var pointer: UnsafeMutablePointer<MTPStorage>?
        var count = 0
        var error = [CChar](repeating: 0, count: 1024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            mtp_copy_storages(context, &pointer, &count, buffer.baseAddress!, buffer.count)
        }
        try check(result, error: error)
        guard let pointer else { return [] }
        defer { mtp_storages_free(pointer, count) }
        return (0..<count).map { index in
            let value = pointer[index]
            return MTPStorageInfo(
                id: value.id,
                name: String(cString: value.name),
                capacity: value.capacity,
                freeSpace: value.free_space
            )
        }
        }
    }

    func children(storageID: UInt32, parentID: UInt32) async throws -> [MTPItem] {
        try lock.withLock { _ in
        var pointer: UnsafeMutablePointer<MTPObject>?
        var count = 0
        var error = [CChar](repeating: 0, count: 1024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            mtp_copy_children(context, storageID, parentID, &pointer, &count, buffer.baseAddress!, buffer.count)
        }
        try check(result, error: error)
        guard let pointer else { return [] }
        defer { mtp_objects_free(pointer, count) }
        return (0..<count).map { index in
            let value = pointer[index]
            return MTPItem(
                id: value.id,
                parentID: value.parent_id,
                storageID: value.storage_id,
                name: String(cString: value.name),
                size: value.size,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(value.modified_at)),
                isFolder: value.is_folder != 0
            )
        }
        .sorted { left, right in
            if left.isFolder != right.isFolder { return left.isFolder }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        }
    }

    func thumbnail(for objectID: UInt32) async throws -> Data {
        try lock.withLock { _ in
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        var error = [CChar](repeating: 0, count: 1024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            mtp_copy_thumbnail(context, objectID, &bytes, &count, buffer.baseAddress!, buffer.count)
        }
        try check(result, error: error)
        guard let bytes else { throw MTPClientError.message("No thumbnail is available.") }
        defer { mtp_bytes_free(bytes) }
        return Data(bytes: bytes, count: count)
        }
    }

    func download(
        objectID: UInt32,
        to destination: URL,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        try lock.withLock { _ in
        let control = TransferControl(progress: progress, isCancelled: isCancelled)
        let pointer = Unmanaged.passRetained(control).toOpaque()
        defer { Unmanaged<TransferControl>.fromOpaque(pointer).release() }
        var error = [CChar](repeating: 0, count: 1024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            destination.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return mtp_download(context, objectID, path, nativeProgress, pointer, buffer.baseAddress!, buffer.count)
            }
        }
        try check(result, error: error)
        }
    }

    private func copiedString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { mtp_string_free(pointer) }
        return String(cString: pointer)
    }

    private func check(_ result: Int32, error bytes: [CChar]) throws {
        if result != 0 {
            let message = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            throw MTPClientError.message(message.isEmpty ? "The MTP operation failed." : message)
        }
    }
}
