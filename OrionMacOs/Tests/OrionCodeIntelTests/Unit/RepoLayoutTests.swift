import XCTest
@testable import OrionCodeIntel

final class RepoLayoutTests: XCTestCase {

    private func layout(prefix: String) -> RepoLayout {
        RepoLayout(moduleRootPrefix: prefix)
    }

    func testRootPackageModule() {
        let l = layout(prefix: "")
        XCTAssertEqual(
            l.moduleInfo(forRelPath: "starlette/applications.py"),
            .init(modulePath: "starlette.applications", isPackageInit: false)
        )
    }

    func testPackageInit() {
        let l = layout(prefix: "")
        XCTAssertEqual(
            l.moduleInfo(forRelPath: "starlette/middleware/__init__.py"),
            .init(modulePath: "starlette.middleware", isPackageInit: true)
        )
        XCTAssertEqual(
            l.moduleInfo(forRelPath: "starlette/__init__.py"),
            .init(modulePath: "starlette", isPackageInit: true)
        )
    }

    func testTopLevelModuleFile() {
        XCTAssertEqual(
            layout(prefix: "").moduleInfo(forRelPath: "conftest.py"),
            .init(modulePath: "conftest", isPackageInit: false)
        )
    }

    func testSrcLayoutStripsPrefix() {
        let l = layout(prefix: "src/")
        XCTAssertEqual(
            l.moduleInfo(forRelPath: "src/pkg/mod.py"),
            .init(modulePath: "pkg.mod", isPackageInit: false)
        )
        XCTAssertEqual(
            l.moduleInfo(forRelPath: "src/pkg/__init__.py"),
            .init(modulePath: "pkg", isPackageInit: true)
        )
    }

    func testFileOutsideModuleRootIsUnresolved() {
        let l = layout(prefix: "src/")
        XCTAssertEqual(
            l.moduleInfo(forRelPath: "scripts/build.py"),
            .init(modulePath: nil, isPackageInit: false)
        )
    }

    func testSrcDetectionFromDisk() throws {
        let tmp = try TempDir()
        try tmp.write("src/pkg/__init__.py", "")
        try tmp.write("src/pkg/mod.py", "x = 1\n")
        let l = RepoLayout(root: tmp.url, pythonRelPaths: ["src/pkg/__init__.py", "src/pkg/mod.py"])
        XCTAssertEqual(l.moduleRootPrefix, "src/")
        XCTAssertEqual(l.moduleInfo(forRelPath: "src/pkg/mod.py").modulePath, "pkg.mod")
    }

    func testNoSrcDirMeansRootPrefix() throws {
        let tmp = try TempDir()
        try tmp.write("pkg/__init__.py", "")
        let l = RepoLayout(root: tmp.url, pythonRelPaths: ["pkg/__init__.py"])
        XCTAssertEqual(l.moduleRootPrefix, "")
    }
}
