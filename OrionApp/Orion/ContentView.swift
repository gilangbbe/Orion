import OrionAgent
import OrionCodeIntel
import SwiftUI

/// Renders `RepositorySession.state`. `.task(id:)` below is what actually drives
/// `idle -> opening -> analyzing` into `.ready`/`.failed` for real (Docs/13 M2) -- the app-level
/// wiring `AnalysisRunner` itself deliberately doesn't do on its own.
struct ContentView: View {
    let session: RepositorySession
    @State private var isPresentingOpenSheet = false
    @State private var progressTracker = AnalysisProgressTracker()
    @State private var semanticSession = SemanticInvestigationSession()
    @State private var isPresentingBuildModelSheet = false
    @State private var isPresentingAskSheet = false

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 420)
            .toolbar {
                if case .ready = session.state {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isPresentingAskSheet = true
                        } label: {
                            Label("Ask…", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingOpenSheet = true
                    } label: {
                        Label("Open Repository…", systemImage: "folder.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingOpenSheet) {
                OpenRepositoryView(session: session)
            }
            .sheet(isPresented: $isPresentingBuildModelSheet) {
                if case .ready(let summary) = session.state {
                    BuildArchitectureModelSheet(
                        repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory,
                        session: semanticSession)
                }
            }
            .sheet(isPresented: $isPresentingAskSheet) {
                if case .ready(let summary) = session.state {
                    AskView(repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory)
                }
            }
            .task(id: session.state) {
                switch session.state {
                case .opening:
                    // A fresh repository attempt -- any previous repo's semantic investigation
                    // state is no longer relevant.
                    semanticSession = SemanticInvestigationSession()
                case .analyzing:
                    guard let repoRoot = session.resolvedRepoRoot else { return }
                    progressTracker = AnalysisProgressTracker()
                    await AnalysisRunner.run(
                        repoRoot: repoRoot, session: session, progress: progressTracker)
                default:
                    break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle:
            emptyState
        case .opening(let input):
            ProgressView(openingLabel(for: input))
        case .analyzing:
            AnalysisProgressView(
                repoRoot: session.resolvedRepoRoot ?? URL(fileURLWithPath: "/"),
                progress: progressTracker)
        case .ready(let summary):
            readyState(summary)
        case .failed(let message):
            errorState(message)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)  // decorative; the text below already says this
            Text("No repository open")
                .font(.title2)
            Text("Open a local checkout or a GitHub URL to build its Codebase Mental Model.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text(linkedLibrariesFooter)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 24)
        }
    }

    /// Docs/05 Stage 1's populated header (compact, once analysis finishes) above the
    /// Architecture Overview (Docs/13 M4) -- the real diagram is the primary content now; the
    /// repo stats collapse into a disclosure so the diagram gets the space it deserves.
    private func readyState(_ summary: RepositorySummary) -> some View {
        VStack(spacing: 0) {
            readyHeader(summary)
            Divider()
            ArchitectureOverviewView(
                repoRoot: summary.repoRoot, outputDirectory: summary.outputDirectory,
                semanticSession: semanticSession
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func readyHeader(_ summary: RepositorySummary) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.repoRoot.lastPathComponent).font(.headline)
                DisclosureGroup("\(summary.fileCount) files · \(summary.symbolCount) symbols · \(summary.relationshipCount) relationships") {
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent("Repository", value: summary.repoRoot.path)
                        LabeledContent("Languages", value: summary.languages.joined(separator: ", "))
                        LabeledContent("Resolver", value: summary.resolver)
                        if summary.resolver == "none" {
                            // Docs/06 §7 failure transparency: `resolver == "none"` in a real
                            // run always means SCIP (scip-python/npx) was unavailable, not a
                            // deliberate choice -- the app never passes --no-resolve itself.
                            // Calls/extends/implements simply don't exist without it; say so
                            // plainly rather than leaving a bare "none" for the user to puzzle
                            // over (Docs/13 M8).
                            Text(
                                "scip-python (Pyright) wasn't available, so call/extends/"
                                    + "implements edges weren't resolved. Symbols, imports, and "
                                    + "module structure are still complete."
                            )
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }
                        if summary.parseErrorCount > 0 {
                            LabeledContent("Parse errors", value: "\(summary.parseErrorCount)")
                                .foregroundStyle(.orange)
                        }
                        if summary.diagnosticCount > 0 {
                            LabeledContent("Diagnostics", value: "\(summary.diagnosticCount)")
                        }
                        LabeledContent(
                            "Analysis time", value: String(format: "%.0f ms", summary.totalDurationMs))
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            semanticInvestigationSection
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Docs/13 M3: the explicit, cost-gated "Build Architecture Model" action and its outcome --
    /// a compact summary now that the Architecture Overview (M4) actually renders the result
    /// below; `orion-index ingest-semantic`'s own CLI output reports the same counts.
    @ViewBuilder
    private var semanticInvestigationSection: some View {
        switch semanticSession.state {
        case .idle:
            Button("Build Architecture Model…") { isPresentingBuildModelSheet = true }
        case .investigating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Investigating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .completed(let summary):
            VStack(alignment: .trailing, spacing: 2) {
                Label(
                    "\(summary.componentCount) components: \(summary.outcome)",
                    systemImage: summary.outcome == "verified" ? "checkmark.seal.fill" : "exclamationmark.seal"
                )
                .font(.caption)
                .foregroundStyle(summary.outcome == "verified" ? .green : .orange)
                if let cost = summary.totalCostUsd {
                    Text("Cost: \(cost.formatted(.currency(code: "USD")))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Rebuild…") { isPresentingBuildModelSheet = true }
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                Label("Architecture model failed", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Try Again…") { isPresentingBuildModelSheet = true }
                    .controlSize(.small)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)  // decorative; the text below already says this
            Text("Couldn't open repository")
                .font(.title2)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try Again") {
                session.reset()
                isPresentingOpenSheet = true
            }
        }
    }

    private func openingLabel(for input: RepositorySession.Input) -> String {
        switch input {
        case .localPath: return "Opening…"
        case .gitHubURL: return "Cloning…"
        }
    }

    /// A real, side-effect-free reference into each linked library -- proof this target
    /// actually links `OrionCodeIntel` and `OrionAgent` (not just resolves the packages),
    /// without loading the MLX model or touching the network. Dropped once later milestones
    /// give the app more organic reasons to import both directly.
    private var linkedLibrariesFooter: String {
        let sample = DepthHeuristics.classify("What does AuthService do?")
        return
            "OrionCodeIntel \(OrionCodeIntel.version) · OrionAgent linked (sample depth: \(sample?.depth.description ?? "nil"))"
    }
}

#Preview {
    ContentView(session: RepositorySession())
}
