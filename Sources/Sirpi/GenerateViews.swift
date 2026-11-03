import SwiftUI
import AppKit

// MARK: - Viewport

struct GenerateViewport: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let b = app.brief {
            BriefView(brief: b)
        } else if let ed = app.sceneEditor, ed.assetID == app.selectedAssetID {
            SceneEditorViewport(editor: ed)
        } else if app.generator.isRunning && app.selectedAssetID == nil {
            GeneratingStream()
        } else if let a = app.selectedAsset {
            AssetPreview(asset: a)
        } else {
            GeometryReader { geo in Composer(width: geo.size.width) }
        }
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var app
    var width: CGFloat = 900
    @AppStorage(SettingKey.enableThinking) private var thinking = true
    @FocusState private var focused: Bool
    @State private var dropTargeted = false
    @AppStorage(AssetPurpose.key) private var purposeRaw = AssetPurpose.game.rawValue
    private var purpose: AssetPurpose { AssetPurpose(rawValue: purposeRaw) ?? .game }

    private let sceneChips: [(String, String)] = [
        ("Night street", "Build a narrow European street at night with lit shop fronts, street lamps, parked bikes and benches."),
        ("Cosy living room", "Build a cosy living room with a sofa, rug, coffee table, bookshelf, window and floor lamp."),
        ("Village square", "Build a village square with a fountain, market stalls, cobblestones and timber houses."),
        ("Kitchen", "Build a small modern kitchen with counters, cabinets, an oven, a fridge and a dining table."),
        ("Park", "Build a small park with trees, paths, benches, a pond and street lamps."),
        ("Sci-fi corridor", "Build a sci-fi space station corridor with doors, pipes, panels and lights."),
    ]

    private let printChips: [(String, String)] = [
        ("Phone stand", "Create a phone stand that holds a phone at 60 degrees, 80 mm wide."),
        ("Pen holder", "Create a hexagonal pen holder, 90 mm tall."),
        ("Planter", "Create a small plant pot with a drainage hole, 70 mm tall."),
        ("Cable organizer", "Create a desk cable organizer with five slots, 100 mm long."),
        ("Key hook", "Create a wall hook for keys, 60 mm tall, with two screw holes."),
        ("Dice tower", "Create a dice tower for tabletop games, 150 mm tall."),
        ("Chess rook", "Create a chess rook piece, 50 mm tall."),
        ("Fox figurine", "Create a low-poly fox figurine, 80 mm tall, standing on a base."),
    ]

    private var canGenerate: Bool {
        (!app.composerText.trimmingCharacters(in: .whitespaces).isEmpty || app.composerImage != nil)
            && app.engineReady && !app.generator.isRunning
    }
    private var examples: some View {
        Menu {
            ForEach(examplePrompts) { e in Button("\(e.domain): \(e.text)") { app.composerText = e.text } }
        } label: { Label("Examples", systemImage: "wand.and.stars") }
        .menuStyle(.button).buttonStyle(.glass).fixedSize()
    }
    private var think: some View {
        Toggle("Think first", isOn: $thinking).toggleStyle(.switch).tint(Theme.accent).controlSize(.small).fixedSize()
    }
    private func generateButton(fullWidth: Bool) -> some View {
        PrimaryButton(title: "Generate", systemImage: "sparkles", fullWidth: fullWidth) { app.generate() }
            .disabled(!canGenerate)
    }

    private let chips: [(String, String)] = [
        ("Village blacksmith", "Create a village blacksmith wearing a blue apron."),
        ("Swamp goblin scout", "Create a swamp goblin scout with a wooden shield."),
        ("Short iron sword", "Create a short iron sword with a leather-wrapped grip."),
        ("Mana potion", "Create a blue mana potion in a hexagonal glass bottle."),
        ("Pine tree on rocks", "Create a pine tree growing on a rocky mound."),
        ("Cargo airship", "Create a small cargo airship with twin propellers."),
        ("Spiked floor trap", "Create a hidden spiked floor trap with stone tiles."),
        ("Dungeon doorway", "Create a stone dungeon doorway module with an iron frame."),
    ]

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 18) {
            Text(purpose == .print ? "What should we print?" : purpose == .scene ? "What should we build?" : "What should we make?")
                .font(.system(size: width < 520 ? 22 : 28, weight: .semibold))
            Text("Describe one game asset in plain English. \(app.provider.kind == .local ? "The 3D Coder model" : app.provider.name) writes a Three.js scene you can export as GLB or print. Attach a picture to model it from a reference.")
                .font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: 520, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Picker("Purpose", selection: $purposeRaw) {
                    ForEach(AssetPurpose.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Game asset: a GLB for Godot. 3D print: a solid, watertight part at real size in mm, ready to slice.")
                TextField(app.composerImage == nil
                          ? (purpose == .print ? "A hexagonal pen holder, 90 mm tall"
                             : purpose == .scene ? "A narrow street at night with lit shop fronts and street lamps"
                             : "A stone golem boss with glowing green crystals")
                                                    : "Optional: what to make from the picture, e.g. a game prop version",
                          text: $app.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(3...8)
                    .focused($focused)
                    .padding(.horizontal, 4).padding(.top, 4)
                    .accessibilityLabel("Asset description")
                if let img = app.composerImage { ReferenceChip(image: img) { app.composerImage = nil } }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        examples; PictureButton(); DetailMenu(); ProviderMenu()
                        Spacer(minLength: 8)
                        think
                        generateButton(fullWidth: false)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) { examples; PictureButton(); DetailMenu(); ProviderMenu() }
                        HStack { think; Spacer(minLength: 8); generateButton(fullWidth: false) }
                    }
                    // Narrowest: one control per row.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) { examples; PictureButton() }
                        DetailMenu()
                        ProviderMenu(fullWidth: true)
                        think
                        generateButton(fullWidth: true)
                    }
                }
            }
            .padding(14)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .overlay { Label("Drop a reference picture", systemImage: "photo").padding(10).glassEffect(.regular, in: .capsule) }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let img = ReferenceImage(url: url) else { return false }
                app.composerImage = img
                return true
            } isTargeted: { dropTargeted = $0 }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            FlowLayout(spacing: 8) {
                ForEach(purpose == .print ? printChips : purpose == .scene ? sceneChips : chips, id: \.0) { chip in
                    Button(chip.0) { app.composerText = chip.1; focused = true }.buttonStyle(.glass)
                }
            }

            if let problem = app.engineProblem {
                let loading = app.provider.kind == .local && app.server.state == .starting
                HStack(spacing: 10) {
                    Label(problem, systemImage: loading ? "hourglass" : "exclamationmark.triangle")
                        .foregroundStyle(loading ? Color.secondary : Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    if !loading { SettingsLink { Text("Open Settings") }.buttonStyle(.glass).controlSize(.small) }
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, width < 520 ? 20 : 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { focused = true }
    }
}

struct GeneratingStream: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let g = app.generator
        VStack(alignment: .leading, spacing: 18) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ViewThatFits(in: .horizontal) {
                    pills(g, connector: 40)
                    pills(g, connector: 16)
                }
            }
            if let ref = g.reference {
                HStack(spacing: 10) {
                    Image(nsImage: ref.thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(g.statusNote ?? "Modelling from the reference picture").foregroundStyle(.secondary)
                    if g.statusNote != nil { ProgressView().controlSize(.small) }
                }
            }
            if g.reasoning.isEmpty {
                pane(title: "Code", count: g.codeTokens, text: g.content, tint: true,
                     placeholder: "Waiting for \(g.engineLabel.isEmpty ? "the model" : g.engineLabel)…")
            } else {
                // Plan above, code below; the bar between them drags to share the height.
                ResizablePanel(key: "streamPlan", defaultHeight: 200, range: 70...620) {
                    pane(title: "Plan", count: g.reasoningTokens, text: g.reasoning, tint: false, placeholder: "")
                }
                pane(title: "Code", count: g.codeTokens, text: g.content, tint: true,
                     placeholder: "Code starts when planning finishes.")
            }
        }
        .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pills(_ g: Generator, connector: CGFloat) -> some View {
        HStack(spacing: 12) {
            StepPill(state: g.phase == .waiting ? .pending : (g.phase == .thinking ? .active : .done),
                     title: g.phase == .thinking ? "Planning" : "Planned",
                     time: duration(from: g.thinkingStarted, to: g.writingStarted))
            Rectangle().fill(.white.opacity(0.14)).frame(width: connector, height: 1)
            StepPill(state: g.phase == .writing ? .active : .pending, title: "Writing code",
                     time: duration(from: g.writingStarted, to: nil))
            Rectangle().fill(.white.opacity(0.14)).frame(width: connector, height: 1)
            StepPill(state: .pending, title: "Preview", time: nil)
        }
        .fixedSize()
    }

    private func pane(title: String, count: Int, text: String, tint: Bool, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                if count > 0 { Text("\(count.formatted()) tokens").font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.tertiary)
                } else {
                    StreamText(text: text, tint: tint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        }
    }

    private func duration(from: Date?, to: Date?) -> String? {
        guard let from else { return nil }
        return formatDuration((to ?? Date()).timeIntervalSince(from))
    }
}

struct StepPill: View {
    enum S { case pending, active, done }
    let state: S
    let title: String
    let time: String?
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(Theme.accent.opacity(0.16))
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                case .active:
                    ProgressView().controlSize(.small).tint(Theme.accent)
                case .pending:
                    Circle().strokeBorder(.white.opacity(0.16))
                }
            }
            .frame(width: 26, height: 26)
            Text(title).fontWeight(state == .pending ? .regular : .semibold)
                .foregroundStyle(state == .pending ? .secondary : .primary)
            if let time { Text(time).monospacedDigit().foregroundStyle(.secondary) }
        }
    }
}

/// Monospaced, auto-scrolling text for streamed output.
struct StreamText: View {
    let text: String
    var tint = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Only the tail is laid out: re-shaping tens of KB of text on every streamed token
                    // grew memory and CPU steadily during long generations. Selection is off for the same reason.
                    Text("\(Text(Self.tail(text)))\(Text(" ▍").foregroundStyle(Theme.accent))")
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(4)
                        .foregroundStyle(Color(hex: tint ? "C9CBD1" : "A4A7AF"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: text.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    /// Last ~5 000 characters, starting at a line break so the view never opens mid-line.
    static func tail(_ s: String, limit: Int = 5_000) -> Substring {
        guard s.count > limit else { return Substring(s) }
        let cut = s.suffix(limit)
        if let nl = cut.firstIndex(of: "\n") { return cut[cut.index(after: nl)...] }
        return cut
    }
}

struct AssetPreview: View {
    @Environment(AppModel.self) private var app
    let asset: Asset
    var body: some View {
        ZStack(alignment: .bottom) {
            ForgeWebView(controller: app.preview)
                .overlay { if app.preview.isLoading { ProgressView() } }
            ViewportToolbar {
                Button { app.preview.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload preview")
                Button { NSWorkspace.shared.open(asset.htmlURL) } label: { Image(systemName: "safari") }.help("Open in browser")
                ViewportDivider()
                Button { Task { await app.exportGLB() } } label: { Label("Export GLB", systemImage: "square.and.arrow.up") }
            }
            .padding(.bottom, 18)
        }
        .task(id: asset.id) { load() }
    }

    private func load() {
        if app.preview.loadedURL != asset.pageURL { app.preview.load(asset.pageURL) }
        let a = asset
        app.preview.onFinish = { [weak lib = app.library, preview = app.preview] in
            guard !FileManager.default.fileExists(atPath: a.thumbURL.path) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                guard preview.loadedURL == a.pageURL, let img = await preview.snapshot(),
                      let png = img.pngThumbnail(maxSide: 160) else { return }
                lib?.write(png, to: a.thumbURL)
            }
        }
        app.preview.onDownload = { [lib = app.library, preview = app.preview] _, data in
            // Only keep bytes that came from this asset's own page.
            guard preview.loadedURL == a.pageURL else { return }
            lib.write(data, to: a.glbURL)
        }
    }
}

// MARK: - Inspector

struct GenerateInspector: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let ed = app.sceneEditor, ed.assetID == app.selectedAssetID {
            SceneInspector(editor: ed)
        } else if app.generator.isRunning && app.selectedAssetID == nil {
            GeneratingInspector()
        } else if let a = app.selectedAsset {
            AssetInspector(asset: a)
        } else {
            ModelInspector()
        }
    }
}

struct ModelInspector: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          ScrollView {
           VStack(alignment: .leading, spacing: 0) {
            let provider = app.provider
            VStack(alignment: .leading, spacing: 8) {
                Text("Writes the asset").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                ProviderMenu(fullWidth: true)
            }
            .padding(16)
            if provider.kind == .local {
                InspectorSection(title: "Qwen3.5 4B GLB 3D Coder") {
                    let _ = app.server.activeModel
                    Text(isNative ? "Runs inside Sirpi with MLX." : "Runs on this Mac with llama.cpp.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    KeyValueRow(key: "Weights", value: Self.weights)
                    KeyValueRow(key: "Speed", value: Self.speed)
                    KeyValueRow(key: "Typical asset", value: Self.typical)
                    KeyValueRow(key: "Context", value: "\(Settings.contextSize / 1024)K")
                }
            } else {
                InspectorSection(title: provider.name) {
                    if !provider.note.isEmpty {
                        Text(provider.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    KeyValueRow(key: "Model", value: ProviderSettings.model(provider).isEmpty ? "Default" : ProviderSettings.model(provider), mono: false)
                    if let problem = app.engineProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("Ready", systemImage: "checkmark.circle").foregroundStyle(Theme.accent)
                    }
                }
            }
            InspectorSection(title: "Thinking") {
                Text("The model plans the asset before writing code. Turn it off for drafts in roughly half the time.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            InspectorSection(title: "Works best with") {
                Text("Short English prompts that name one object, a material and a colour.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(["Create a tiny fox companion wearing a red scarf.", "Build a weathered snow siege platform"], id: \.self) { p in
                    Button { app.composerText = p } label: {
                        Text(p).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cell))
                    }
                    .buttonStyle(.plain)
                }
            }
           }
          }
            InspectorSection {
                HStack {
                    Text(footerText).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    SettingsLink { Text("Settings") }.buttonStyle(.glass)
                }
            }
        }
    }
}

extension ModelInspector {
    static var model: String { (Settings.modelPath as NSString).lastPathComponent }
    var isNative: Bool { _ = app.server.activeModel; return app.server.usesNative }
    var footerText: String {
        switch app.provider.kind {
        case .local: isNative ? "In-app · no server" : "Server on port \(String(Settings.port))"
        case .cli: "Runs the \(ProviderSettings.executable(app.provider)) CLI"
        case .openAI, .anthropic: app.provider.needsKey ? "Cloud API" : "Local server"
        }
    }
    static var weights: String {
        switch model {
        case "mlx-4bit": "MLX 4-bit · 2.2 GB"
        case "mlx-6bit": "MLX 6-bit · 3.2 GB"
        default: model.contains("Q4") ? "Q4_K_M · 2.6 GB" : "Q8_0 · 4.2 GB"
        }
    }
    static var speed: String {
        switch model {
        case "mlx-4bit": "about 83 tok/s"
        case "mlx-6bit": "about 61 tok/s"
        default: model.contains("Q4") ? "about 58 tok/s" : "about 43 tok/s"
        }
    }
    static var typical: String { model == "mlx-4bit" ? "2 to 4 min" : model == "mlx-6bit" ? "3 to 5 min" : "5 to 8 min" }
}

struct GeneratingInspector: View {
    @Environment(AppModel.self) private var app
    @State private var showReasoning = false
    var body: some View {
        let g = app.generator
        VStack(alignment: .leading, spacing: 0) {
          ScrollView {
           VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt").font(.headline)
                Text(g.title).padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cell))
            }
            .padding(16)
            InspectorSection(title: "Live") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 10) {
                        KeyValueRow(key: "Elapsed", value: formatDuration(g.elapsed))
                        KeyValueRow(key: "Planning tokens", value: g.reasoningTokens.formatted())
                        KeyValueRow(key: "Code tokens", value: g.codeTokens.formatted())
                        KeyValueRow(key: "Speed", value: "\(Int(g.tokensPerSecond)) tok/s")
                        KeyValueRow(key: "Engine", value: g.engineLabel, mono: false)
                    }
                }
            }
            InspectorSection(title: "Reasoning") {
                Button(showReasoning ? "Hide reasoning" : "Show full reasoning") { showReasoning.toggle() }.buttonStyle(.glass)
                if showReasoning {
                    ResizablePanel(key: "inspectorReasoning", defaultHeight: 220, range: 100...700) {
                        StreamText(text: g.reasoning)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cell))
                    }
                }
            }
            InspectorSection {
                Label("Keep working. You get a notification when the preview is ready.", systemImage: "bell")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
           }
          }
            InspectorSection {
                Button(role: .destructive) { app.stopGenerating() } label: {
                    Label("Stop generating", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass).controlSize(.large).tint(Theme.destructive)
                .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

struct AssetInspector: View {
    @Environment(AppModel.self) private var app
    let asset: Asset
    @State private var refinement = ""
    @FocusState private var refineFocused: Bool
    @AppStorage("exportLightmapUVs") private var lightmapUVs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.refinement.map { "Refined: \($0)" } ?? asset.prompt).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let s = asset.genSeconds {
                            Text("Generated in \(formatDuration(s))\(asset.tokens.map { " from \($0.formatted()) tokens" } ?? "")")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let e = asset.engine {
                                Label(e, systemImage: "cpu").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } else if asset.imported == true {
                            Text("Imported GLB").foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)

                    InspectorSection {
                        Button { Task { await app.customise(asset) } } label: {
                            Label(asset.purpose == "scene" ? "Customise scene" : "Customise parts",
                                  systemImage: "slider.horizontal.below.square.and.square.filled")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass).controlSize(.large)
                        Text(asset.purpose == "scene" ? "Move, recolour, duplicate or remove objects, and add assets from your library."
                             : "Move, recolour or remove individual parts.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    if asset.hasReference == true, let ref = NSImage(contentsOf: asset.referenceURL) {
                        InspectorSection(title: "Reference picture") {
                            Image(nsImage: ref).resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    DetailSection(asset: asset)

                    if asset.imported != true {
                        InspectorSection(title: "Refine") {
                            ResizablePanel(key: "refineEditor", defaultHeight: 84, range: 56...360) {
                                TextEditor(text: $refinement)
                                    .font(.body)
                                    .scrollContentBackground(.hidden)
                                    .focused($refineFocused)
                                    .padding(.horizontal, 6).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cell))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(refineFocused ? Theme.accent.opacity(0.5) : Theme.hairline))
                                    .overlay(alignment: .topLeading) {
                                        if refinement.isEmpty {
                                            Text("Make the scarf longer and add a small bell")
                                                .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .onKeyPress(.return, phases: .down) { press in
                                        guard press.modifiers.contains(.command) else { return .ignored }
                                        apply(); return .handled
                                    }
                            }
                            HStack {
                                Text("⌘↩ creates a new version").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 8)
                                Button("Apply") { apply() }.buttonStyle(.glass)
                                    .disabled(refinement.trimmingCharacters(in: .whitespaces).isEmpty || !app.engineReady || app.generator.isRunning)
                            }
                        }
                    }

                    InspectorSection(title: "Check") {
                        if app.preview.errors.isEmpty {
                            Label {
                                Text(app.preview.isLoading ? "Loading preview" : "No script errors")
                            } icon: {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                                    .frame(width: 22, height: 22).background(Circle().fill(Theme.accent.opacity(0.16)))
                            }
                        } else {
                            Label("\(app.preview.errors.count) script error\(app.preview.errors.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.warning)
                            ForEach(app.preview.errors.prefix(4), id: \.self) {
                                Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                            }
                            Button("Fix with 3D Coder") { app.fixErrors() }.buttonStyle(.glass)
                                .disabled(!app.engineReady || app.generator.isRunning)
                        }
                        if app.prep.assetID == asset.id && app.prep.triangles > 0 {
                            KeyValueRow(key: "Triangles", value: app.prep.triangles.formatted())
                        }
                    }

                    InspectorSection(title: "Export") {
                        Toggle(isOn: $lightmapUVs) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add lightmap UVs")
                                Text("A second UV set (UV2) so Godot can bake lighting with LightmapGI.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch).tint(Theme.accent).controlSize(.small)
                        .accessibilityLabel("Add lightmap UVs")
                        VStack(spacing: 8) {
                            Button { Task { await app.exportGLB() } } label: {
                                Label("Save GLB file…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button { Task { await app.exportOBJ() } } label: {
                                Label("Save OBJ file (with colours)…", systemImage: "cube").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button { Task { await app.openInBlender() } } label: {
                                Label("Open in Blender", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .help(Blender.installed ? "Opens Blender with this asset imported" : Blender.installHelp)
                            Button { Task { await app.saveBlendFile() } } label: {
                                Label("Save Blender file (.blend)…", systemImage: "doc.badge.arrow.up").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .help(Blender.installed ? "Saves a .blend using Blender in the background" : Blender.installHelp)
                            Button { Task { await app.copyToGodot() } } label: {
                                Label("Copy to Godot project", systemImage: "gamecontroller").frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            InspectorSection {
                PrimaryButton(title: "Prepare for print", systemImage: "arrow.right", fullWidth: true) { app.go(.prepare) }
            }
        }
        .onChange(of: app.refineFocusToken) { _, _ in refineFocused = true }
    }

    private func apply() {
        let r = refinement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        refinement = ""
        app.refine(r)
    }
}

// MARK: - Follow-up questions

struct BriefView: View {
    @Environment(AppModel.self) private var app
    @Bindable var brief: Brief
    @AppStorage(Brief.enabledKey) private var alwaysAsk = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A few details first").font(.system(size: 26, weight: .semibold))
                    Text(brief.prompt).font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if brief.loading {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Reading your request…", systemImage: "sparkles").foregroundStyle(.secondary)
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 10) {
                                RoundedRectangle(cornerRadius: 5).fill(Theme.cell).frame(width: 220, height: 14)
                                HStack { ForEach(0..<3, id: \.self) { _ in Capsule().fill(Theme.cell).frame(width: 96, height: 28) } }
                            }
                        }
                    }
                    .redacted(reason: .placeholder)
                } else {
                    ForEach(brief.questions) { q in question(q) }
                }
                HStack(spacing: 12) {
                    Toggle("Always ask before generating", isOn: $alwaysAsk)
                        .toggleStyle(.switch).tint(Theme.accent).controlSize(.small).fixedSize()
                    Spacer(minLength: 12)
                    Button("Cancel") { app.cancelBrief() }.buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button("Skip questions") { app.finishBrief(skip: true) }.buttonStyle(.glass)
                    PrimaryButton(title: "Generate", systemImage: "sparkles") { app.finishBrief(skip: false) }
                        .disabled(brief.loading)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                if !brief.loading {
                    Text(brief.source == "built-in" ? "Standard questions." : "Questions written by \(brief.source).")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private func question(_ q: BriefQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(q.question).fontWeight(.semibold)
            FlowLayout(spacing: 8) {
                ForEach(q.options, id: \.self) { opt in
                    let on = brief.answers[q.id]?.contains(opt) == true
                    Button {
                        var set = brief.answers[q.id] ?? []
                        if on { set.remove(opt) } else {
                            if !q.multi { set.removeAll() }
                            set.insert(opt)
                        }
                        brief.answers[q.id] = set
                    } label: {
                        Label(opt, systemImage: on ? "checkmark" : "circle").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glass)
                    .tint(on ? Theme.accent : nil)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            TextField("Something else…", text: Binding(get: { brief.notes[q.id] ?? "" }, set: { brief.notes[q.id] = $0 }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
        }
    }
}

// MARK: - Smooth & add detail

struct DetailSection: View {
    @Environment(AppModel.self) private var app
    let asset: Asset
    @AppStorage("enhanceLevels") private var levels = 2
    @AppStorage("enhanceCrease") private var crease = 50.0
    var body: some View {
        InspectorSection(title: "Smooth & add detail") {
            Text("Subdivides every part: round shapes become smooth, edges sharper than the angle below stay crisp. Saved as a new version.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Detail", selection: $levels) {
                Text("×4").tag(1); Text("×16").tag(2); Text("×64").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                Text("Keep edges over").foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(crease))°").monospacedDigit()
            }
            Slider(value: $crease, in: 20...90, step: 5).labelsHidden()
            Button {
                Task { await app.enhanceDetail(levels: levels, creaseAngle: crease) }
            } label: {
                HStack {
                    if app.enhancing { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                    Text(app.enhancing ? "Adding detail…" : "Smooth & add detail").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.glass).disabled(app.enhancing)
        }
    }
}

// MARK: - Reference picture and detail controls

struct PictureButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Menu {
            Button("Choose Picture…", systemImage: "photo") { if let img = ReferenceImage.choose() { app.composerImage = img } }
            Button("Paste Picture", systemImage: "doc.on.clipboard") {
                if let img = ReferenceImage.fromPasteboard() { app.composerImage = img } else { app.alert = "The clipboard has no picture." }
            }
            if app.composerImage != nil {
                Divider()
                Button("Remove Picture", systemImage: "xmark", role: .destructive) { app.composerImage = nil }
            }
        } label: {
            Label(app.composerImage == nil ? "Picture" : "Picture ✓", systemImage: "photo.badge.plus")
        }
        .menuStyle(.button).buttonStyle(.glass).fixedSize()
        .help("Generate from a reference picture (or drop one on the box)")
    }
}

struct ReferenceChip: View {
    @Environment(AppModel.self) private var app
    let image: ReferenceImage
    var onRemove: () -> Void
    var body: some View {
        let p = app.provider
        HStack(spacing: 12) {
            Image(nsImage: image.thumbnail).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            VStack(alignment: .leading, spacing: 2) {
                Text("Reference picture").fontWeight(.medium)
                Text(p.seesImages ? "\(p.name) sees the picture directly."
                     : "\(ImageDescriber.describer?.name ?? "A vision model") describes it for \(p.kind == .local ? "the 3D Coder" : p.name) first.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !p.seesImages && ImageDescriber.describer == nil {
                    Text("No vision model available: install Claude Code or add an API key.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Spacer(minLength: 0)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove picture")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cell))
    }
}

struct DetailMenu: View {
    @AppStorage(DetailLevel.key) private var level = 0
    var body: some View {
        let current = DetailLevel(rawValue: level) ?? .lowPoly
        Menu {
            Picker("Detail", selection: $level) {
                ForEach(DetailLevel.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(current.title, systemImage: current.symbol)
        }
        .menuStyle(.button).buttonStyle(.glass).fixedSize()
        .help("How detailed the generated model should be")
    }
}

// MARK: - Provider menu

/// Picks who writes the asset: the local 3D Coder, a coding-agent CLI or a cloud API.
struct ProviderMenu: View {
    @Environment(AppModel.self) private var app
    var fullWidth = false
    var body: some View {
        let current = app.provider
        let clis = app.clis
        Menu {
            Section("On this Mac") {
                Button { app.selectProvider(Providers.local.id) } label: {
                    Label(Providers.local.name, systemImage: current.id == "local" ? "checkmark" : "cpu")
                }
            }
            Section("Coding agents you're signed in to") {
                ForEach(clis.installed) { p in
                    let info = clis.info[p.id]
                    let models = info?.models ?? []
                    if models.isEmpty {
                        Button { app.select(p, model: nil) } label: {
                            Label("\(p.name) · \(clis.status(p))", systemImage: current.id == p.id ? "checkmark" : "terminal")
                        }
                    } else {
                        Menu {
                            Button("Default model") { app.select(p, model: "") }
                            Divider()
                            ForEach(models.prefix(60), id: \.self) { m in
                                Button { app.select(p, model: m) } label: {
                                    let on = current.id == p.id && ProviderSettings.model(p) == m
                                    if on { Label(m, systemImage: "checkmark") } else { Text(m) }
                                }
                            }
                        } label: {
                            Label("\(p.name) · \(clis.status(p))", systemImage: current.id == p.id ? "checkmark" : "terminal")
                        }
                    }
                }
                if clis.installed.isEmpty {
                    Text(clis.scanning ? "Looking for coding agents…" : "No coding-agent CLIs found")
                }
            }
            Section("Cloud APIs and local servers") {
                ForEach(Providers.all.filter { $0.kind == .anthropic || $0.kind == .openAI }) { p in
                    Button { app.selectProvider(p.id) } label: {
                        Label(p.name + (ProviderSettings.problem(p) == nil ? "" : " (set up)"),
                              systemImage: p.id == current.id ? "checkmark" : p.symbol)
                    }
                }
            }
            if !clis.missing.isEmpty {
                Menu("Not installed") {
                    ForEach(clis.missing) { p in Text(p.name) }
                }
            }
            Divider()
            Button("Rescan Coding Agents") { Task { await app.clis.scan() } }
            SettingsLink { Text("Provider Settings…") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: current.symbol)
                Text(shortName(current)).lineLimit(1)
                if app.engineProblem != nil && !(current.kind == .local && app.server.state == .starting) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warning)
                }
            }
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        }
        .menuStyle(.button).buttonStyle(.glass)
        .fixedSize(horizontal: !fullWidth, vertical: false)
        .help("Choose who writes the asset")
    }

    private func shortName(_ p: Provider) -> String {
        if p.kind == .local { return "3D Coder" }
        let m = ProviderSettings.model(p)
        guard !m.isEmpty, p.kind != .cli || !m.isEmpty else { return p.name }
        let tail = m.split(separator: "/").last.map(String.init) ?? m
        return "\(p.name) · \(tail.count > 18 ? String(tail.prefix(17)) + "…" : tail)"
    }
}

// MARK: - Helpers

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Treat zero/unbounded probes as the design width so the reported size stays stable across
        // the split view's min/max size passes (an unstable min size loops AppKit's constraint pass).
        let width = proposal.width.flatMap { $0.isFinite && $0 > 120 ? $0 : nil } ?? 680
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

extension NSImage {
    func pngThumbnail(maxSide: CGFloat) -> Data? {
        let side = min(size.width, size.height)
        guard side > 0 else { return nil }
        let src = NSRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        let target = min(maxSide, side)
        let out = NSImage(size: NSSize(width: target, height: target))
        out.lockFocus()
        draw(in: NSRect(origin: .zero, size: out.size), from: src, operation: .copy, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
