import SwiftUI

@main
struct AndroidFileImporterApp: App {
    var body: some Scene {
        WindowGroup {
            if let client = ADBClient() {
                ContentView(state: AppState(client: client))
            } else {
                ContentUnavailableView("ADB Unavailable", systemImage: "xmark.circle", description: Text("Run scripts/bootstrap-mtp.sh first."))
            }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            SelectionCommands()
        }
    }
}

private struct SelectionCommands: Commands {
    @FocusedValue(\.androidFileImporterState) private var state

    var body: some Commands {
        CommandMenu("Selection") {
            Button("Select All") { state?.selectAll() }
                .disabled(state?.items.isEmpty != false)
            Button("Deselect All") { state?.deselectAll() }
                .disabled(state?.selection.isEmpty != false)
            Divider()
            Button("Open Selected Folder") {
                guard let state else { return }
                Task { await state.openSelectedFolder() }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(state?.selectedFolder == nil)
        }
    }
}
