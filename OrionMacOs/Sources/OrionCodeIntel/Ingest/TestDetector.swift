import Foundation

/// Test detection. `isTestPath` drives the file-level `is_test` column (M1); `isTestSymbol`
/// picks out the individual test functions/methods a `tested_by` edge can originate from (M6).
public enum TestDetector {
    public static func isTestPath(_ relPath: String) -> Bool {
        let comps = relPath.split(separator: "/").map(String.init)
        guard let file = comps.last else { return false }
        if comps.dropLast().contains(where: { $0 == "tests" || $0 == "test" }) { return true }
        if file.hasPrefix("test_") && file.hasSuffix(".py") { return true }
        if file.hasSuffix("_test.py") { return true }
        if file == "conftest.py" { return true }
        return false
    }

    /// A symbol that pytest / unittest would collect as a test case: a `test*`
    /// function/method, or one carrying a `pytest` decorator, inside a test file.
    public static func isTestSymbol(
        name: String, kind: String, decorators: [String], fileIsTest: Bool
    ) -> Bool {
        guard fileIsTest, kind == "function" || kind == "method" else { return false }
        if name.hasPrefix("test") { return true }
        return decorators.contains { $0.hasPrefix("pytest") || $0.hasPrefix("pytest.") }
    }
}
