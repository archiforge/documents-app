import SwiftUI

/// Destination retained for deferred tools. The Tools grid normally disables
/// unavailable entries, but this screen remains useful for deep links and
/// makes the current capability boundary explicit.
struct ToolStubView: View {
    let tool: ToolItem

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: tool.symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(tool.title)
                .font(.title2.bold())
            Text(tool.capability.statusLabel)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let reasonTitle = tool.capability.reasonTitle {
                Text(reasonTitle)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            Text(tool.capability.reason ?? "This tool is available with the current app services.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
