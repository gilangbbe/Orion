import XCTest

@testable import OrionAgent

final class LocalModelBackendTests: XCTestCase {
    func testParsing() throws {
        XCTAssertEqual(try LocalModelBackend(parsing: " CoreAI "), .coreAI(variant: "qwen3-8b-4bit"))
        XCTAssertEqual(try LocalModelBackend(parsing: "coreai:qwen3-4b-4bit"), .coreAI(variant: "qwen3-4b-4bit"))
        XCTAssertThrowsError(try LocalModelBackend(parsing: "coreai:"))
        XCTAssertThrowsError(try LocalModelBackend(parsing: "gguf"))
    }

    /// Docs/18 M6: MLX is gone; asking for it says so instead of "unknown backend".
    func testMLXIsRejectedWithTheRemovalReason() {
        XCTAssertThrowsError(try LocalModelBackend(parsing: "mlx")) { error in
            XCTAssertTrue(
                (error as? LocalModelBackend.ParseError)?.errorDescription?.contains("removed") ?? false, "\(error)")
        }
    }

    /// Docs/19 M1: the on-device system model as a backend.
    func testSystemBackend() throws {
        XCTAssertEqual(try LocalModelBackend(parsing: " System "), .system)
        XCTAssertEqual(
            try LocalModelBackend.fromEnvironment([LocalModelBackend.environmentKey: "system"]), .system)
        XCTAssertTrue(LocalModelBackend.system.modelIdentifier.hasPrefix("system:"))
        // One model: no variants, and no reasoning mode to switch -- every role resolves to it as-is,
        // whatever `ORION_LOCAL_ROLES` says.
        let roles = try LocalModelRoles(parsing: "*=qwen3-4b-4bit:off")
        for role in LocalModelRole.allCases {
            XCTAssertEqual(
                LocalModelBackend.system.resolved(for: role, roles: roles),
                ResolvedLocalModel(backend: .system, reasoning: .on))
        }
        // Nothing to export.
        XCTAssertEqual(CoreAIModelLocator.missingVariants(for: .system, roles: LocalModelRole.allCases), [])
    }

    func testTheMacDefaultIsCoreAI() {
        XCTAssertEqual(LocalModelBackend.platformDefault, .defaultCoreAI)
    }

    func testSystemBackendNeedsNoLoad() async throws {
        let model = try await LocalModelLoader.shared.model(for: .system, role: .judging)
        XCTAssertEqual(model.modelIdentifier, LocalModelBackend.system.modelIdentifier)
        XCTAssertTrue(model is any NativeToolCallingModel)
        XCTAssertTrue(model is any GuidedGenerating)
    }

    func testDefaultIsTheDefaultCoreAIBundle() {
        XCTAssertEqual(LocalModelBackend.defaultCoreAI, .coreAI(variant: CoreAIModelLocator.defaultVariant))
    }

    func testEnvironment() throws {
        XCTAssertNil(try LocalModelBackend.fromEnvironment([:]))
        XCTAssertEqual(
            try LocalModelBackend.fromEnvironment([LocalModelBackend.environmentKey: "coreai"]),
            .coreAI(variant: "qwen3-8b-4bit"))
        XCTAssertThrowsError(try LocalModelBackend.fromEnvironment([LocalModelBackend.environmentKey: "typo"]))
    }

    func testIdentifiersMatchWhatTheLoadedModelsReport() {
        XCTAssertEqual(LocalModelBackend.coreAI(variant: "qwen3-8b-4bit").modelIdentifier, "coreai:qwen3-8b-4bit")
    }

    func testMissingCoreAIBundleFailsWithTheExportCommand() async {
        do {
            _ = try await LocalModelLoader.shared.model(for: .coreAI(variant: "no-such-model-4bit"))
            XCTFail("expected a missing-bundle error")
        } catch {
            XCTAssertEqual(
                error as? CoreAIModelLocator.LocatorError,
                .bundleNotFound(
                    CoreAIModelLocator.rootDirectory().appendingPathComponent("no-such-model-4bit", isDirectory: true),
                    variant: "no-such-model-4bit"))
        }
    }
}

/// Docs/18 M4: the per-role model table.
final class LocalModelRolesTests: XCTestCase {
    func testWildcardAppliesToEveryRoleNotNamedOtherwise() throws {
        let roles = try LocalModelRoles(parsing: "*=qwen3-4b-4bit:off, answering=qwen3-8b-4bit")
        XCTAssertEqual(roles.setting(for: .answering), LocalModelSetting(variant: "qwen3-8b-4bit", reasoning: .on))
        XCTAssertEqual(roles.setting(for: .judging), LocalModelSetting(variant: "qwen3-4b-4bit", reasoning: .off))
        XCTAssertEqual(roles.setting(for: .comparing), LocalModelSetting(variant: "qwen3-4b-4bit", reasoning: .off))
    }

    func testSettingForms() throws {
        let roles = try LocalModelRoles(parsing: "judging=off,drafting=qwen3-4b-4bit,comparing=:off")
        XCTAssertEqual(roles.setting(for: .judging), LocalModelSetting(reasoning: .off))
        XCTAssertEqual(roles.setting(for: .drafting), LocalModelSetting(variant: "qwen3-4b-4bit"))
        XCTAssertEqual(roles.setting(for: .comparing), LocalModelSetting(reasoning: .off))
        XCTAssertEqual(roles.setting(for: .answering), LocalModelSetting(), "unnamed: backend variant, thinking on")
    }

    func testRejectsUnknownRolesAndModes() {
        XCTAssertThrowsError(try LocalModelRoles(parsing: "grading=off"))
        XCTAssertThrowsError(try LocalModelRoles(parsing: "judging=qwen3-4b-4bit:maybe"))
        XCTAssertThrowsError(try LocalModelRoles(parsing: "judging"))
        XCTAssertNil(try LocalModelRoles.fromEnvironment([:]))
    }

    /// Docs/18 M4's short-run choice: answering on 4B without thinking; judging and comparing
    /// keep thinking on (without it the judge calls nearly every criterion "met").
    func testRecommendedTableAppliesOnlyToTheDefaultBundle() {
        XCTAssertEqual(LocalModelRoles.current(for: .coreAI(variant: CoreAIModelLocator.defaultVariant)), .recommended)
        XCTAssertEqual(LocalModelRoles.current(for: .coreAI(variant: "qwen3-4b-4bit")), .uniform)
        XCTAssertEqual(
            LocalModelBackend.coreAI(variant: "qwen3-4b-4bit").modelIdentifier(for: .judging),
            "coreai:qwen3-4b-4bit", "an explicit variant runs every role on it")
    }

    func testRecommendedTable() {
        let coreAI = LocalModelBackend.coreAI(variant: "qwen3-8b-4bit")
        let roles = LocalModelRoles.recommended
        XCTAssertEqual(coreAI.modelIdentifier(for: .answering, roles: roles), "coreai:qwen3-4b-4bit+nothink")
        XCTAssertEqual(coreAI.modelIdentifier(for: .judging, roles: roles), "coreai:qwen3-8b-4bit")
        XCTAssertEqual(coreAI.modelIdentifier(for: .comparing, roles: roles), "coreai:qwen3-8b-4bit")
        XCTAssertEqual(coreAI.modelIdentifier(for: .drafting, roles: roles), "coreai:qwen3-8b-4bit")
    }

    func testResolutionOnCoreAIAndMLX() throws {
        let roles = try LocalModelRoles(parsing: "judging=qwen3-4b-4bit:off")
        let coreAI = LocalModelBackend.coreAI(variant: "qwen3-8b-4bit")
        XCTAssertEqual(coreAI.modelIdentifier(for: .judging, roles: roles), "coreai:qwen3-4b-4bit+nothink")
        XCTAssertEqual(coreAI.modelIdentifier(for: .answering, roles: roles), "coreai:qwen3-8b-4bit")
        XCTAssertEqual(
            coreAI.resolved(for: .judging, roles: roles),
            ResolvedLocalModel(backend: .coreAI(variant: "qwen3-4b-4bit"), reasoning: .off))
    }
}
