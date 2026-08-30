import SwiftUI

extension View {
    /// Presents a store-mutation failure so the UI never reports success
    /// after a failed save. `message` holds the latest error text; nil
    /// hides the alert.
    func storeFailureAlert(message: Binding<String?>) -> some View {
        alert(
            "Action Failed",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { shown in
                    if !shown { message.wrappedValue = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
