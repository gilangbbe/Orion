import XCTest
@testable import OrionCodeIntel

final class PEP508Tests: XCTestCase {

    func testNormalize() {
        XCTAssertEqual(PEP508.normalize("Typing_Extensions"), "typing-extensions")
        XCTAssertEqual(PEP508.normalize("python-multipart"), "python-multipart")
        XCTAssertEqual(PEP508.normalize("A.B__C"), "a-b-c")
    }

    func testParsePlain() {
        let d = PEP508.parse("anyio>=3.6.2,<5", source: .pyproject, group: "runtime")
        XCTAssertEqual(d?.distribution, "anyio")
        XCTAssertEqual(d?.versionSpec, ">=3.6.2,<5")
        XCTAssertNil(d?.marker)
    }

    func testParseWithMarkerAndExtras() {
        let d = PEP508.parse(
            "typing_extensions[foo, bar]>=4.10.0; python_version < '3.13'",
            source: .pyproject, group: "runtime"
        )
        XCTAssertEqual(d?.distribution, "typing-extensions")
        XCTAssertEqual(d?.versionSpec, ">=4.10.0")
        XCTAssertEqual(d?.extras, ["foo", "bar"])
        XCTAssertEqual(d?.marker, "python_version < '3.13'")
    }

    func testParseParenthesizedSpecAndUnconstrained() {
        XCTAssertEqual(PEP508.parse("jinja2", source: .pyproject, group: "x")?.versionSpec, nil)
        XCTAssertEqual(
            PEP508.parse("foo (>=1.0)", source: .pyproject, group: "x")?.versionSpec, ">=1.0"
        )
    }

    func testParseURLRequirement() {
        let d = PEP508.parse("mypkg @ https://example.com/mypkg.whl", source: .requirements, group: "r")
        XCTAssertEqual(d?.distribution, "mypkg")
        XCTAssertNil(d?.versionSpec)
    }

    func testCommentsAndOptionsAreIgnored() {
        XCTAssertNil(PEP508.parse("# a comment", source: .requirements, group: "r"))
        XCTAssertNil(PEP508.parse("-r base.txt", source: .requirements, group: "r"))
        XCTAssertNil(PEP508.parse("   ", source: .requirements, group: "r"))
    }
}

final class PyProjectParserTests: XCTestCase {

    func testStarletteShape() throws {
        let toml = """
        [project]
        name = "starlette"
        dependencies = [
            "anyio>=3.6.2,<5",
            "typing_extensions>=4.10.0; python_version < '3.13'",
        ]

        [project.optional-dependencies]
        full = ["itsdangerous", "jinja2", "httpx>=0.27.0,<0.29.0"]

        [dependency-groups]
        dev = ["starlette[full]", "pytest==9.1.1"]
        """
        let deps = try PyProjectParser.parse(tomlText: toml)
        let byName = Dictionary(uniqueKeysWithValues: deps.map { ($0.distribution, $0) })

        XCTAssertEqual(byName["anyio"]?.versionSpec, ">=3.6.2,<5")
        XCTAssertEqual(byName["typing-extensions"]?.versionSpec, ">=4.10.0")
        XCTAssertEqual(byName["httpx"]?.versionSpec, ">=0.27.0,<0.29.0")
        XCTAssertNotNil(byName["jinja2"])
        XCTAssertEqual(byName["pytest"]?.versionSpec, "==9.1.1")
        // self-reference is dropped
        XCTAssertNil(byName["starlette"])
    }

    func testEmptyWhenNoProjectTable() throws {
        XCTAssertTrue(try PyProjectParser.parse(tomlText: "[build-system]\nrequires = [\"x\"]\n").isEmpty)
    }
}

final class RequirementsParserTests: XCTestCase {

    func testParsesAndDedups() {
        let text = """
        # base requirements
        Django>=4.2
        requests==2.31.0
        requests==2.31.0
        -e .
        pytest ; python_version >= '3.9'
        """
        let deps = RequirementsParser.parse(text: text)
        let names = deps.map(\.distribution)
        XCTAssertEqual(names, ["django", "pytest", "requests"])
        XCTAssertEqual(deps.first { $0.distribution == "django" }?.versionSpec, ">=4.2")
        XCTAssertEqual(deps.first { $0.distribution == "pytest" }?.marker, "python_version >= '3.9'")
    }
}
