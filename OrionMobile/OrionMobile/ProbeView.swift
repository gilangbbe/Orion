import SwiftUI
import UIKit

/// Runs `FMProbe` on the phone and saves the report to Documents, where
/// `xcrun devicectl device copy from --domain-type appDataContainer` can pull it (Docs/19 M0).
/// Launching with `FM_PROBE_AUTORUN=1` starts the run without a tap.
struct ProbeView: View {
    @State private var probe = FMProbe()
    @State private var savedURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("System model") {
                    row("Device", probe.report.deviceModel)
                    row("OS", probe.report.os)
                    row("Availability", probe.report.availability)
                    row("Variant", probe.report.variant ?? "–")
                    row("Context size", probe.report.contextSize.map { "\($0) tokens" } ?? "–")
                    ForEach(probe.report.capabilities.sorted(by: { $0.key < $1.key }), id: \.key) { name, supported in
                        row(name, supported ? "yes" : "no")
                    }
                }
                if !probe.report.tokenization.isEmpty {
                    Section("Tokenization (Orion context)") {
                        ForEach(probe.report.tokenization, id: \.chars) { sample in
                            row("\(sample.chars) chars", "\(sample.tokens) tok · \(sample.charsPerToken.formatted(.number.precision(.fractionLength(2)))) c/t")
                        }
                    }
                }
                Section("Checks") {
                    ForEach(probe.report.checks) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(check.name, systemImage: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(check.ok ? .green : .red)
                            Text(metrics(check)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(check.detail).font(.caption).lineLimit(4)
                        }
                    }
                    if probe.isRunning {
                        Label("Running \(probe.currentStep)…", systemImage: "hourglass")
                    }
                }
            }
            .navigationTitle("Orion · FM probe")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Run", systemImage: "play.fill") { Task { await runProbe() } }
                        .disabled(probe.isRunning)
                }
                if let savedURL {
                    ToolbarItem(placement: .secondaryAction) {
                        ShareLink(item: savedURL)
                    }
                }
            }
        }
        .task {
            if ProcessInfo.processInfo.environment["FM_PROBE_AUTORUN"] == "1" { await runProbe() }
        }
    }

    private func runProbe() async {
        // The system model is foreground-only; keep the screen on for the ~minute a run takes.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        await probe.run()
        savedURL = save(probe.report)
    }

    /// Writes a timestamped report plus `fm-probe-latest.json` (the fixed name the pull command uses).
    private func save(_ report: ProbeReport) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let data = Data(report.json().utf8)
        let stamped = documents.appending(path: "fm-probe-\(Int(report.startedAt.timeIntervalSince1970)).json")
        try? data.write(to: stamped)
        try? data.write(to: documents.appending(path: "fm-probe-latest.json"))
        return stamped
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    private func metrics(_ check: ProbeReport.Check) -> String {
        var parts: [String] = []
        if let ttft = check.ttftMs { parts.append("ttft \(ttft)ms") }
        if let total = check.totalMs { parts.append("total \(total)ms") }
        if let input = check.inputTokens { parts.append("in \(input)") }
        if let cached = check.cachedInputTokens, cached > 0 { parts.append("cached \(cached)") }
        if let output = check.outputTokens { parts.append("out \(output)") }
        if let reasoning = check.reasoningTokens, reasoning > 0 { parts.append("think \(reasoning)") }
        if let tps = check.decodeTokensPerSecond { parts.append("\(tps.formatted(.number.precision(.fractionLength(1)))) tok/s") }
        return parts.joined(separator: " · ")
    }
}
