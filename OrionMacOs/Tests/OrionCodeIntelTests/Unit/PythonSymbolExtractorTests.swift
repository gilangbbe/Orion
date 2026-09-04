import XCTest
@testable import OrionCodeIntel

final class PythonSymbolExtractorTests: XCTestCase {

    private func run(
        _ src: String, relPath: String = "m.py", module: String? = "m", isInit: Bool = false
    ) throws -> FileSymbols {
        let parser = try TreeSitterParser(PythonLanguageSupport())
        let parsed = try XCTUnwrap(
            parser.parse(fileId: "f", relPath: relPath, source: Data(src.utf8))
        )
        return PythonSymbolExtractor().extract(parsed, modulePath: module, isPackageInit: isInit)
    }

    private func symbol(_ fs: FileSymbols, _ anchor: String) -> ExtractedSymbol? {
        fs.symbols.first { $0.anchor == anchor }
    }

    func testModuleSymbol() throws {
        let fs = try run("x = 1\n")
        let mod = try XCTUnwrap(symbol(fs, "m.py"))
        XCTAssertEqual(mod.kind, .module)
        XCTAssertEqual(mod.qualifiedName, "m")
        XCTAssertNil(mod.parentAnchor)
        XCTAssertTrue(mod.isExported)
    }

    func testPackageInitModuleSymbol() throws {
        let fs = try run("", relPath: "pkg/sub/__init__.py", module: "pkg.sub", isInit: true)
        let mod = try XCTUnwrap(symbol(fs, "pkg/sub/__init__.py"))
        XCTAssertEqual(mod.kind, .package)
        XCTAssertEqual(mod.qualifiedName, "pkg.sub")
    }

    func testNestedMethodAnchorAndQualifiedName() throws {
        let fs = try run("""
        class Widget:
            def render(self, x) -> bytes:
                def helper():
                    return x
                return helper()
        """)
        let method = try XCTUnwrap(symbol(fs, "m.py::Widget.render"))
        XCTAssertEqual(method.kind, .method)
        XCTAssertEqual(method.qualifiedName, "m.Widget.render")
        XCTAssertEqual(method.parentAnchor, "m.py::Widget")
        XCTAssertEqual(method.signature, "(self, x) -> bytes")
        // nested function stays kind .function, parented to the method
        let helper = try XCTUnwrap(symbol(fs, "m.py::Widget.render.helper"))
        XCTAssertEqual(helper.kind, .function)
        XCTAssertEqual(helper.parentAnchor, "m.py::Widget.render")
    }

    func testVariableConstantProperty() throws {
        let fs = try run("""
        SIZE = 10
        name = "x"

        class C:
            attr = 1
            @property
            def value(self):
                return self.attr
        """)
        XCTAssertEqual(symbol(fs, "m.py::SIZE")?.kind, .constant)
        XCTAssertEqual(symbol(fs, "m.py::name")?.kind, .variable)
        XCTAssertEqual(symbol(fs, "m.py::C.attr")?.kind, .variable)
        XCTAssertEqual(symbol(fs, "m.py::C.value")?.kind, .property)
    }

    func testDecoratorsAndDocstring() throws {
        let fs = try run("""
        import functools

        @functools.cache
        @staticmethod
        def f():
            \"\"\"Does a thing.\"\"\"
            return 1
        """)
        let f = try XCTUnwrap(symbol(fs, "m.py::f"))
        XCTAssertEqual(f.decorators, ["functools.cache", "staticmethod"])
        XCTAssertEqual(f.docstring, "Does a thing.")
        // span starts at the first decorator line
        XCTAssertEqual(f.startLine, 3)
    }

    func testDunderAllControlsExport() throws {
        let fs = try run("""
        __all__ = ["public_fn", "Klass"]

        def public_fn(): pass
        def hidden_fn(): pass
        class Klass: pass
        class _Internal: pass
        """)
        XCTAssertEqual(symbol(fs, "m.py::public_fn")?.isExported, true)
        XCTAssertEqual(symbol(fs, "m.py::hidden_fn")?.isExported, false)
        XCTAssertEqual(symbol(fs, "m.py::Klass")?.isExported, true)
        XCTAssertEqual(symbol(fs, "m.py::_Internal")?.isExported, false)
    }

    func testNoDunderAllFallsBackToVisibility() throws {
        let fs = try run("def pub(): pass\ndef _priv(): pass\n")
        XCTAssertEqual(symbol(fs, "m.py::pub")?.isExported, true)
        XCTAssertEqual(symbol(fs, "m.py::_priv")?.isExported, false)
        XCTAssertEqual(symbol(fs, "m.py::_priv")?.visibility, "private")
    }

    func testDynamicDunderAllEmitsDiagnostic() throws {
        let fs = try run("__all__ = [n for n in dir()]\ndef f(): pass\n")
        XCTAssertTrue(fs.diagnostics.contains { $0.code == "DYNAMIC_ALL" })
        // falls back to visibility
        XCTAssertEqual(symbol(fs, "m.py::f")?.isExported, true)
    }

    func testImportAliases() throws {
        let fs = try run("""
        import os
        import a.b.c as abc
        from x.y import z
        from x.y import w as ww
        """)
        XCTAssertEqual(symbol(fs, "m.py::os")?.kind, .importAlias)
        XCTAssertEqual(symbol(fs, "m.py::os")?.redirectsTo, "os")
        XCTAssertEqual(symbol(fs, "m.py::abc")?.redirectsTo, "a.b.c")
        XCTAssertEqual(symbol(fs, "m.py::z")?.redirectsTo, "x.y::z")
        XCTAssertEqual(symbol(fs, "m.py::ww")?.redirectsTo, "x.y::w")
    }

    func testRelativeReexportInInit() throws {
        let fs = try run("""
        from .applications import Starlette
        from . import responses
        from typing import Any
        """, relPath: "pkg/__init__.py", module: "pkg", isInit: true)

        let reexport = try XCTUnwrap(symbol(fs, "pkg/__init__.py::Starlette"))
        XCTAssertEqual(reexport.kind, .reexport)
        XCTAssertEqual(reexport.redirectsTo, ".applications::Starlette")
        XCTAssertEqual(symbol(fs, "pkg/__init__.py::responses")?.kind, .reexport)
        // absolute import in __init__ stays a plain alias, not a re-export
        XCTAssertEqual(symbol(fs, "pkg/__init__.py::Any")?.kind, .importAlias)
    }

    func testFutureImportProducesNoSymbol() throws {
        let fs = try run("from __future__ import annotations\nx = 1\n")
        XCTAssertNil(symbol(fs, "m.py::annotations"))
    }

    func testWildcardImportDiagnostic() throws {
        let fs = try run("from os.path import *\n")
        XCTAssertTrue(fs.diagnostics.contains { $0.code == "WILDCARD_IMPORT" })
    }

    func testConditionalTopLevelDefsAreFound() throws {
        let fs = try run("""
        import sys
        if sys.version_info >= (3, 11):
            def feature(): return "new"
        else:
            def feature(): return "old"
        try:
            from fast import thing
        except ImportError:
            from slow import thing
        """)
        XCTAssertNotNil(symbol(fs, "m.py::feature"))
        XCTAssertEqual(symbol(fs, "m.py::feature")?.parentAnchor, "m.py")
        XCTAssertNotNil(symbol(fs, "m.py::thing"))
    }

    func testVisibilityClassification() throws {
        let fs = try run("a = 1\n_b = 2\n__c = 3\n__d__ = 4\n")
        XCTAssertEqual(symbol(fs, "m.py::a")?.visibility, "public")
        XCTAssertEqual(symbol(fs, "m.py::_b")?.visibility, "private")
        XCTAssertEqual(symbol(fs, "m.py::__c")?.visibility, "private")
        XCTAssertEqual(symbol(fs, "m.py::__d__")?.visibility, "dunder")
    }

    func testTupleAssignmentBindsEachName() throws {
        let fs = try run("x, y = 1, 2\n")
        XCTAssertNotNil(symbol(fs, "m.py::x"))
        XCTAssertNotNil(symbol(fs, "m.py::y"))
    }
}
