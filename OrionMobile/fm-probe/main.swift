import Foundation

// The Mac twin of the iOS probe screen (Docs/19 M0): same `FMProbe`, report on stdout.
// Set FM_PROBE_OUT=<path> to also write the JSON to a file.
let probe = FMProbe()
await probe.run()
let json = probe.report.json()
print(json)
if let path = ProcessInfo.processInfo.environment["FM_PROBE_OUT"] {
    try Data(json.utf8).write(to: URL(fileURLWithPath: path))
}
