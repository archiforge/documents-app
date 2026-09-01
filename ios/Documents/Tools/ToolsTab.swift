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
    /// App-icon quick actions: "Scan Document" and "New Text" land here.
    @Environment(QuickActionRouter.self) private var quickActions
    /// The direct camera pass: presented first on a scan-tool tap so the
    /// camera is the first thing on screen. `ScannerFlowView` takes over
    /// with the captured pages once this cover is fully gone.
    @State private var scanRequest: ScanEntryRequest?
    @State private var entryPass: ScanEntryPass?
    @State private var flowEntry: ScanFlowEntry?
    @State private var showCameraUnavailable = false
    @State private var showScanNoPages = false
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
            .fullScreenCover(item: $scanRequest, onDismiss: { scanEntryClosed() }) { request in
                if let pass = entryPass {
                    ScanEntryCameraCover(pass: pass)
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
            .fullScreenCover(item: $flowEntry) { entry in
                ScannerFlowView(
                    mode: entry.mode,
                    initialPages: entry.pages,
                    initialFrontPages: entry.frontPages
                ) { result in
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
            .alert("Camera unavailable", isPresented: $showCameraUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The document scanner needs a physical camera. Run Documents on an iPhone or iPad to scan.")
            }
            .alert("Scan Not Saved", isPresented: $showScanNoPages) {
                Button("Try Again") {
                    guard let mode = entryPass?.mode else { return }
                    entryPass = makeEntryPass(mode: mode)
                    scanRequest = ScanEntryRequest(mode: mode)
                }
                Button("Cancel", role: .cancel) { entryPass = nil }
            } message: {
                Text("The scanner closed without delivering a page, so nothing was stored. Try the scan again.")
            }
            .alert(
                "Scan failed",
                isPresented: Binding(
                    get: { entryPass?.failureMessage != nil },
                    set: { if !$0 { entryPass?.clearFailure() } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(entryPass?.failureMessage ?? "")
            }
            .documentViewer(item: $presentedDocument)
            .onAppear(perform: consumeQuickAction)
            .onChange(of: quickActions.pending) { _, _ in
                consumeQuickAction()
            }
        }
    }

    /// Fulfills the "Scan Document" and "New Text" app-icon quick actions
    /// when this tab is on screen; other destinations are left for their
    /// own tabs.
    private func consumeQuickAction() {
        guard let pending = quickActions.pending else { return }
        switch pending {
        case .scan:
            quickActions.pending = nil
            openScanEntry(mode: .document)
        case .newDocument:
            quickActions.pending = nil
            showNewDocument = true
        case .importFiles:
            break // Recent's importer handles it.
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
            openScanEntry(mode: mode)
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

    /// Presents the camera directly — no intermediate flow page. A fresh
    /// `ScanEntryPass` owns this pass's session and captured state.
    private func openScanEntry(mode: ScanMode) {
        guard ScanningService.isCameraAvailable else {
            showCameraUnavailable = true
            return
        }
        entryPass = makeEntryPass(mode: mode)
        scanRequest = ScanEntryRequest(mode: mode)
    }

    private func makeEntryPass(mode: ScanMode) -> ScanEntryPass {
        let pass = ScanEntryPass(mode: mode)
        pass.onCameraDismiss = { scanRequest = nil }
        return pass
    }

    /// Runs when the direct camera cover is fully gone — the only safe
    /// point to hand the capture to the flow, offer a retry, or reset.
    private func scanEntryClosed() {
        guard let pass = entryPass else { return }
        pass.session.detach()
        if pass.hasCapture {
            flowEntry = ScanFlowEntry(
                mode: pass.mode,
                pages: pass.pages,
                frontPages: pass.frontPages
            )
            return
        }
        if pass.scanDelivered {
            // Deliberate cancel or an empty delivery: nothing to show. Keep
            // the pass — a failure message still needs to surface through
            // the alert binding, and the next entry replaces it anyway.
            return
        }
        // The scanner closed without delivering any callback: offer a retry
        // instead of silently dropping the entry.
        showScanNoPages = true
    }
}

/// Item payload for the Tools tab's direct camera cover.
struct ScanEntryRequest: Identifiable {
    let id = UUID()
    let mode: ScanMode
}

/// Item payload for the flow handoff after the direct camera pass captured
/// pages (or an ID-card front side).
struct ScanFlowEntry: Identifiable {
    let id = UUID()
    let mode: ScanMode
    let pages: [UIImage]
    let frontPages: [UIImage]
}

/// The direct camera pass cover: pure backdrop plus the scanner. VisionKit's
/// own chrome provides the capture and cancel controls; the pass adds
/// nothing on top.
private struct ScanEntryCameraCover: View {
    let pass: ScanEntryPass

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DocumentScannerView(session: pass.session)
        }
    }
}
