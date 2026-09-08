import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.2/§8 M2: the actual open-a-repository form -- Local
/// Folder/GitHub URL tabs, the picker/field, and a Recents list -- shared verbatim between
/// `WelcomeView`'s embedded card (Docs/05 Stage 1's entry point) and `OpenRepositoryView` below,
/// which now only wraps this for the "Open Another Repository" sheet shown from an already-`.ready`
/// session (Docs/13_phase4_architecture_ui.md Decision 2's original sheet, since M1 moved its
/// trigger from the toolbar into the sidebar). `onWillOpen` lets a sheet host dismiss itself right
/// before `RepositorySession.open(_:)` fires; `WelcomeView` passes the default no-op since there's
/// nothing to dismiss when the form is embedded directly in the window.
struct OpenRepositoryForm: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case localFolder = "Local Folder"
        case gitHubURL = "GitHub URL"
        var id: String { rawValue }
    }

    let session: RepositorySession
    var onWillOpen: () -> Void = {}
    private let recents: RecentRepositories

    @State private var mode: Mode = .localFolder
    @State private var urlText: String = ""
    @State private var isPickingFolder = false
    @State private var validationError: String?
    @State private var recentEntries: [RecentRepositoryEntry] = []

    init(
        session: RepositorySession, onWillOpen: @escaping () -> Void = {},
        recents: RecentRepositories = RecentRepositories()
    ) {
        self.session = session
        self.onWillOpen = onWillOpen
        self.recents = recents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
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
                        .buttonStyle(.glassProminent)
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
                // A bounded height, not just `.listStyle(.plain)`, matters here specifically
                // because `WelcomeView` embeds this form inside its own `ScrollView` -- a `List`
                // nested in a `ScrollView` with no explicit height silently collapses to near-zero
                // instead of showing its rows (a real bug caught visually, not assumed away: it
                // rendered as an empty "Recent" section with nothing under it).
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
                .frame(minHeight: 120, maxHeight: 240)
            }
        }
        .onAppear { recentEntries = recents.load() }
    }

    private func openLocalPath(_ url: URL) {
        validationError = nil
        recents.recordOpened(input: url.path, displayName: url.lastPathComponent)
        onWillOpen()
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
        onWillOpen()
        Task { await session.open(.gitHubURL(url)) }
    }

    private func reopen(_ entry: RecentRepositoryEntry) {
        onWillOpen()
        if let url = URL(string: entry.input), url.scheme?.lowercased() == "https" {
            Task { await session.open(.gitHubURL(url)) }
        } else {
            Task { await session.open(.localPath(URL(fileURLWithPath: entry.input))) }
        }
    }
}

/// The "Open Another Repository" sheet, shown only from an already-`.ready` session (M1's sidebar
/// footer) -- `WelcomeView` is what a repository-less session shows now, so this is no longer
/// Docs/05 Stage 1's own first screen, just a modal re-entry point. Thin chrome around
/// `OpenRepositoryForm`, dismissing itself right before a new open begins.
struct OpenRepositoryView: View {
    @Environment(\.dismiss) private var dismiss
    let session: RepositorySession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Repository").font(.title2.bold())
            OpenRepositoryForm(session: session, onWillOpen: { dismiss() })
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
    }
}
