import OrionCore
import SwiftUI
import UniformTypeIdentifiers

/// The repositories on this device (Docs/19 M4, redesigned in M8). Choosing one opens it in
/// Explore; any tab's title menu switches between them too.
struct LibraryView: View {
    @Bindable var library: LibraryModel
    let cloud: CloudSync
    /// Called after the user picks a repository, so the shell can switch to Explore.
    let onOpen: () -> Void

    @State private var isPickingFile = false
    /// The M0 probe re-run path (`FM_PROBE_AUTORUN=1`, Docs/19 M0) opens it at launch.
    @State private var showingDiagnostics = ProcessInfo.processInfo.environment["FM_PROBE_AUTORUN"] == "1"
    @State private var pendingRemoval: LocalLibrary.Entry?
    @State private var showingBench = false
    @State private var showingLearnBench = false

    var body: some View {
        NavigationStack {
            List {
                if !library.entries.isEmpty {
                    Section {
                        CloudStatusRow(cloud: cloud)
                    }
                    Section {
                        ForEach(library.entries, id: \.libraryKey) { entry in
                            LibraryRepositoryRow(
                                entry: entry, isOpen: entry.libraryKey == library.selectedKey,
                                noLongerSynced: library.noLongerSynced.contains(entry.libraryKey),
                                open: { open(entry) }, remove: { pendingRemoval = entry })
                        }
                    } footer: {
                        Text("Knowledge comes from Orion on your Mac. What you learn and ask here stays on this device.")
                    }
                }
            }
            .overlay {
                if library.entries.isEmpty {
                    LibraryEmptyState(noAccount: cloud.account == .noAccount) { isPickingFile = true }
                }
            }
            .refreshable { await cloud.refresh() }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Import Snapshot…", systemImage: "square.and.arrow.down") { isPickingFile = true }
                        Section("Developer") {
                            Button("On-Device Model…", systemImage: "cpu") { showingDiagnostics = true }
                            Button("Ask Benchmark…", systemImage: "gauge.with.dots.needle.33percent") { showingBench = true }
                                .disabled(library.selected == nil)
                            Button("Learn Benchmark…", systemImage: "checklist") { showingLearnBench = true }
                                .disabled(library.selected == nil)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message = library.message {
                    LibraryMessageBar(message: message) { library.dismissMessage() }
                }
            }
            .overlay {
                if library.isImporting {
                    ProgressView("Importing…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: DesignTokens.Radius.panel))
                }
            }
            .confirmationDialog(
                "Remove \(pendingRemoval?.manifest.repositoryName ?? "")?", isPresented: removalBinding,
                titleVisibility: .visible, presenting: pendingRemoval
            ) { entry in
                Button("Remove from This iPhone", role: .destructive) { library.remove(entry) }
            } message: { _ in
                Text("Your answers, progress and questions about it on this device are deleted too. Orion on your Mac keeps its own copy.")
            }
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.data, .item], onCompletion: importPicked)
        .sheet(isPresented: $showingDiagnostics) {
            ProbeView()
        }
        .sheet(isPresented: $showingBench) {
            if let entry = library.selected {
                AskBenchView(entry: entry, ids: nil, forcedDepth: nil)
            }
        }
        .sheet(isPresented: $showingLearnBench) {
            if let entry = library.selected {
                LearnBenchView(entry: entry, request: LearnBench.Request())
            }
        }
    }

    private func open(_ entry: LocalLibrary.Entry) {
        library.selectedKey = entry.libraryKey
        onOpen()
    }

    private func importPicked(_ result: Result<URL, any Error>) {
        if case .success(let url) = result {
            Task { await library.importPickedFile(url) }
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    static func commitLabel(_ commit: String) -> String {
        commit == "unversioned" ? "unversioned" : "commit \(commit.prefix(8))"
    }

    static func dateLabel(_ iso: String) -> String {
        guard let date = try? Date(iso, strategy: .iso8601) else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Files, concepts and claims. Not components: the snapshot counts every investigation's, so
    /// Starlette said 33 while its architecture model has 11 (Docs/19 M8).
    static func contentsLabel(_ counts: KnowledgeSnapshotManifest.Counts) -> String {
        var parts = ["\(counts.files) files"]
        if counts.teachingConcepts > 0 { parts.append("\(counts.teachingConcepts) concepts") }
        if counts.claims > 0 { parts.append("\(counts.claims) claims") }
        return parts.joined(separator: " · ")
    }
}
