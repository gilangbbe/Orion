import Foundation

/// Reports first-run model-weight download progress to a sink (stderr by default) --
/// Docs/12_phase3_mlx_agent.md M6: a silent, multi-minute hang on the very first `orion-agent
/// ask` (real weight: ~4.3GB, confirmed live in this machine's own
/// `~/.cache/huggingface/hub/models--mlx-community--Qwen3-8B-4bit`) reads as a hung or broken
/// CLI, not a slow one. `HuggingFace`'s downloader (`HubClient+Files.swift`) drives a real,
/// incrementally-updated `Progress` from actual bytes written, so `fractionCompleted` is
/// meaningful during a real download -- this just needs to print it without being spammy.
///
/// **Confirmed live** on a cached load (the common case after the first run): the handler still
/// fires, but jumps straight from 0% to 100% near-instantly (`\r0%\r100%\n`, verified byte for
/// byte) rather than sitting at any single percentage -- two quick lines, not silence, but no
/// spam either, since the throttle only ever prints on a genuine percent change.
///
/// `@unchecked Sendable`: the one mutable field (`lastReportedPercent`) is protected by a lock,
/// since `Qwen3Agent.load`'s `progressHandler` is `@Sendable` and download callbacks are not
/// guaranteed to arrive on a single, consistent thread.
public final class ModelDownloadProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReportedPercent: Int = -1
    private let sink: (String) -> Void

    public init(sink: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) {
        self.sink = sink
    }

    /// Throttled to whole percentage points -- a real download calls the handler far more often
    /// than once per percent, and re-printing on every byte-count update would flood stderr.
    public func report(_ progress: Progress) {
        let percent = Int((progress.fractionCompleted * 100).rounded(.down))
        lock.lock()
        let alreadyReported = percent == lastReportedPercent
        if !alreadyReported { lastReportedPercent = percent }
        lock.unlock()
        guard !alreadyReported else { return }
        let line = "\rDownloading \(Qwen3Agent.modelConfiguration.name) weights: \(percent)%"
        sink(percent >= 100 ? line + "\n" : line)
    }
}
