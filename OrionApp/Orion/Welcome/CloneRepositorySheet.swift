import SwiftUI

/// File > Clone from GitHub… (Docs/20 R2): the URL, checked before it's used, with Cancel and a
/// default Clone button (HIG, Sheets).
struct CloneRepositorySheet: View {
    let onClone: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Repository URL", text: $text, prompt: Text(verbatim: "https://github.com/owner/repo"))
                    .onSubmit(clone)
            } header: {
                Text("Clone from GitHub")
                    .font(.headline)
            } footer: {
                Text(error ?? "Public HTTPS repositories only. Orion clones it, then analyzes it on this Mac.")
                    .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Clone", action: clone)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func cancel() {
        dismiss()
    }

    private func clone() {
        guard let url = Self.validURL(text) else {
            error = "Enter an https:// address, like https://github.com/owner/repo."
            return
        }
        dismiss()
        onClone(url)
    }

    static func validURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.pathComponents.count > 1
        else { return nil }
        return url
    }
}
