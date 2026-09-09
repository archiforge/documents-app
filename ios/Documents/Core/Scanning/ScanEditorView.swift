import SwiftUI

/// Nondestructive page editor for an unfinished scan. Source bytes remain in
/// the draft; reorder, rotate, crop, and removal only update the manifest.
struct ScanEditorView: View {
    @Binding var pages: [ScanPageBuffer]
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex = 0
    @State private var selectedPageID: UUID?
    @State private var cropPage: ScanPageBuffer?

    var body: some View {
        NavigationStack {
            Group {
                if pages.isEmpty {
                    ContentUnavailableView("No Pages", systemImage: "doc", description: Text("Add a page to continue editing."))
                } else {
                    VStack(spacing: 0) {
                        pagePreview
                        pageList
                        controls
                    }
                }
            }
            .navigationTitle("Edit Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $cropPage) { page in
            ScanCropSheet(page: page) { crop in
                guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
                pages[index] = ScanPageEditing.cropping(page, to: crop)
                selectedIndex = index
                selectedPageID = page.id
                onChange()
            }
        }
        .onAppear { normalizeSelection() }
        .onChange(of: pages.map(\.id)) { _, _ in normalizeSelection() }
    }

    private var pagePreview: some View {
        TabView(selection: $selectedIndex) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                Group {
                    ScanPagePreview(page: page)
                }
                .tag(index)
                .padding()
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(maxHeight: 300)
        .background(Color.black.opacity(0.9))
        .onChange(of: selectedIndex) { _, index in
            guard pages.indices.contains(index) else { return }
            selectedPageID = pages[index].id
        }
    }

    private var pageList: some View {
        List {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                Button {
                    selectedIndex = index
                    selectedPageID = page.id
                } label: {
                    HStack(spacing: 12) {
                        ScanPagePreview(page: page, maxDimension: 240)
                            .frame(width: 44, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Page \(index + 1)")
                                .font(.body.weight(index == selectedIndex ? .semibold : .regular))
                            if page.edit.rotationDegrees != 0 || page.edit.crop != .fullPage {
                                Text("Edited")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if index == selectedIndex {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(index + 1)")
                .accessibilityIdentifier("scanner-editor-page-\(index + 1)")
                .accessibilityValue(editorDescription(for: page))
            }
            .onMove { offsets, destination in
                let selectedID = selectedPageID ?? (
                    pages.indices.contains(selectedIndex) ? pages[selectedIndex].id : nil
                )
                let result = ScanPageEditing.reorder(
                    pages,
                    from: offsets,
                    to: destination,
                    keepingSelectedPageID: selectedID
                )
                pages = result.pages
                selectedIndex = result.selectedIndex
                selectedPageID = pages.indices.contains(selectedIndex) ? pages[selectedIndex].id : nil
                onChange()
            }
        }
        .environment(\.editMode, .constant(.active))
        .frame(maxHeight: 220)
    }

    private var controls: some View {
        HStack(spacing: 18) {
            editorButton("Rotate", systemImage: "rotate.right") {
                guard pages.indices.contains(selectedIndex) else { return }
                pages[selectedIndex] = ScanPageEditing.rotating(pages[selectedIndex])
                selectedPageID = pages[selectedIndex].id
                onChange()
            }
            editorButton("Recrop", systemImage: "crop") {
                guard pages.indices.contains(selectedIndex) else { return }
                cropPage = pages[selectedIndex]
            }
            editorButton("Remove", systemImage: "trash", role: .destructive) {
                guard pages.indices.contains(selectedIndex) else { return }
                let selectedID = selectedPageID ?? pages[selectedIndex].id
                let result = ScanPageEditing.removing(
                    pages,
                    at: selectedIndex,
                    selectedPageID: selectedID
                )
                pages = result.pages
                selectedPageID = result.selectedPageID
                selectedIndex = selectedPageID.flatMap { id in
                    pages.firstIndex { $0.id == id }
                } ?? 0
                onChange()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func editorButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func editorDescription(for page: ScanPageBuffer) -> String {
        var details: [String] = []
        if page.edit.rotationDegrees != 0 {
            details.append("Rotation \(page.edit.rotationDegrees) degrees")
        }
        if page.edit.crop != .fullPage {
            details.append("Cropped")
        }
        return details.isEmpty ? "Original" : details.joined(separator: ", ")
    }

    private func normalizeSelection() {
        guard !pages.isEmpty else {
            selectedPageID = nil
            selectedIndex = 0
            return
        }
        if let selectedPageID,
           let index = pages.firstIndex(where: { $0.id == selectedPageID }) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, pages.count - 1)
            selectedPageID = pages[selectedIndex].id
        }
    }
}

/// A compact native crop surface. Drag on the page to draw the crop region;
/// applying it only updates normalized manifest values.
private struct ScanCropSheet: View {
    let page: ScanPageBuffer
    let onApply: (ScanCrop) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var crop = ScanCrop.fullPage
    @State private var dragStart: CGPoint?
    @State private var previewImage: UIImage?
    @State private var previewFailed = false

    private var uncroppedPage: ScanPageBuffer {
        ScanPageBuffer(
            id: page.id,
            data: page.data,
            edit: ScanPageEdit(rotationDegrees: page.edit.rotationDegrees)
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let imageRect = fittedRect(
                    imageSize: previewImage?.size ?? CGSize(width: 1, height: 1),
                    in: proxy.size
                )
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                    } else if previewFailed {
                        ContentUnavailableView("Preview Unavailable", systemImage: "exclamationmark.triangle")
                    }
                    Color.clear
                        .frame(width: imageRect.width, height: imageRect.height)
                        // Name the fixed image-sized space before positioning
                        // it in the letterboxed canvas.
                        .coordinateSpace(name: "cropImage")
                        .position(x: imageRect.midX, y: imageRect.midY)
                        .contentShape(Rectangle())
                        .gesture(drawGesture(canvasSize: imageRect.size))
                    Rectangle()
                        .stroke(.yellow, lineWidth: 3)
                        .frame(
                            width: imageRect.width * crop.width,
                            height: imageRect.height * crop.height
                        )
                        .position(
                            x: imageRect.minX + imageRect.width * (crop.x + crop.width / 2),
                            y: imageRect.minY + imageRect.height * (crop.y + crop.height / 2)
                        )
                }
            }
            .navigationTitle("Recrop Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(crop.clamped)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { crop = page.edit.crop }
        .task(id: uncroppedPage.previewKey) {
            previewImage = nil
            previewFailed = false
            do {
                let data = try await ScanPageRenderer.previewData(for: uncroppedPage, maxDimension: 1_600)
                guard !Task.isCancelled else { return }
                previewImage = UIImage(data: data)
            } catch {
                guard !Task.isCancelled else { return }
                previewImage = nil
                previewFailed = true
            }
        }
    }

    private func drawGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("cropImage"))
            .onChanged { value in
                let start = dragStart ?? value.startLocation
                dragStart = start
                crop = ScanPageEditing.crop(from: start, to: value.location, in: canvasSize)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
