import Foundation
import Testing
@testable import AndroidFileImporter

@Suite("ADB client integration")
struct ADBClientIntegrationTests {
    @Test("Downsamples and caches Android camera thumbnails")
    func thumbnails() async throws {
        guard ProcessInfo.processInfo.environment["PIXEL_INTEGRATION_TEST"] == "1" else { return }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "AndroidFileImporter/Thumbnails")
        try? FileManager.default.removeItem(at: cache)

        let client = try #require(ADBClient())
        _ = try await client.connect()
        let storage = try #require(try await client.storages().first)
        let root = try await client.children(storageID: storage.id, parentID: 0)
        let dcim = try #require(root.first(where: { $0.name == "DCIM" }))
        let dcimChildren = try await client.children(storageID: storage.id, parentID: dcim.id)
        let camera = try #require(dcimChildren.first(where: { $0.name == "Camera" }))
        let photos = Array(try await client.children(storageID: storage.id, parentID: camera.id)
            .filter(\.isPreviewable).prefix(8))
        #expect(!photos.isEmpty)

        let clock = ContinuousClock()
        let cold = await clock.measure {
            await withTaskGroup(of: (String, Data?).self) { group in
                for photo in photos { group.addTask { (photo.name, try? await client.thumbnail(for: photo.id)) } }
                var values: [(String, Data?)] = []
                for await value in group { values.append(value) }
                for value in values { print("Thumbnail \(value.0): \(value.1?.count ?? 0) bytes") }
                #expect(values.compactMap(\.1).allSatisfy { $0.count < 100_000 })
                #expect(!values.compactMap(\.1).isEmpty)
            }
        }
        let warm = await clock.measure {
            for photo in photos { _ = try? await client.thumbnail(for: photo.id) }
        }

        print("Android thumbnails: cold=\(cold), warm=\(warm), count=\(photos.count)")
        #expect(warm < cold)
    }

    @Test("Imports two Android camera files through the concurrent queue")
    func concurrentImport() async throws {
        guard ProcessInfo.processInfo.environment["PIXEL_INTEGRATION_TEST"] == "1" else { return }
        let client = try #require(ADBClient())
        _ = try await client.connect()
        let storage = try #require(try await client.storages().first)
        let rootItems = try await client.children(storageID: storage.id, parentID: 0)
        let dcim = try #require(rootItems.first(where: { $0.name == "DCIM" }))
        let dcimItems = try await client.children(storageID: storage.id, parentID: dcim.id)
        let camera = try #require(dcimItems.first(where: { $0.name == "Camera" }))
        let files = Array(try await client.children(storageID: storage.id, parentID: camera.id)
            .filter { !$0.isFolder && $0.size > 0 }
            .prefix(2))
        #expect(files.count == 2)

        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let engine = ImportEngine(client: client)
        let candidates = try await engine.expand(files)
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await engine.run(
            candidates: candidates,
            destination: destination,
            conflictResolver: { _ in .keepBoth },
            progress: { _ in }
        )
        let duration = start.duration(to: clock.now)

        #expect(result.importedFiles == 2)
        #expect(result.failures.isEmpty)
        for file in files {
            let imported = destination.appending(path: file.name)
            let size = try #require(try imported.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(UInt64(size) == file.size)
        }
        print("Android concurrent import: \(duration), files=\(files.map(\.name))")
    }
}
