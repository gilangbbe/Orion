import XCTest
@testable import OrionCodeIntel

final class ScipSymbolTests: XCTestCase {

    func testLocal() throws {
        let s = try XCTUnwrap(ScipSymbol("local 42"))
        XCTAssertTrue(s.isLocal)
        XCTAssertNil(s.moduleDotted)
    }

    func testClassSymbol() throws {
        let s = try XCTUnwrap(ScipSymbol(
            "scip-python python starlette 4f250d6b `starlette.responses`/JSONResponse#"
        ))
        XCTAssertEqual(s.package, "starlette")
        XCTAssertEqual(s.moduleDotted, "starlette.responses")
        XCTAssertEqual(s.inFileDotted, "JSONResponse")
        XCTAssertEqual(s.leafKind, .type)
        XCTAssertEqual(s.leafName, "JSONResponse")
        XCTAssertFalse(s.isModuleSymbol)
    }

    func testMethodSymbol() throws {
        let s = try XCTUnwrap(ScipSymbol(
            "scip-python python starlette 4f250d6b `starlette.applications`/Starlette#build_middleware_stack()."
        ))
        XCTAssertEqual(s.moduleDotted, "starlette.applications")
        XCTAssertEqual(s.inFileDotted, "Starlette.build_middleware_stack")
        XCTAssertEqual(s.leafKind, .method)
    }

    func testParameterIsExcludedFromDotted() throws {
        let s = try XCTUnwrap(ScipSymbol(
            "scip-python python starlette 4f250d6b `starlette.applications`/Starlette#build_middleware_stack().(self)"
        ))
        XCTAssertEqual(s.inFileDotted, "Starlette.build_middleware_stack")
        XCTAssertEqual(s.leafKind, .method)   // parameter suffix ignored for the leaf kind
    }

    func testModuleSymbol() throws {
        let s = try XCTUnwrap(ScipSymbol(
            "scip-python python starlette 4f250d6b `starlette.responses`/__init__:"
        ))
        XCTAssertEqual(s.moduleDotted, "starlette.responses")
        XCTAssertEqual(s.inFileDotted, "")
        XCTAssertTrue(s.isModuleSymbol)
    }

    func testTopPackageModuleSymbol() throws {
        let s = try XCTUnwrap(ScipSymbol("scip-python python starlette 4f250d6b starlette/__init__:"))
        XCTAssertEqual(s.moduleDotted, "starlette")
        XCTAssertTrue(s.isModuleSymbol)
    }

    func testExternalStdlibSymbol() throws {
        let s = try XCTUnwrap(ScipSymbol("scip-python python python-stdlib 3.11 builtins/str#"))
        XCTAssertEqual(s.package, "python-stdlib")
        XCTAssertEqual(s.moduleDotted, "builtins")
        XCTAssertEqual(s.leafName, "str")
    }

    func testTermSymbol() throws {
        let s = try XCTUnwrap(ScipSymbol(
            "scip-python python starlette 4f250d6b `starlette.applications`/Starlette#middleware_stack."
        ))
        XCTAssertEqual(s.inFileDotted, "Starlette.middleware_stack")
        XCTAssertEqual(s.leafKind, .term)
    }
}
