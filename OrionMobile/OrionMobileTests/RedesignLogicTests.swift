import OrionCore
import XCTest

@testable import Orion

/// Docs/19 M8: the redesign's logic, without rendering -- search, grouping, wording and the
/// starter questions.
@MainActor
final class RedesignLogicTests: XCTestCase {
    private func node(_ id: String, _ name: String, size: Int = 1, subtitle: String? = nil, tier: String? = "high") -> ArchitectureNode {
        ArchitectureNode(id: id, name: name, subtitle: subtitle, size: size, confidenceTier: tier, epistemicType: "INTERPRETATION")
    }

    // MARK: - Explore

    func testComponentSearchMatchesNameOrPurposeIgnoringCaseAndDiacritics() {
        let nodes = [
            node("a", "Routing & Endpoint Dispatch", subtitle: "Matches a path to a handler."),
            node("b", "Exception Handling", subtitle: "Turns errors into responses."),
        ]
        XCTAssertEqual(ExploreHomeList.filter(nodes, by: "rout").map(\.id), ["a"])
        XCTAssertEqual(ExploreHomeList.filter(nodes, by: "RESPONSES").map(\.id), ["b"])
        XCTAssertEqual(ExploreHomeList.filter(nodes, by: "  ").map(\.id), ["a", "b"], "blank shows everything")
    }

    func testConfidenceIsShownOnlyWhenNotHigh() {
        XCTAssertFalse(ConfidenceNote.isWorthShowing("high"))
        XCTAssertFalse(ConfidenceNote.isWorthShowing(nil))
        XCTAssertTrue(ConfidenceNote.isWorthShowing("medium"))
        XCTAssertEqual(ConfidenceNote.text("low"), "Low confidence")
        XCTAssertEqual(ConfidenceNote.text("unresolved"), "Unresolved")
    }

    func testMembersAreGroupedByKindClassesFirst() {
        func member(_ name: String, _ kind: String) -> ComponentMemberDetail {
            ComponentMemberDetail(id: name, anchor: "m.py::\(name)", name: name, kind: kind, startLine: 1, endLine: 2)
        }
        let groups = ComponentDetailList.memberGroups([
            member("helper", "function"), member("Router", "class"), member("app", "module"), member("Route", "class"),
        ])
        XCTAssertEqual(groups.map(\.title), ["Classes", "Functions", "Modules"])
        XCTAssertEqual(groups[0].members.map(\.name), ["Route", "Router"])
    }

    func testRelationshipsReadAsPlainWords() {
        XCTAssertEqual(RelationshipRow.verb("depends_on"), "Depends on")
        XCTAssertEqual(RelationshipRow.verb("calls"), "Calls")
    }

    func testModelChangeSymbolsFollowTheKindOfChange() {
        XCTAssertEqual(ModelChangeRow.symbol(for: "Claim added"), "plus.circle")
        XCTAssertEqual(ModelChangeRow.symbol(for: "Open question no longer raised"), "checkmark.circle")
        XCTAssertEqual(ModelChangeRow.symbol(for: "Open question raised"), "questionmark.circle")
        XCTAssertEqual(ModelChangeRow.symbol(for: "Something else"), "clock.arrow.circlepath")
    }

    func testEvidenceSheetTitlesTheSymbolAndSubtitlesItsPlace() {
        XCTAssertEqual(EvidenceSheet.title("pkg/app.py::Router.add_route"), "Router.add_route")
        XCTAssertEqual(EvidenceSheet.title("pkg/app.py"), "app.py")
        XCTAssertEqual(
            EvidenceSheet.subtitle(EvidenceDetail(id: "e", anchor: "pkg/app.py::Router", startLine: 20, endLine: 50)),
            "pkg/app.py · lines 20–50")
        XCTAssertEqual(
            EvidenceSheet.subtitle(EvidenceDetail(id: "e", anchor: "pkg/app.py::x", startLine: 7, endLine: 7)),
            "pkg/app.py · line 7")
    }

    func testLibraryCountsLeaveOutComponents() {
        let counts = KnowledgeSnapshotManifest.Counts(
            files: 135, symbols: 1, relationships: 0, components: 33, claims: 108, evidence: 1, modelRevisions: 0,
            teachingConcepts: 60, teachingQuestions: 0, snippets: 1, snippetsSkipped: 0)
        XCTAssertEqual(LibraryView.contentsLabel(counts), "135 files · 60 concepts · 108 claims")
    }

    // MARK: - Ask

    func testStarterQuestionsComeFromTheArchitecture() {
        let model = ArchitectureModel(
            layer: .semantic(investigationId: "i", componentCount: 2, investigatedAt: nil),
            nodes: [node("a", "Routing", size: 9), node("b", "Middleware", size: 3)],
            edges: [ArchitectureEdge(id: "e", sourceId: "b", targetId: "a", type: "depends_on", confidenceTier: "high")],
            uncertainties: [])
        XCTAssertEqual(
            AskSuggestions.make(model: model),
            ["What are the main parts of this codebase?", "What does Routing do?", "How does Middleware use Routing?"])
        XCTAssertEqual(AskSuggestions.make(component: "Routing").first, "What does Routing do?")
        XCTAssertEqual(AskSuggestions.make(model: nil).count, 2, "generic questions without an architecture model")
    }

    // MARK: - Learn

    func testConceptsAreGroupedByKindInPlannerOrder() {
        func row(_ id: String, _ kind: String) -> TeachingConceptRow {
            TeachingConceptRow(
                id: id, label: id, kind: kind, difficultyBand: 1, centrality: 0, pMastered: 0.15, confidenceBand: "new",
                attempts: 0, lastVerdict: nil, openMisconceptions: [], plannerScore: 0)
        }
        let sections = LearnConceptList.sections([row("c1", "claim"), row("k1", "component"), row("c2", "claim")])
        XCTAssertEqual(sections.map(\.kind), ["claim", "component"], "a group is ordered by its best-ranked concept")
        XCTAssertEqual(sections[0].rows.map(\.id), ["c1", "c2"])
        XCTAssertEqual(LearnConceptList.sectionTitle("relationship"), "Relationships")
    }
}
