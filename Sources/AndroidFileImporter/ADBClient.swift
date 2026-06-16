import AppKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

private actor AsyncLimiter {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) { self.permits = permits }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class ADBClient: MTPClient, @unchecked Sendable {
    let maxConcurrentDownloads = 2

    private let adbURL: URL
    private let operationLock = Mutex(())
    private let paths = Mutex<[UInt32: String]>([0: "/sdcard"])
    private let cacheKeys = Mutex<[UInt32: String]>([:])
    private let thumbnailSlots = AsyncLimiter(permits: 4)
    private let thumbnailCacheURL: URL

    init?() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundled = root.appending(path: "Vendor/platform-tools/adb")
        let appBundled = Bundle.main.resourceURL?.appending(path: "platform-tools/adb")
        let environment = ProcessInfo.processInfo.environment["ANDROID_HOME"].map {
            URL(fileURLWithPath: $0).appending(path: "platform-tools/adb")
        }
        guard let found = [appBundled, bundled, environment].compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { return nil }
        adbURL = found
        thumbnailCacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "AndroidFileImporter/Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: thumbnailCacheURL, withIntermediateDirectories: true)
    }

    func connect() async throws -> DeviceInfo {
        try operationLock.withLock { _ in
            let devices = try run(["devices", "-l"]).output
            let lines = devices.split(separator: "\n").dropFirst()
            guard let line = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw MTPClientError.message("Enable USB debugging on the Android device, reconnect it, then approve this Mac on the phone.")
            }
            if line.contains("unauthorized") {
                throw MTPClientError.message("Unlock the Android device and approve the USB debugging request.")
            }
            guard line.contains("device") else {
                throw MTPClientError.message("The Android device is connected but USB debugging is not ready.")
            }
            let serial = String(line.split(separator: " ").first ?? "unknown")
            let model = try run(["shell", "getprop", "ro.product.model"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            paths.withLock { $0 = [0: "/sdcard"] }
            cacheKeys.withLock { $0.removeAll(keepingCapacity: true) }
            return DeviceInfo(name: model.isEmpty ? "Android device" : model, serial: serial)
        }
    }

    func disconnect() async { }

    func storages() async throws -> [MTPStorageInfo] {
        try operationLock.withLock { _ in
            let output = try run(["shell", "df", "-k", "/sdcard"]).output
            let columns = output.split(separator: "\n").last?.split(whereSeparator: \.isWhitespace) ?? []
            let capacity = columns.count >= 4 ? UInt64(columns[1]).map { $0 * 1024 } ?? 0 : 0
            let free = columns.count >= 4 ? UInt64(columns[3]).map { $0 * 1024 } ?? 0 : 0
            return [MTPStorageInfo(id: 1, name: "Android storage", capacity: capacity, freeSpace: free)]
        }
    }

    func children(storageID: UInt32, parentID: UInt32) async throws -> [MTPItem] {
        try operationLock.withLock { _ in
            guard let parent = paths.withLock({ $0[parentID] }) else { throw MTPClientError.message("Folder location is no longer available.") }
            let separator = "\u{1F}"
            let format = "%f\(separator)%s\(separator)%Y\(separator)%n"
            let script = #"stat -c "$2" "$1"/* 2>/dev/null; true"#
            let output = try run(["exec-out", "sh", "-c", script, "sh", parent, format]).output
            var result: [MTPItem] = []
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = line.split(separator: Character(separator), maxSplits: 3, omittingEmptySubsequences: false)
                guard fields.count == 4,
                      let mode = UInt32(fields[0], radix: 16) else { continue }
                let path = String(fields[3])
                let id = identifier(for: path)
                paths.withLock { $0[id] = path }
                cacheKeys.withLock { $0[id] = "\(fields[1])-\(fields[2])" }
                result.append(MTPItem(
                    id: id,
                    parentID: parentID,
                    storageID: storageID,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    size: UInt64(fields[1]) ?? 0,
                    modificationDate: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                    isFolder: mode & 0xF000 == 0x4000
                ))
            }
            return result.sorted {
                $0.isFolder == $1.isFolder
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.isFolder
            }
        }
    }

    func thumbnail(for objectID: UInt32) async throws -> Data {
        guard let path = paths.withLock({ $0[objectID] }) else {
            throw MTPClientError.message("File location is no longer available.")
        }
        let key = cacheKeys.withLock { $0[objectID] } ?? "unknown"
        let cacheURL = thumbnailCacheURL.appending(path: "\(objectID)-\(key).jpg")
        if let cached = try? Data(contentsOf: cacheURL) { return cached }

        await thumbnailSlots.acquire()
        do {
            if let cached = try? Data(contentsOf: cacheURL) {
                await thumbnailSlots.release()
                return cached
            }
            let original = try runData(["exec-out", "cat", path])
            guard let thumbnail = downsampledJPEG(from: original) else {
                throw MTPClientError.message("This image could not be previewed.")
            }
            try? thumbnail.write(to: cacheURL, options: .atomic)
            await thumbnailSlots.release()
            return thumbnail
        } catch {
            await thumbnailSlots.release()
            throw error
        }
    }

    func download(
        objectID: UInt32,
        to destination: URL,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        guard let path = paths.withLock({ $0[objectID] }) else {
            throw MTPClientError.message("File location is no longer available.")
        }
        let process = Process()
        process.executableURL = adbURL
        var arguments = ["pull", "-a", "-q"]
        if shouldDisableCompression(for: path) { arguments.append("-Z") }
        arguments.append(contentsOf: [path, destination.path])
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        while process.isRunning {
            if isCancelled() {
                terminate(process)
                throw CancellationError()
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                terminate(process)
                throw CancellationError()
            }
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MTPClientError.message(message.flatMap { $0.isEmpty ? nil : $0 } ?? "ADB transfer failed.")
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        progress(size, size)
    }

    private func identifier(for path: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    private func shouldDisableCompression(for path: String) -> Bool {
        let compressedExtensions: Set<String> = [
            "7z", "aac", "apk", "avif", "gif", "gz", "heic", "heif", "jpeg", "jpg",
            "m4a", "m4v", "mov", "mp3", "mp4", "pdf", "png", "rar", "webm", "webp", "zip",
        ]
        return compressedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func run(_ arguments: [String]) throws -> (output: String, error: String) {
        let output = try runData(arguments)
        return (String(data: output, encoding: .utf8) ?? "", "")
    }

    private func runData(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = adbURL
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw MTPClientError.message(String(data: error, encoding: .utf8) ?? "ADB command failed.")
        }
        return output
    }

    private func downsampledJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
