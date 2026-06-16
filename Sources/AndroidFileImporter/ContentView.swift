import AppKit
import SwiftUI

struct AndroidFileImporterStateKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var androidFileImporterState: AppState? {
        get { self[AndroidFileImporterStateKey.self] }
        set { self[AndroidFileImporterStateKey.self] = newValue }
    }
}

struct ContentView: View {
    @State var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 560)
        .focusedSceneValue(\.androidFileImporterState, state)
        .task {
            if case .disconnected = state.connection { await state.connect() }
        }
        .sheet(item: $state.conflictRequest) { request in
            ConflictSheet(state: state, request: request)
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { state.selectedStorage?.id },
            set: { id in
                guard let id, let storage = state.storages.first(where: { $0.id == id }) else { return }
                Task { await state.selectStorage(storage) }
            }
        )) {
            Section("Device") {
                ForEach(state.storages) { storage in
                    Label(storage.name, systemImage: "internaldrive").tag(storage.id)
                }
            }
        }
        .navigationTitle("Android File Importer")
        .safeAreaInset(edge: .bottom) { connectionCard.padding(12) }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.connection {
        case .disconnected, .connecting:
            ContentUnavailableView("Connecting to Android Device", systemImage: "cable.connector", description: Text("Unlock the phone and approve USB debugging."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Android Device Not Available", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await state.connect() } }
            }
        case .connected:
            browser
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(state.path) { location in
                    Button(location.name) { Task { await state.navigate(to: location) } }
                        .buttonStyle(.plain)
                    if location.id != state.path.last?.id { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                }
                Spacer()
                if !state.items.isEmpty {
                    Text(selectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(state.allItemsSelected ? "Deselect All" : "Select All") {
                        state.allItemsSelected ? state.deselectAll() : state.selectAll()
                    }
                    if state.selectedFolder != nil {
                        Button("Open Folder") { Task { await state.openSelectedFolder() } }
                    }
                }
                Button(state.selection.isEmpty ? "Import" : "Import \(state.selection.count) Selected") {
                    Task { await state.chooseAndImport() }
                }
                    .disabled(state.selection.isEmpty || state.importProgress.isRunning)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            if state.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.items.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else {
                Table(state.items, selection: $state.selection) {
                    TableColumn("") { item in
                        Toggle("", isOn: Binding(
                            get: { state.selection.contains(item.id) },
                            set: { state.setSelection($0, for: item) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(state.selection.contains(item.id) ? "Deselect \(item.name)" : "Select \(item.name)")
                    }
                    .width(28)
                    TableColumn("Name") { item in
                        HStack {
                            ThumbnailView(client: state.client, item: item)
                            Text(item.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    TableColumn("Size") { item in
                        Text(item.isFolder ? "--" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .width(90)
                    TableColumn("Modified") { item in
                        Text(item.modificationDate, format: .dateTime.year().month().day())
                            .foregroundStyle(.secondary)
                    }
                    .width(110)
                }
            }

            if state.importProgress.isRunning || state.importProgress.failure != nil || state.importProgress.completedFiles > 0 {
                Divider()
                importBar.padding(12)
            }
        }
    }

    private var selectionSummary: String {
        state.selection.isEmpty ? "None selected" : "\(state.selection.count) selected"
    }

    private var importBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(importStatus)
                    .lineLimit(2)
                ProgressView(value: state.importProgress.fraction)
                Text("\(state.importProgress.completedFiles) of \(state.importProgress.totalFiles) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if state.importProgress.isRunning {
                Button("Cancel") { state.cancelImport() }
            } else if let destination = state.lastDestination {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
        }
    }

    private var importStatus: String {
        if let failure = state.importProgress.failure { return failure }
        if state.importProgress.isRunning {
            return state.importProgress.currentName.isEmpty
                ? "Preparing import"
                : "Importing \(state.importProgress.currentName)"
        }
        if state.importProgress.failedFiles > 0 {
            return "Import finished with \(state.importProgress.failedFiles) failed"
        }
        return "Import complete"
    }

    private var connectionCard: some View {
        HStack {
            Image(systemName: "cable.connector")
            VStack(alignment: .leading) {
                if case .connected(let device) = state.connection {
                    Text(device.name).font(.headline)
                    Text("USB connected").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No Android device connected").font(.headline)
                }
            }
            Spacer()
        }
    }
}

private struct ConflictSheet: View {
    let state: AppState
    let request: ConflictRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("File Already Exists", systemImage: "doc.on.doc")
                .font(.title2.bold())
            Text("A file named \(request.url.lastPathComponent) already exists in the destination.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("This file")
                    .font(.subheadline.weight(.medium))
                HStack {
                    Button("Skip") { state.answerConflict(.skip) }
                    Spacer()
                    Button("Keep Both") { state.answerConflict(.keepBoth) }
                    Button("Replace", role: .destructive) { state.answerConflict(.replace) }
                }
                Divider()
                Text("All remaining duplicates")
                    .font(.subheadline.weight(.medium))
                Button("Skip All Duplicates") {
                    state.answerConflict(.skip, applyToAll: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}

private struct ThumbnailView: View {
    let client: any MTPClient
    let item: MTPItem
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.isFolder ? "folder.fill" : "doc.fill").resizable().scaledToFit().padding(5)
                    .foregroundStyle(item.isFolder ? .blue : .secondary)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: item.id) {
            guard item.isPreviewable, let data = try? await client.thumbnail(for: item.id) else { return }
            image = NSImage(data: data)
        }
    }
}
