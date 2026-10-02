import OrionCore
import SwiftUI

/// Ask on the iPhone (Docs/19 M6, redesigned in M8): conversations about the open repository,
/// answered on device.
///
/// A split view: the conversations on the leading side, the open one on the trailing side. On
/// iPhone it collapses and opens on the conversation (`preferredCompactColumn: .detail`), with the
/// list one step back -- the common case is asking, not browsing history.
struct AskView: View {
    @State private var model: AskModel
    @Binding var request: AskRequest?
    @State private var selection: String?
    @State private var compactColumn = NavigationSplitViewColumn.detail

    init(entry: LocalLibrary.Entry, request: Binding<AskRequest?>) {
        _model = State(initialValue: AskModel(entry: entry))
        _request = request
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            ConversationsList(model: model, selection: $selection, startNew: startNew)
                .repositoryTitleMenu()
        } detail: {
            NavigationStack {
                if model.availability == .available {
                    ConversationScreen(model: model, startNew: startNew)
                } else {
                    ModelUnavailableView(availability: model.availability, feature: "Ask", onRetry: model.refreshAvailability)
                }
            }
        }
        .task {
            model.load()
            model.prewarm()
            selection = model.selectedSessionId
            consume(request)
        }
        .onChange(of: request) { _, newValue in consume(newValue) }
        .onChange(of: selection) { _, newValue in
            guard newValue != model.selectedSessionId else { return }
            model.select(newValue)
            // Only a chosen conversation opens the detail. Going Back on iPhone clears the
            // selection too; forcing the detail then bounced straight into a new conversation,
            // so reaching the list took two Backs.
            if newValue != nil { compactColumn = .detail }
        }
        .onChange(of: model.selectedSessionId) { _, newValue in selection = newValue }
    }

    private func startNew() {
        model.startNewConversation()
        compactColumn = .detail
    }

    private func consume(_ request: AskRequest?) {
        guard let request else { return }
        model.startConversation(aboutComponent: request.componentId, name: request.componentName)
        self.request = nil
        compactColumn = .detail
    }
}
