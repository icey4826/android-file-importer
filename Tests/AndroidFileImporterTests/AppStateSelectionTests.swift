import Foundation
import Testing
@testable import AndroidFileImporter

@MainActor
@Suite("Browser selection")
struct AppStateSelectionTests {
    @Test("Select all and deselect all operate on the visible folder")
    func selectAll() {
        let state = AppState(client: FakeMTPClient())
        state.items = [item(id: 1), item(id: 2), item(id: 3)]

        state.selectAll()
        #expect(state.selection == [1, 2, 3])
        #expect(state.allItemsSelected)

        state.deselectAll()
        #expect(state.selection.isEmpty)
        #expect(!state.allItemsSelected)
    }

    @Test("Checkbox toggles one item without clearing existing selection")
    func toggle() {
        let state = AppState(client: FakeMTPClient())
        let first = item(id: 1)
        let second = item(id: 2)
        state.items = [first, second]
        state.selection = [first.id]

        state.toggleSelection(for: second)
        #expect(state.selection == [first.id, second.id])

        state.toggleSelection(for: first)
        #expect(state.selection == [second.id])
    }

    @Test("Checkbox binding sets an explicit selection state")
    func setSelection() {
        let state = AppState(client: FakeMTPClient())
        let first = item(id: 1)
        let second = item(id: 2)
        state.items = [first, second]
        state.selection = [first.id]

        state.setSelection(true, for: second)
        state.setSelection(true, for: second)
        #expect(state.selection == [first.id, second.id])

        state.setSelection(false, for: first)
        state.setSelection(false, for: first)
        #expect(state.selection == [second.id])
    }

    @Test("Open folder is available only for one selected folder")
    func selectedFolder() {
        let state = AppState(client: FakeMTPClient())
        let folder = item(id: 1, isFolder: true)
        let file = item(id: 2)
        state.items = [folder, file]

        state.selection = [folder.id]
        #expect(state.selectedFolder == folder)

        state.selection = [folder.id, file.id]
        #expect(state.selectedFolder == nil)
    }

    private func item(id: UInt32, isFolder: Bool = false) -> MTPItem {
        MTPItem(
            id: id,
            parentID: 0,
            storageID: 1,
            name: "Item \(id)",
            size: 0,
            modificationDate: .distantPast,
            isFolder: isFolder
        )
    }
}
