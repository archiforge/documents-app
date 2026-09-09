import SwiftUI

/// The horizontally scrolling format filter chips above the Recent list:
/// All / Scanned / PDF / DOC / EPUB / XLS / TXT (custom row, ledger #8).
struct FormatFilterRow: View {
    @Binding var selection: FormatFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FormatFilter.allCases) { filter in
                    chip(filter)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ filter: FormatFilter) -> some View {
        let isSelected = filter == selection
        return Button {
            withAnimation(.snappy) {
                selection = filter
            }
        } label: {
            Text(LocalizedStringKey(filter.title))
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .underline(isSelected, color: .accentColor)
                // Keep the compact ledger row visually light while giving
                // every filter the native 44-point minimum touch target.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title) filter")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
