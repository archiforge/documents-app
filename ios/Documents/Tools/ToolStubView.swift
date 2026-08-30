import SwiftUI

/// Placeholder destination for tools that land in later phases.
struct ToolStubView: View {
    let tool: ToolItem

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: tool.symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(tool.title)
                .font(.title2.bold())
            Text("Coming in Phase \(tool.stubPhase ?? 0)")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(phaseDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var phaseDescription: String {
        switch tool.stubPhase {
        case 2:
            "Part of the Phase 2 toolbox: scanning, format conversion, and PDF tools."
        case 3:
            "Part of Phase 3: on-device AI features such as extraction, summary, and translation."
        default:
            "Planned for a future phase."
        }
    }
}
