import SwiftUI

/// Docs/13_phase4_architecture_ui.md Decision 2's sheet: a local folder or a GitHub URL, plus a
/// recents list for quick reopen. Purely input collection -- `RepositorySession.open(_:)` does
/// the real work, so this view has nothing to unit-test beyond what's already covered by
/// `RepositorySessionTests`/`RepositoryClonerTests`; correctness here is verified manually
/// (Docs/13 "Testing & verification").
struct OpenRepositoryView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case localFolder = "Local Folder"
        case gitHubURL = "GitHub URL"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let session: RepositorySession
    private let recents: RecentRepositories

    @State private var mode: Mode = .localFolder
    @State private var urlText: String = ""
    @State private var isPickingFolder = false
    @State private var validationError: String?
    @State private var recentEntries: [RecentRepositoryEntry] = []

    init(session: RepositorySession, recents: RecentRepositories = RecentRepositories()) {
        self.session = session
        self.recents = recents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Repository").font(.title2.bold())

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .localFolder:
                Button {
                    isPickingFolder = true
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) {
                    result in
                    switch result {
                    case .success(let url): openLocalPath(url)
                    case .failure(let error): validationError = "\(error)"
                    }
                }
            case .gitHubURL:
                HStack {
                    TextField("https://github.com/owner/repo", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(openGitHubURL)
                    Button("Clone", action: openGitHubURL)
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Public HTTPS URLs only in this version -- no private repositories yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationError {
                Text(validationError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if !recentEntries.isEmpty {
                Divider()
                Text("Recent").font(.headline)
                List(recentEntries) { entry in
                    Button {
                        reopen(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                            Text(entry.input)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { recentEntries = recents.load() }
    }

    private func openLocalPath(_ url: URL) {
        validationError = nil
        recents.recordOpened(input: url.path, displayName: url.lastPathComponent)
        dismiss()
        Task { await session.open(.localPath(url)) }
    }

    private func openGitHubURL() {
        validationError = nil
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty
        else {
            validationError = "Enter a valid https:// GitHub URL."
            return
        }
        recents.recordOpened(input: trimmed, displayName: url.lastPathComponent)
        dismiss()
        Task { await session.open(.gitHubURL(url)) }
    }

    private func reopen(_ entry: RecentRepositoryEntry) {
        dismiss()
        if let url = URL(string: entry.input), url.scheme?.lowercased() == "https" {
            Task { await session.open(.gitHubURL(url)) }
        } else {
            Task { await session.open(.localPath(URL(fileURLWithPath: entry.input))) }
        }
    }
}
