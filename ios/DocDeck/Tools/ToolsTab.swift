import SwiftUI

/// Adaptive grid of tools. Increment 2 wires the scanner, PDF toolbox,
/// converters, and archives; Phase-3 items still push stub screens.
struct ToolsTab: View {
    enum ToolRoute: Hashable {
        case pdfTools
        case formatConvert
        case convert(ConversionTarget)
        case stub(ToolItem)
    }

    @State private var route: ToolRoute?
    @State private var showNewDocument = false
    @State private var scanMode: ScanMode?
    @State private var showCompress = false
    @State private var showExtract = false
    @State private var presentedDocument: PresentedDocument?
    @State private var toolMessage: ToolMessage?
    @State private var showToolMessage = false
    @State private var pendingDocument: PresentedDocument?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(ToolItem.all) { tool in
                        Button {
                            select(tool)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: tool.symbol)
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .frame(width: 56, height: 56)
                                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                                Text(tool.title)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2, reservesSpace: true)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Tools")
            .navigationDestination(item: $route) { route in
                destination(for: route)
            }
            .sheet(isPresented: $showNewDocument) {
                NewDocumentSheet { created in
                    presentedDocument = created
                }
            }
            .fullScreenCover(item: $scanMode) { mode in
                ScannerFlowView(mode: mode) { result in
                    presentedDocument = result
                }
            }
            .sheet(isPresented: $showCompress) {
                CompressSheet { message, document in
                    show(message: message, document: document)
                }
            }
            .sheet(isPresented: $showExtract) {
                ExtractSheet()
            }
            .alert(
                toolMessage?.title ?? "Done",
                isPresented: $showToolMessage,
                presenting: toolMessage
            ) { _ in
                if pendingDocument != nil {
                    Button("Open") {
                        if let document = pendingDocument {
                            presentedDocument = document
                        }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message.body)
            }
            .documentViewer(item: $presentedDocument)
        }
    }

    @ViewBuilder
    private func destination(for route: ToolRoute) -> some View {
        switch route {
        case .pdfTools:
            PDFToolsView(initialSource: nil)
        case .formatConvert:
            ConvertFlowView(fixedTarget: nil)
        case .convert(let target):
            ConvertFlowView(fixedTarget: target)
        case .stub(let tool):
            ToolStubView(tool: tool)
        }
    }

    private func select(_ tool: ToolItem) {
        switch tool.kind {
        case .newDocument:
            showNewDocument = true
        case .scan(let mode):
            scanMode = mode
        case .pdfTools:
            route = .pdfTools
        case .formatConvert:
            route = .formatConvert
        case .convert(let target):
            route = .convert(target)
        case .compress:
            showCompress = true
        case .extract:
            showExtract = true
        case .stub:
            route = .stub(tool)
        }
    }

    private func show(message: ToolMessage, document: PresentedDocument?) {
        pendingDocument = document
        toolMessage = message
        showToolMessage = true
    }
}
