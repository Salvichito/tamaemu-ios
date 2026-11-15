import SwiftUI
import TamaCore
import UniformTypeIdentifiers

/// Downloadable content for one Tama: what's in each of its download
/// slots, adding more from files, and clearing slots out. The color Tamas
/// that had downloads (iD, iD L, P's, 4U) keep them in a small, fixed
/// number of slots per kind of content, so "remove" matters as much as
/// "add" -- a full category takes nothing new until one is cleared.
struct DownloadsView: View {
    let device: TamaDevice
    let viewModel: PlayViewModel

    @State private var categories: [DownloadCategory] = []
    @State private var showingPicker = false
    @State private var results: [DownloadInstallResult]?
    @State private var pendingRemoval: DownloadSlot?

    private var canChange: Bool { viewModel.canChangeDownloads }

    var body: some View {
        List {
            Section {
                Button {
                    showingPicker = true
                } label: {
                    Label("Add Downloads…", systemImage: "square.and.arrow.down")
                }
                .disabled(!canChange)
            } footer: {
                if canChange {
                    Text("Choose download files (.jpg or .bin) made for the \(device.title). For a set that comes in several parts, select all the parts together. \(device.title) is backed up first.")
                } else {
                    Text("\(device.title) is paused. Resume it to add or remove downloads.")
                }
            }

            ForEach(categories) { category in
                Section {
                    // Only what's actually installed gets a row; the free
                    // slots are one summary line, not twenty blank ones.
                    ForEach(category.slots.filter(\.isOccupied)) { slot in
                        DownloadRow(slot: slot)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canChange {
                                    Button("Remove", role: .destructive) { pendingRemoval = slot }
                                }
                            }
                            .contextMenu {
                                if canChange {
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        pendingRemoval = slot
                                    }
                                }
                            }
                    }
                    Text(freeSlotsText(category))
                        .foregroundStyle(.secondary)
                } header: {
                    HStack {
                        Text(category.label)
                        Spacer()
                        Text("\(category.usedCount) of \(category.slots.count)")
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.jpeg, .data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            results = viewModel.installDownloads(from: urls)
            reload()
        }
        .sheet(isPresented: Binding(get: { results != nil }, set: { if !$0 { results = nil } })) {
            DownloadResultsView(results: results ?? []) { results = nil }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "this download")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { slot in
            Button("Remove", role: .destructive) {
                viewModel.removeDownload(slot)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's erased from \(device.title) and its slot becomes free. \(device.title) is backed up first, and you can add it again from its file.")
        }
    }

    private func reload() {
        categories = viewModel.downloadCategories()
    }

    private func freeSlotsText(_ category: DownloadCategory) -> String {
        let free = category.slots.count - category.usedCount
        switch free {
        case 0: return "Full — remove one to add another"
        case 1: return "1 free slot"
        default: return "\(free) free slots"
        }
    }
}

private struct DownloadRow: View {
    let slot: DownloadSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(slot.displayName)
            // The original (usually Japanese) name under a known English
            // one, so either can be matched against the Tama's own screen.
            if slot.englishName != nil, !slot.name.isEmpty, slot.name != slot.displayName {
                Text(slot.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// What happened to each file after "Add Downloads…".
private struct DownloadResultsView: View {
    let results: [DownloadInstallResult]
    var onDone: () -> Void

    private var installed: [DownloadInstallResult] { results.filter(\.succeeded) }
    private var failed: [DownloadInstallResult] { results.filter { !$0.succeeded } }

    var body: some View {
        NavigationStack {
            List {
                if !installed.isEmpty {
                    Section("Added") {
                        ForEach(installed) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.itemName.isEmpty ? r.fileName : r.itemName)
                                if let label = r.categoryLabel {
                                    Text(label)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !failed.isEmpty {
                    Section("Not added") {
                        ForEach(failed) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.itemName.isEmpty ? r.fileName : r.itemName)
                                Text(r.failure ?? "")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        if failed.isEmpty { return installed.count == 1 ? "Download Added" : "\(installed.count) Downloads Added" }
        if installed.isEmpty { return "Nothing Added" }
        return "\(installed.count) of \(results.count) Added"
    }
}
