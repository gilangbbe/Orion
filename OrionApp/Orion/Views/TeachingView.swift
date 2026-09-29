import OrionAgent
import OrionCodeIntel
import SwiftUI

/// Docs/05_user_flow_and_ux.md Stage 7 / Docs/17_phase7_teaching_mode.md §11 — Teaching Mode's
/// real screen. A concept rail on the left (each concept with the developer's mastery of it,
/// ordered by `TeachingPlanner` rank) and a working pane on the right that runs Docs/05's loop —
/// Explain → Question → Your Answer → Evaluation → Correction → Transfer — for the selected
/// concept. The Evaluation section shows the *decomposed* grade: a point-by-point checklist with
/// the developer's own words quoted back, not a bare score (Docs/17 §2.1/§7, H7).
///
/// Same `HSplitView` master-detail shape as `AskView` (and the same reasons: `NavigationSplitView`
/// here would let the rail collapse away with no toolbar toggle to bring it back; `.inspector`'s
/// resize handle only shrinks on this SDK — both documented in `AskView` / `ContentView`).
struct TeachingView: View {
    let session: TeachingSession
    let repoRoot: URL
    let outputDirectory: URL

    @State private var filter = ""
    @State private var bandOverride: Int = 1
    @State private var selectedEvidence: EvidenceDetail?
    /// Core AI bundles the drafting and judging roles need that aren't exported yet (Docs/18 M6).
    @State private var missingModels: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if !missingModels.isEmpty {
                LocalModelSetupNotice(missing: missingModels, recheck: checkModels)
                    .padding(DesignTokens.Spacing.md)
            }
            HSplitView {
                conceptRail
                    .frame(minWidth: 268, idealWidth: 268, maxWidth: 268, maxHeight: .infinity)
                workPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            checkModels()
            await session.refresh(outputDirectory: outputDirectory)
        }
        .onChange(of: session.selectedConceptId) { _, newValue in
            if let id = newValue, let row = session.concepts.first(where: { $0.id == id }) {
                bandOverride = row.difficultyBand
            }
        }
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceView(repoRoot: repoRoot, evidence: evidence)
        }
    }

    // MARK: - Concept rail

    private var conceptRail: some View {
        VStack(spacing: 0) {
            TextField("Filter concepts…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            if session.concepts.isEmpty {
                railEmptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredConcepts) { conceptRow($0) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { railFooter }
    }

    private var filteredConcepts: [TeachingConceptRow] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return session.concepts }
        return session.concepts.filter { $0.label.lowercased().contains(q) }
    }

    private var railEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "graduationcap")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(
                session.loadError == nil
                    ? "No concepts yet — build an Architecture Model first, then Teaching Mode "
                        + "derives concepts from it."
                    : "Couldn't load concepts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error = session.loadError {
                Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func conceptRow(_ row: TeachingConceptRow) -> some View {
        Button {
            session.select(conceptId: row.id, outputDirectory: outputDirectory)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    Text(row.label)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if row.hasOpenMisconception {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.contradicted)
                            .accessibilityLabel("Open misconception")
                    }
                }
                HStack(spacing: 6) {
                    MasteryMeter(pMastered: row.pMastered, band: row.confidenceBand)
                    Text(kindWord(row.kind))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            row.id == session.selectedConceptId
                ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
    }

    private var railFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let next = session.concepts.first {
                Button {
                    Task {
                        await session.startNext(repoRoot: repoRoot, outputDirectory: outputDirectory)
                    }
                } label: {
                    Label("Start suggested concept", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(session.isGenerating)
                Text("Next: \(next.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Work pane

    private var workPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                    switch session.phase {
                    case .idle:
                        idlePane
                    case .picking(let conceptId):
                        conceptCard(conceptId)
                    case .questioning(let card):
                        questioningPane(card)
                    case .grading(let card):
                        gradingPane(card)
                    case .graded(let card, let grade):
                        gradedPane(card, grade).id("graded")
                    }
                }
                .padding(DesignTokens.Spacing.xxl)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: isGradedPhase) { _, graded in
                if graded { withAnimation { proxy.scrollTo("graded", anchor: .top) } }
            }
        }
        .safeAreaInset(edge: .top) {
            if !TeachingSession.isCalibrated { calibrationNote }
        }
    }

    private var isGradedPhase: Bool {
        if case .graded = session.phase { return true }
        return false
    }

    /// Docs/17 Decision 10 / §11 — while the grader hasn't been calibrated against expert review
    /// (Phase 7 M7), every verdict is framed as a self-check, and no mastery estimate is persisted.
    private var calibrationNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(
                "Self-check only. Teaching Mode's grading isn't calibrated against expert review "
                    + "yet — use the breakdown to reflect, not as a verdict. Your mastery isn't "
                    + "being scored.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var idlePane: some View {
        ContentUnavailableView {
            Label("Practice a concept", systemImage: "graduationcap")
        } description: {
            Text("Pick a concept on the left, or start the suggested one below it.")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: - Picking: the concept card

    @ViewBuilder
    private func conceptCard(_ conceptId: String) -> some View {
        if let row = session.concepts.first(where: { $0.id == conceptId }) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                GroupBox {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        HStack {
                            Text(kindWord(row.kind).uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(.tertiary)
                                .tracking(0.5)
                            Spacer()
                            MasteryMeter(
                                pMastered: row.pMastered, band: row.confidenceBand, showsLabel: true)
                        }
                        Text(row.label)
                            .font(.title3.weight(.semibold))
                        if row.attempts > 0 {
                            Text(masterySubtitle(row))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !row.openMisconceptions.isEmpty {
                            misconceptionPanel(row.openMisconceptions)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    eyebrow("Question depth")
                    Picker("Question depth", selection: $bandOverride) {
                        Text("Recall").tag(1)
                        Text("Comprehension").tag(2)
                        Text("Transfer").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(bandHint(bandOverride))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if session.isGenerating {
                    generatingRow(band: bandOverride)
                } else {
                    Button {
                        Task {
                            await session.getQuestion(
                                band: bandOverride, repoRoot: repoRoot,
                                outputDirectory: outputDirectory)
                        }
                    } label: {
                        Label("Get a question", systemImage: "text.badge.plus")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
                if let error = session.generateError { errorBanner(error) }
            }
        }
    }

    private func misconceptionPanel(_ statements: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("You've shown a misconception here", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(DesignTokens.contradicted)
            ForEach(statements, id: \.self) { s in
                Text("• \(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.contradicted.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    // MARK: - Questioning

    private func questioningPane(_ card: TeachingQuestionCard) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            questionHeader(card, compact: false)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                eyebrow("Your answer")
                answerEditor
                Text("You'll get a point-by-point breakdown of your answer, not just a score.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("Submit for review") {
                        Task { await session.submit(repoRoot: repoRoot, outputDirectory: outputDirectory) }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(session.answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Different question") {
                        Task {
                            await session.getQuestion(
                                band: card.band, repoRoot: repoRoot, outputDirectory: outputDirectory)
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(session.isGenerating)
                }
            }
            if let error = session.generateError { errorBanner(error) }
        }
    }

    private var answerEditor: some View {
        TextEditor(text: Binding(get: { session.answerDraft }, set: { session.answerDraft = $0 }))
            .font(.callout)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: 132)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                    .strokeBorder(Color(nsColor: .separatorColor)))
    }

    // MARK: - Grading (in progress)

    private func gradingPane(_ card: TeachingQuestionCard) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            questionHeader(card, compact: true)
            answerQuote(session.answerDraft)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    "Checking each point against the code. This runs the local model — a "
                        + "Comprehension or Transfer question can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Graded

    private func gradedPane(_ card: TeachingQuestionCard, _ grade: TeachingGradeCard) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            questionHeader(card, compact: true)
            answerQuote(session.answerDraft)

            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    verdictHeader(grade)
                    Divider()
                    criterionChecklist(grade.criteria)
                    if grade.disputed {
                        Label(
                            "The overall score and a same-idea check disagreed — re-read the "
                                + "reference answer below.",
                            systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !grade.misconceptionsDetected.isEmpty || !grade.misconceptionsCleared.isEmpty {
                misconceptionOutcome(grade)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                eyebrow("Correction")
                MarkdownText(raw: grade.correction)
                    .font(.callout)
            }

            if let after = grade.masteryAfter, let before = grade.masteryBefore,
               let bandAfter = grade.bandAfter {
                masteryMovedRow(before: before, after: after, band: bandAfter)
            }

            transferPanel(card, grade)
            if let error = session.generateError { errorBanner(error) }
        }
    }

    private func verdictHeader(_ grade: TeachingGradeCard) -> some View {
        let style = Self.verdictStyle(grade.verdict)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(style.label, systemImage: style.icon)
                    .font(.headline)
                    .foregroundStyle(style.color)
                Spacer()
                Text("\(grade.requiredMet) of \(grade.requiredTotal) key points")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Gauge(value: gaugeValue(grade)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(style.color)
            if grade.needsReviewCount > 0 {
                Text(
                    "\(grade.needsReviewCount) point(s) couldn't be graded confidently and were "
                        + "left out — check them yourself below.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func gaugeValue(_ grade: TeachingGradeCard) -> Double {
        grade.requiredTotal > 0 ? Double(grade.requiredMet) / Double(grade.requiredTotal) : 0
    }

    private func criterionChecklist(_ rows: [TeachingCriterionRow]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ForEach(rows.filter { $0.kind != .anti || $0.met }) { row in
                criterionRow(row)
            }
        }
    }

    @ViewBuilder
    private func criterionRow(_ row: TeachingCriterionRow) -> some View {
        let mark = Self.criterionMark(row)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mark.icon)
                .foregroundStyle(mark.color)
                .accessibilityLabel(mark.accessibility)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.text)
                        .font(.callout)
                        .foregroundStyle(row.kind == .anti ? DesignTokens.contradicted : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.kind == .bonus {
                        Text("bonus")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                    }
                }
                if row.needsReview {
                    Text("Not graded confidently — decide for yourself.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if row.met, !row.evidenceQuote.isEmpty {
                    Text("you wrote: “\(row.evidenceQuote)”")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.evidence.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(row.evidence) { evidence in
                            Button {
                                selectedEvidence = evidence
                            } label: {
                                Text(evidence.anchor)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func misconceptionOutcome(_ grade: TeachingGradeCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(grade.misconceptionsDetected, id: \.self) { s in
                Label {
                    Text("Your answer suggests: \(s)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(DesignTokens.contradicted)
            }
            ForEach(grade.misconceptionsCleared, id: \.self) { s in
                Label {
                    Text("Cleared up: \(s)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(DesignTokens.fact)
            }
        }
    }

    private func masteryMovedRow(before: Double, after: Double, band: String) -> some View {
        HStack(spacing: 8) {
            eyebrow("Mastery")
            MasteryMeter(pMastered: before, band: band, showsLabel: false)
                .opacity(0.5)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            MasteryMeter(pMastered: after, band: band, showsLabel: true)
        }
    }

    private func transferPanel(_ card: TeachingQuestionCard, _ grade: TeachingGradeCard) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let transfer = card.transferProblem, !transfer.isEmpty {
                eyebrow("Transfer problem")
                MarkdownText(raw: transfer)
                    .font(.callout)
            } else {
                eyebrow("Keep going")
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                if card.transferProblem?.isEmpty == false, card.band < 3 {
                    Button("Try this — one level up") {
                        Task {
                            await session.tryTransfer(
                                repoRoot: repoRoot, outputDirectory: outputDirectory)
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
                Button("Another question here") {
                    Task {
                        await session.anotherQuestion(
                            repoRoot: repoRoot, outputDirectory: outputDirectory)
                    }
                }
                .buttonStyle(.glass)
                Button("Next concept") {
                    Task {
                        await session.startNext(repoRoot: repoRoot, outputDirectory: outputDirectory)
                    }
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .disabled(session.isGenerating)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.accent.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    // MARK: - Shared pieces

    private func questionHeader(_ card: TeachingQuestionCard, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(spacing: 6) {
                Text(kindWord(card.conceptKind).uppercased() + " · " + bandWord(card.band).uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                Spacer()
                Text(card.conceptLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !compact {
                VStack(alignment: .leading, spacing: 4) {
                    eyebrow("Explain")
                    MarkdownText(raw: card.explain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                eyebrow("Question")
                MarkdownText(raw: card.prompt)
                    .font(compact ? .headline : .title3)
                    .fontWeight(.semibold)
            }
        }
    }

    private func answerQuote(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            eyebrow("Your answer")
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
    }

    private func generatingRow(band: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(
                band >= 3
                    ? "Writing a transfer question — this uses Claude and can take a minute or two."
                    : "Writing a question — the first one also loads the local Core AI model.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkModels() {
        missingModels = CoreAIModelLocator.missingVariants(for: .default, roles: [.drafting, .judging])
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.caption2)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(DesignTokens.accent)
            .tracking(0.5)
    }

    // MARK: - Vocabulary

    private func kindWord(_ raw: String) -> String {
        switch raw {
        case TeachingConceptKind.component.rawValue: return "Component"
        case TeachingConceptKind.claim.rawValue: return "Claim"
        case TeachingConceptKind.relationship.rawValue: return "Relationship"
        case TeachingConceptKind.role.rawValue: return "Role"
        case TeachingConceptKind.dataflow.rawValue: return "Data flow"
        default: return raw.capitalized
        }
    }

    private func bandWord(_ band: Int) -> String {
        switch band {
        case 1: return "Recall"
        case 2: return "Comprehension"
        default: return "Transfer"
        }
    }

    private func bandHint(_ band: Int) -> String {
        switch band {
        case 1: return "State or define what this is and does."
        case 2: return "Explain how it relates to or differs from a neighbour."
        default: return "What breaks if this changes? Uses Claude, costs a little."
        }
    }

    private func masterySubtitle(_ row: TeachingConceptRow) -> String {
        var parts = ["\(row.attempts) attempt\(row.attempts == 1 ? "" : "s")"]
        if let v = row.lastVerdict {
            parts.append("last: \(v.replacingOccurrences(of: "-", with: " "))")
        }
        return parts.joined(separator: " · ")
    }

    struct VerdictStyle { let label: String; let icon: String; let color: Color }

    static func verdictStyle(_ raw: String) -> VerdictStyle {
        switch raw {
        case TeachingVerdictTier.solid.rawValue:
            return VerdictStyle(label: "Solid", icon: "checkmark.seal.fill", color: DesignTokens.fact)
        case TeachingVerdictTier.partial.rawValue:
            return VerdictStyle(
                label: "Partial", icon: "circle.lefthalf.filled", color: DesignTokens.confidenceMedium)
        case TeachingVerdictTier.shaky.rawValue:
            return VerdictStyle(
                label: "Shaky", icon: "exclamationmark.circle", color: DesignTokens.confidenceLow)
        default:
            return VerdictStyle(
                label: "Off track", icon: "xmark.circle", color: DesignTokens.contradicted)
        }
    }

    struct CriterionMark { let icon: String; let color: Color; let accessibility: String }

    static func criterionMark(_ row: TeachingCriterionRow) -> CriterionMark {
        if row.kind == .anti {
            return CriterionMark(
                icon: "exclamationmark.triangle.fill", color: DesignTokens.contradicted,
                accessibility: "Misconception")
        }
        if row.needsReview {
            return CriterionMark(
                icon: "minus.circle", color: .secondary, accessibility: "Needs your review")
        }
        return row.met
            ? CriterionMark(icon: "checkmark.circle.fill", color: DesignTokens.fact, accessibility: "Met")
            : CriterionMark(icon: "xmark.circle", color: .secondary, accessibility: "Not met")
    }
}
