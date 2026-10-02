import Foundation


/// One Ask call's routing/trace detail, Docs/14 §4.9 -- the question alongside the
/// `AskResultSummary` that already carries `routingMethod`/`routingConfidence`/`rationale`/
/// `toolCalls` (currently only shown per-answer behind `AskEntryView`'s own "Explain" disclosure).
/// `AskResultSummary` alone doesn't say which question produced it, so this pairs the two.
struct DiagnosticsAskTrace: Equatable {
    let question: String
    let summary: AskResultSummary
}
