import AppKit
import Foundation
import Observation

struct BrowserLocation: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

struct ConflictRequest: Identifiable {
    let id = UUID()
    let url: URL
    let continuation: CheckedContinuation<ConflictChoice, Never>
}

@MainActor
@Observable
final class AppState {
    let client: any MTPClient
    let importer: ImportEngine

    var connection: ConnectionState = .disconnected
    var storages: [MTPStorageInfo] = []
    var selectedStorage: MTPStorageInfo?
    var items: [MTPItem] = []
    var selection: Set<UInt32> = []
    var path: [BrowserLocation] = []
    var isLoading = false
    var importProgress = ImportProgress()
    var conflictRequest: ConflictRequest?
    private var conflictAutoChoice: ConflictChoice?
    var lastDestination: URL?

    var selectedItems: [MTPItem] { items.filter { selection.contains($0.id) } }
    var selectedFolder: MTPItem? {
        guard selectedItems.count == 1, selectedItems[0].isFolder else { return nil }
        return selectedItems[0]
    }
    var allItemsSelected: Bool { !items.isEmpty && selection.count == items.count }

    init(client: any MTPClient) {
        self.client = client
        self.importer = ImportEngine(client: client)
    }

    func connect() async {
        connection = .connecting
        do {
            let device = try await client.connect()
            let values = try await client.storages()
            connection = .connected(device)
            storages = values
            if let first = values.first { await selectStorage(first) }
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func selectStorage(_ storage: MTPStorageInfo) async {
        selectedStorage = storage
        path = [BrowserLocation(id: 0, name: storage.name)]
        await load(parentID: 0)
    }

    func open(_ item: MTPItem) async {
        guard item.isFolder else { return }
        path.append(BrowserLocation(id: item.id, name: item.name))
        await load(parentID: item.id)
    }

    func navigate(to location: BrowserLocation) async {
        guard let index = path.firstIndex(of: location) else { return }
        path.removeSubrange(path.index(after: index)..<path.endIndex)
        await load(parentID: location.id)
    }

    func chooseAndImport() async {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Here"
        if let lastDestination { panel.directoryURL = lastDestination }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        lastDestination = destination
        conflictAutoChoice = nil
        importProgress = ImportProgress(isRunning: true)

        do {
            let candidates = try await importer.expand(selected)
            let result = try await importer.run(
                candidates: candidates,
                destination: destination,
                conflictResolver: { [weak self] url in
                    guard let self else { return .keepBoth }
                    return await self.resolveConflict(at: url)
                },
                progress: { [weak self] value in
                    Task { @MainActor in self?.importProgress = value }
                }
            )
            selection = result.failedSelectionIDs
            if let first = result.failures.first {
                let count = result.failures.count
                importProgress.failure = count == 1
                    ? "Couldn't import \(first.name): \(first.message)"
                    : "Couldn't import \(count) files. First error: \(first.name): \(first.message)"
            }
        } catch is CancellationError {
            importProgress.isRunning = false
            importProgress.failure = "Import cancelled."
        } catch {
            importProgress.isRunning = false
            importProgress.failure = error.localizedDescription
        }
    }

    func cancelImport() { Task { await importer.cancel() } }

    func selectAll() { selection = Set(items.map(\.id)) }

    func deselectAll() { selection.removeAll() }

    func toggleSelection(for item: MTPItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func setSelection(_ selected: Bool, for item: MTPItem) {
        if selected {
            selection.insert(item.id)
        } else {
            selection.remove(item.id)
        }
    }

    func openSelectedFolder() async {
        guard let selectedFolder else { return }
        await open(selectedFolder)
    }

    func answerConflict(_ choice: ConflictChoice, applyToAll: Bool = false) {
        guard let request = conflictRequest else { return }
        if applyToAll { conflictAutoChoice = choice }
        conflictRequest = nil
        request.continuation.resume(returning: choice)
    }

    private func load(parentID: UInt32) async {
        guard let storage = selectedStorage else { return }
        isLoading = true
        selection.removeAll()
        defer { isLoading = false }
        do {
            items = try await client.children(storageID: storage.id, parentID: parentID)
        } catch {
            connection = .failed(error.localizedDescription)
            items = []
        }
    }

    private func resolveConflict(at url: URL) async -> ConflictChoice {
        if let conflictAutoChoice { return conflictAutoChoice }
        return await withCheckedContinuation { continuation in
            conflictRequest = ConflictRequest(url: url, continuation: continuation)
        }
    }
}
