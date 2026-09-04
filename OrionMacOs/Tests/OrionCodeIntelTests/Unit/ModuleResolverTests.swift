import XCTest
@testable import OrionCodeIntel

final class ModuleResolverTests: XCTestCase {

    private let resolver = ModuleResolver(inRepoModules: [
        "app", "app.core", "app.core.db", "app.util", "app.util.text", "app.web",
    ])

    private func resolve(
        _ spec: String, name: String? = nil, from importer: String, isPackage: Bool = false
    ) -> ModuleResolver.Target {
        resolver.resolve(
            spec: spec, importedName: name,
            importerModulePath: importer, importerIsPackage: isPackage
        )
    }

    func testAbsoluteExactModule() {
        XCTAssertEqual(resolve("app.core.db", from: "app.web"), .inRepoModule("app.core.db"))
    }

    func testAbsoluteViaImportedSubmodule() {
        // from app.core import db  ->  app.core.db is the module
        XCTAssertEqual(resolve("app.core", name: "db", from: "app.web"), .inRepoModule("app.core.db"))
    }

    func testAbsoluteViaPrefixWhenLeafIsAName() {
        // from app.core.db import Session  ->  resolves to module app.core.db
        XCTAssertEqual(
            resolve("app.core.db", name: "Session", from: "app.web"),
            .inRepoModule("app.core.db")
        )
    }

    func testExternalStdlibAndThirdParty() {
        XCTAssertEqual(resolve("os.path", from: "app.web"),
                       .external(topLevel: "os", full: "os.path"))
        XCTAssertEqual(resolve("anyio.to_thread", from: "app.web"),
                       .external(topLevel: "anyio", full: "anyio.to_thread"))
    }

    func testOwnTopLevelButUnknownModuleIsUnresolvable() {
        XCTAssertEqual(resolve("app.missing.thing", from: "app.web"), .unresolvable("app.missing.thing"))
    }

    func testRelativeFromModule() {
        // in app/web.py (not a package): `from . import core` -> app.core
        XCTAssertEqual(resolve(".", name: "core", from: "app.web"), .inRepoModule("app.core"))
        // `from .core import db` -> app.core.db  (core is a package here)
        XCTAssertEqual(resolve(".core", name: "db", from: "app.web"), .inRepoModule("app.core.db"))
    }

    func testRelativeFromPackageInit() {
        // in app/core/__init__.py: `from . import db` -> app.core.db
        XCTAssertEqual(
            resolve(".", name: "db", from: "app.core", isPackage: true),
            .inRepoModule("app.core.db")
        )
    }

    func testRelativeParentLevel() {
        // in app/core/db.py: `from ..util import text` -> app.util.text
        XCTAssertEqual(resolve("..util", name: "text", from: "app.core.db"), .inRepoModule("app.util.text"))
        XCTAssertEqual(resolve("..util", from: "app.core.db"), .inRepoModule("app.util"))
    }

    func testRelativeBeyondTopIsUnresolvable() {
        XCTAssertEqual(resolve("...x", from: "app.core"), .unresolvable("...x"))
    }
}
