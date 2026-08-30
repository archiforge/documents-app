import SwiftUI

/// The horizontally scrolling format filter chips above the Recent list,
/// matching the Android app's row: All / Scanned / DOC / XLS / PPT / PDF /
/// OFD / TXT.
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
        let foreground: Color = isSelected ? .white : .primary
        let background: Color = isSelected ? .accentColor : Color(.secondarySystemBackground)
        return Button {
            withAnimation(.snappy) {
                selection = filter
            }
        } label: {
            Text(filter.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(foreground)
                .background(Capsule().fill(background))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title) filter")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
