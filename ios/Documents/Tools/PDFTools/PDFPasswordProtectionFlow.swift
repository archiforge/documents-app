import SwiftUI

/// Collects a password and saves a password-protected copy of a selected PDF.
/// Password values stay in transient SecureField state and are never persisted
/// in the document model or included in status messages.
struct PDFPasswordProtectionFlowView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var source: DocumentRecord?
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var errorState = FlowErrorState()
    @State private var protectionTask: Task<Void, Never>?

    let onDone: (ToolMessage, PresentedDocument?) -> Void

    var body: some View {
        Form {
            if let source {
                Section("Source") {
                    Label(source.displayName, systemImage: "doc.richtext")
                    Button("Choose a different PDF") {
                        self.source = nil
                    }
                    .font(.footnote)
                }
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirmation)
                        .textContentType(.newPassword)
                } header: {
                    Text("Password")
                } footer: {
                    Text("A new protected copy is saved. The original file remains unchanged.")
                }
            } else {
                PDFSourcePicker { source = $0 }
            }
        }
        .navigationTitle("Protect PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancelProtection() }
            }
            if source != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Protect") { protect() }
                        .disabled(working)
                }
            }
        }
        .alert("Protection failed", isPresented: $errorState.isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorState.message)
        }
        .onDisappear {
            protectionTask?.cancel()
            clearCredentials()
        }
    }

    private func protect() {
        guard let source else { return }
        let sourceURL = source.absolutePath.map(URL.init(fileURLWithPath:))
            ?? store.fileBridge.absoluteURL(forRelativePath: source.relativePath)
        let base = (source.displayName as NSString).deletingPathExtension
        let outputName = "Protected_\(base).pdf"
        let password = password
        let confirmation = confirmation
        let documentStore = store

        working = true
        protectionTask?.cancel()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let payload = try Data(contentsOf: sourceURL)
            try Task.checkCancellation()
            let protected = try PDFToolbox.encrypt(
                payload,
                password: password,
                confirmation: confirmation
            )
            try Task.checkCancellation()
            return protected
        }
        protectionTask = Task { @MainActor in
            do {
                let protected = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
                try Task.checkCancellation()
                guard !Task.isCancelled else { return }

                // Save only after the detached work has completed and the
                // task has remained active. DocumentStore is main-actor
                // isolated and writes the generated copy atomically.
                let record = try documentStore.saveGeneratedFile(
                    name: outputName,
                    data: protected
                )

                clearCredentials()
                protectionTask = nil
                working = false
                dismiss()
                onDone(
                    ToolMessage(title: "PDF Protected", body: "Saved as \(record.displayName)."),
                    PresentedDocument(record: record)
                )
            } catch is CancellationError {
                clearCredentials()
                working = false
                protectionTask = nil
            } catch {
                working = false
                protectionTask = nil
                errorState.message = error.localizedDescription
                errorState.isPresented = true
            }
        }
    }

    private func cancelProtection() {
        protectionTask?.cancel()
        protectionTask = nil
        working = false
        clearCredentials()
        dismiss()
    }

    private func clearCredentials() {
        password.removeAll()
        confirmation.removeAll()
    }
}
