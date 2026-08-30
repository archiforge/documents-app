import SwiftUI

/// Working "New Document" tool: name the file, pick .txt or .md, create it
/// in the container, record it, and hand it to the viewer.
struct NewDocumentSheet: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var fileExtension = "txt"
    @State private var failureText: String?

    let onCreated: (PresentedDocument) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Document name", text: $name)
                }
                Section("Type") {
                    Picker("Type", selection: $fileExtension) {
                        Text("Plain Text (.txt)").tag("txt")
                        Text("Markdown (.md)").tag("md")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("New Document")
            .navigationBarTitleDisplayMode(.inline)
            .storeFailureAlert(message: $failureText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                }
            }
        }
    }

    private func create() {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let contents = fileExtension == "md" ? "# \(displayName.isEmpty ? "Untitled" : displayName)\n" : ""
        do {
            let record = try store.createDocument(
                named: displayName,
                fileExtension: fileExtension,
                contents: contents
            )
            try store.recordOpen(record)
            let presented = PresentedDocument(record: record)
            dismiss()
            onCreated(presented)
        } catch {
            failureText = error.localizedDescription
        }
    }
}
