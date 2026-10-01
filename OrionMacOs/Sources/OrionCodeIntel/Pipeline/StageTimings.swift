import Foundation

/// Accumulates wall-clock time per pipeline stage (milliseconds). Persisted to
/// `analysis_runs.stage_timings`.
public final class StageTimings {
    public private(set) var milliseconds: [String: Double] = [:]

    public init() {}

    @discardableResult
    public func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            milliseconds[stage, default: 0] += elapsed
        }
        return try body()
    }
}
