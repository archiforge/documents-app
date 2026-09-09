import SwiftUI

/// Tools board with a scanner hero, grouped file tools, and an explicit
/// capability state for deferred services. Every existing entry remains
/// visible; local AI routes explain temporary model states and offer retry.
struct ToolsTab: View {
    enum ToolRoute: Hashable {
        case pdfTools
        case formatConvert
        case convert(ConversionTarget)
        case stub(ToolItem)
        case ai(AIToolKind)
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
    @State private var showScanNoPages = false
    @State private var showCompress = false
    @State private var showExtract = false
    @State private var presentedDocument: PresentedDocument?
    @State private var toolMessage: ToolMessage?
    @State private var showToolMessage = false
    @State private var pendingDocument: PresentedDocument?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesAccessibilityLayout: Bool {
        switch dynamicTypeSize {
        case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            true
        default:
            false
        }
    }

    private var columns: [GridItem] {
        usesAccessibilityLayout
            ? [GridItem(.flexible(), spacing: 16)]
            : [GridItem(.adaptive(minimum: 136), spacing: 16)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    scanHero
                    toolSection("Core tools", tools: ToolItem.quickTools)
                    toolSection("File conversion", tools: ToolItem.fileConversion)
                    toolSection("Other tools", tools: ToolItem.supportingTools)
                    toolSection("AI tools", tools: ToolItem.aiTools)
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

    private var scanHero: some View {
        Button {
            select(ToolItem.scanHero)
        } label: {
            Group {
                if usesAccessibilityLayout {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            heroIcon
                            Spacer(minLength: 8)
                            heroChevron
                        }
                        heroText
                    }
                } else {
                    HStack(spacing: 16) {
                        heroIcon
                        heroText
                        Spacer(minLength: 8)
                        heroChevron
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.accentColor, .blue.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Scan Document")
        .accessibilityLabel("Scan Document")
        .accessibilityHint("Opens the scanner and photo import")
    }

    private var heroIcon: some View {
        Image(systemName: ToolItem.scanHero.symbol)
            .font(.system(size: 28, weight: .semibold))
            .frame(width: 56, height: 56)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ToolItem.scanHero.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Capture papers, documents, and ID cards")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroChevron: some View {
        Image(systemName: "chevron.right")
            .font(.headline.weight(.semibold))
    }

    private func toolSection(_ title: String, tools: [ToolItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(tools) { tool in
                    toolButton(tool)
                }
            }
        }
    }

    private func toolButton(_ tool: ToolItem) -> some View {
        VStack(spacing: 4) {
            Button {
                select(tool)
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: tool.symbol)
                        .font(.title2)
                        .foregroundStyle(
                            tool.capability.isAvailable ? Color.accentColor : Color.secondary
                        )
                        .frame(width: 56, height: 56)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    Text(tool.title)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: usesAccessibilityLayout ? 124 : 104, alignment: .top)
            }
            .buttonStyle(.plain)
            // AI routes remain open when the system model is preparing or
            // unavailable so the destination can explain the state and let
            // the user retry after changing device settings.
            .disabled(!tool.capability.isAvailable && !tool.isAITool)
            .accessibilityLabel(tool.title)
            .accessibilityValue(tool.capability.statusLabel)
            .accessibilityHint(tool.capability.reason ?? "Available")
            if let reason = tool.capability.reason {
                // Keep the explanation outside the disabled button so the
                // system's disabled opacity does not wash out the readable
                // reason while the button remains semantically unavailable.
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: usesAccessibilityLayout ? 176 : 132,
            alignment: .top
        )
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
        case .ai(let tool):
            AIFlowView(kind: tool)
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
        case .ai(let kind):
            route = .ai(kind)
        }
    }

    private func show(message: ToolMessage, document: PresentedDocument?) {
        pendingDocument = document
        toolMessage = message
        showToolMessage = true
    }

    /// Checks the app-private draft before presenting the direct camera. A
    /// saved draft must be reachable without forcing a new capture, and a
    /// camera-less device still enters the flow so PhotosPicker can provide
    /// the first page. Fresh camera-supported scans retain the direct-camera
    /// entry UX.
    private func openScanEntry(mode: ScanMode) {
        Task { @MainActor in
            let hasDraft: Bool
            do {
                hasDraft = try await ScanDraftStore.shared.load() != nil
            } catch {
                // A corrupt draft is still a draft: ScannerFlowView presents
                // its recovery/discard UI without overwriting it.
                hasDraft = true
            }

            switch ScanEntryRouting.route(
                hasDraft: hasDraft,
                cameraAvailable: ScanningService.isCameraAvailable
            ) {
            case .restoreDraft, .galleryFlow:
                flowEntry = ScanFlowEntry(mode: mode, pages: [], frontPages: [])
            case .directCamera:
                entryPass = makeEntryPass(mode: mode)
                scanRequest = ScanEntryRequest(mode: mode)
            }
        }
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
