import SwiftUI

/// Rename… on a session (Docs/15 §4.7 M8.5): its title, with Cancel and a default Rename.
struct RenameSessionSheet: View {
    let session: AskSessionRow
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(session: AskSessionRow, onSave: @escaping (String) -> Void) {
        self.session = session
        self.onSave = onSave
        _title = State(initialValue: session.title)
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title)
                    .onSubmit(save)
            } header: {
                Text("Rename Session")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename", action: save)
                    .disabled(trimmedTitle.isEmpty)
            }
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancel() {
        dismiss()
    }

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        onSave(trimmedTitle)
        dismiss()
    }
}
