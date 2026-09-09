import SwiftUI

/// Configuration for the optional self-hosted Office conversion service.
/// `SettingsView` owns the entry point; keeping this form separate makes the
/// endpoint/token boundary testable without changing the existing Settings
/// sections.
struct OfficeConversionSettingsView: View {
    private let configurationStore: OfficeConversionConfigurationStore

    @State private var endpoint: String
    @State private var token: String
    @State private var statusMessage = ""
    @State private var showStatus = false

    init(configurationStore: OfficeConversionConfigurationStore = .shared) {
        self.configurationStore = configurationStore
        let configuration = configurationStore.configuration
        _endpoint = State(initialValue: configuration.endpoint?.absoluteString ?? "")
        _token = State(initialValue: configuration.token ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("HTTPS endpoint", text: $endpoint)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Office conversion HTTPS endpoint")
                SecureField("Bearer token (optional)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Office conversion bearer token")
            } header: {
                Text("Office conversion service")
            } footer: {
                Text("The service receives a temporary copy of one file. Configure an HTTPS endpoint; the optional token is stored in Keychain.")
            }

            Section {
                Button("Save service settings") { save() }
                    .disabled(!isValidEndpoint)
                    .accessibilityHint(isValidEndpoint ? "Saves the endpoint and optional token" : "Enter an HTTPS endpoint first")
                Button("Clear service settings", role: .destructive) { clear() }
                    .disabled(endpoint.isEmpty && token.isEmpty)
            }
        }
        .navigationTitle("Office Conversion")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Office conversion", isPresented: $showStatus) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusMessage)
        }
    }

    private var isValidEndpoint: Bool {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return OfficeConversionConfiguration.isValidEndpoint(url)
    }

    private func save() {
        do {
            try configurationStore.save(endpoint: endpoint, token: token)
            statusMessage = "Office conversion settings saved."
        } catch {
            statusMessage = error.localizedDescription
        }
        showStatus = true
    }

    private func clear() {
        do {
            try configurationStore.clear()
            endpoint = ""
            token = ""
            statusMessage = "Office conversion settings cleared."
        } catch {
            statusMessage = error.localizedDescription
        }
        showStatus = true
    }
}
