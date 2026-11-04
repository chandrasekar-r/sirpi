import SwiftUI
import AppKit

// Settings follow the macOS System Settings pattern: a sidebar of panes, each a grouped form.
// One accent (lime) for the active choice, plain labels beside every field, status written in words.

enum SettingsPane: String, CaseIterable, Identifiable {
    case generation, agents, cloud, local, printer, slicer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .generation: "Generation"
        case .agents: "Coding Agents"
        case .cloud: "Cloud APIs"
        case .local: "Local Model"
        case .printer: "Printer"
        case .slicer: "Slicer"
        }
    }
    var symbol: String {
        switch self {
        case .generation: "sparkles"
        case .agents: "terminal"
        case .cloud: "cloud"
        case .local: "cpu"
        case .printer: "printer"
        case .slicer: "square.stack.3d.up"
        }
    }
}

/// Settings panes, shown in the main window's sidebar while Settings is open.
struct SettingsSidebar: View {
    @AppStorage("settingsPane") private var paneRaw = SettingsPane.generation.rawValue
    var body: some View {
        let pane = Binding<SettingsPane?>(get: { SettingsPane(rawValue: paneRaw) ?? .generation },
                                          set: { paneRaw = ($0 ?? .generation).rawValue })
        List(SettingsPane.allCases, selection: pane) { p in
            Label(p.title, systemImage: p.symbol).tag(p)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                ActiveEngineBadge().padding(.horizontal, 10)
                PageSwitcher()
            }
        }
    }
}

/// The open settings pane, shown in the main window.
struct SettingsView: View {
    @AppStorage("settingsPane") private var paneRaw = SettingsPane.generation.rawValue
    var body: some View {
        Group {
            switch SettingsPane(rawValue: paneRaw) ?? .generation {
            case .generation: GenerationPane()
            case .agents: AgentsPane()
            case .cloud: CloudPane()
            case .local: LocalModelPane()
            case .printer: PrinterPane()
            case .slicer: SlicerPane()
            }
        }
        .tint(Theme.accent) // switches and pickers in the panes use the app accent; the sidebar keeps the system one
    }
}

/// Opens a settings pane inside the main window (replaces SwiftUI's SettingsLink, which opens a separate window).
struct SettingsButton<Content: View>: View {
    @Environment(AppModel.self) private var app
    var pane: SettingsPane? = nil
    @ViewBuilder var label: () -> Content
    var body: some View {
        Button { app.openSettings(pane) } label: { label() }
    }
}

/// Bottom of the sidebar: who writes assets right now, and whether it can.
private struct ActiveEngineBadge: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let ok = app.engineProblem == nil
        VStack(alignment: .leading, spacing: 3) {
            Text("Writes assets").font(.caption).foregroundStyle(.secondary)
            Text(ProviderSettings.label(app.provider)).font(.callout.weight(.medium)).lineLimit(2)
            Label(ok ? "Ready" : "Needs attention", systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(ok ? Theme.accent : Theme.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cell))
    }
}

// MARK: - Generation

private struct GenerationPane: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AssetPurpose.key) private var purpose = AssetPurpose.game.rawValue
    @AppStorage(DetailLevel.key) private var detail = 0
    @AppStorage(Brief.enabledKey) private var askFirst = true
    @AppStorage(SettingKey.enableThinking) private var thinking = true
    @AppStorage(VisualCheck.enabledKey) private var pictureCheck = true
    @AppStorage(Patch.enabledKey) private var patchFixes = true
    @AppStorage("provider.maxOutputTokens") private var maxTokens = 32000

    var body: some View {
        Form {
            Section {
                Picker("Default purpose", selection: $purpose) {
                    ForEach(AssetPurpose.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                Picker("Detail", selection: $detail) {
                    ForEach(DetailLevel.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("Both can also be changed in the composer for each asset.")
            }
            Section {
                Toggle("Ask follow-up questions before generating", isOn: $askFirst)
                Toggle("Let the model think before writing code", isOn: $thinking)
            } footer: {
                Text("Follow-up questions are written by the fastest signed-in model (Claude Code with Haiku first). Thinking roughly doubles generation time; for the Claude API it switches between high and low effort.")
            }
            Section {
                Toggle("Review each new asset and fix what's off", isOn: $pictureCheck)
                Toggle("Apply fixes and refinements as small edits", isOn: $patchFixes)
            } footer: {
                Text("After each new asset, Sirpi renders it from four sides and asks a vision model to check it against your request, your answers to the follow-up questions and, if you attached one, the picture. Anything that falls short goes back as one quick fix; assets that score 8/10 or better are left alone. Needs Claude Code or a cloud API key for the vision check. Small edits change only the lines that need it, so a fix takes seconds instead of rewriting the whole file; if an edit doesn't match the code, Sirpi rewrites the file instead.")
            }
            Section("Cloud and agent output") {
                LabeledContent("Max output tokens") {
                    HStack(spacing: 8) {
                        Text(maxTokens.formatted()).monospacedDigit()
                        Stepper("Max output tokens", value: $maxTokens, in: 4000...128000, step: 4000).labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Coding agents (auto-detected CLIs)

private struct AgentsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let clis = app.clis
        Form {
            Section {
                if clis.installed.isEmpty {
                    if clis.scanning {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking for coding agents on this Mac…") }
                    } else {
                        Text("No coding-agent CLIs found. Install one below, sign in once in Terminal, then rescan.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(clis.installed) { p in AgentRow(provider: p) }
            } header: {
                HStack {
                    Text("Installed")
                    Spacer()
                    Button { Task { await app.clis.scan() } } label: {
                        Label(clis.scanning ? "Scanning" : "Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless).disabled(clis.scanning)
                }
            } footer: {
                Text("Sirpi runs each agent headless with the login it already has. Nothing is copied from your accounts.")
            }
            if !clis.missing.isEmpty {
                Section("Not installed") {
                    ForEach(clis.missing) { p in
                        LabeledContent(p.name) {
                            Text(installHint(p)).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func installHint(_ p: Provider) -> String {
        switch p.id {
        case "pi": "npm i -g @mariozechner/pi-coding-agent"
        case "gemini-cli": "npm i -g @google/gemini-cli"
        case "codex": "npm i -g @openai/codex"
        case "claude-code": "curl -fsSL https://claude.ai/install.sh | bash"
        case "opencode": "curl -fsSL https://opencode.ai/install | bash"
        default: "install \(p.executable)"
        }
    }
}

private struct AgentRow: View {
    @Environment(AppModel.self) private var app
    let provider: Provider
    @State private var model = ""

    var body: some View {
        let info = app.clis.info[provider.id]
        let inUse = app.provider.id == provider.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).fontWeight(.semibold)
                    Text(info?.path ?? "").font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if inUse {
                    Label("In use", systemImage: "checkmark").foregroundStyle(Theme.accent).font(.callout.weight(.medium))
                } else {
                    Button("Use") { app.select(provider, model: nil) }
                        .disabled(info?.signedIn == false)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: info?.signedIn == false ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
                    .foregroundStyle(info?.signedIn == false ? Theme.warning : .secondary)
                Text(app.clis.status(provider)).foregroundStyle(.secondary)
            }
            .font(.callout)
            if info?.signedIn == false {
                Text("Sign in once in Terminal: \(ProviderSettings.loginCommand(provider))")
                    .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            let models = info?.models ?? []
            Picker("Model", selection: $model) {
                Text("Agent default").tag("")
                if !model.isEmpty && !models.contains(model) { Text(model).tag(model) }
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: model) { _, m in
                UserDefaults.standard.set(m, forKey: "provider.\(provider.id).model")
                app.providerRevision += 1
            }
        }
        .padding(.vertical, 4)
        .onAppear { model = UserDefaults.standard.string(forKey: "provider.\(provider.id).model") ?? "" }
    }
}

// MARK: - Cloud APIs and local servers

private struct CloudPane: View {
    @Environment(AppModel.self) private var app
    @AppStorage("settingsCloudProvider") private var selected = "anthropic"
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var account = ""
    @State private var models: [String] = []
    @State private var status: String?
    @State private var testing = false

    private var apis: [Provider] { Providers.all.filter { $0.kind == .anthropic || $0.kind == .openAI } }

    var body: some View {
        let p = Providers.find(selected)
        Form {
            Section {
                Picker("Service", selection: $selected) {
                    Section("Cloud") { ForEach(apis.filter(\.needsKey)) { Text($0.name).tag($0.id) } }
                    Section("Local servers") { ForEach(apis.filter { !$0.needsKey }) { Text($0.name).tag($0.id) } }
                }
                if !p.note.isEmpty { Text(p.note).font(.callout).foregroundStyle(.secondary) }
            }
            Section("Connection") {
                LabeledContent("API key") {
                    HStack {
                        SecureField("API key", text: $key, prompt: Text(p.needsKey ? "Paste a key" : "Optional"))
                            .labelsHidden()
                        if let u = URL(string: p.keyURL), !p.keyURL.isEmpty { Link("Get a key", destination: u) }
                    }
                }
                if p.needsAccount {
                    LabeledContent("Account ID") {
                        TextField("Account ID", text: $account, prompt: Text("From the dashboard URL")).labelsHidden()
                    }
                }
                LabeledContent("Base URL") {
                    TextField("Base URL", text: $baseURL, prompt: Text(p.baseURL)).labelsHidden()
                }
                LabeledContent("Model") {
                    HStack {
                        TextField("Model", text: $model, prompt: Text(p.defaultModel.isEmpty ? "Model ID" : p.defaultModel)).labelsHidden()
                        if !models.isEmpty {
                            Menu("Choose") { ForEach(models, id: \.self) { m in Button(m) { model = m } } }.fixedSize()
                        }
                    }
                }
            }
            Section {
                HStack(spacing: 10) {
                    Button("Save") { save(p) }
                    Button("Test connection") { Task { await test(p) } }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    if app.provider.id == p.id {
                        Label("In use", systemImage: "checkmark").foregroundStyle(Theme.accent)
                    } else {
                        Button("Use for generation") { save(p); app.selectProvider(p.id) }
                            .disabled(ProviderSettings.problem(p) != nil)
                    }
                }
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else if let problem = ProviderSettings.problem(p) {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warning)
                }
            } footer: {
                Text("Keys are stored in a file only your user account can read. General-purpose models get extra rules so they return one standalone Three.js file.")
            }
        }
        .formStyle(.grouped)
        .onAppear { load(p) }
        .onChange(of: selected) { old, new in save(Providers.find(old)); load(Providers.find(new)) }
        .onDisappear { save(Providers.find(selected)) }
    }

    private func load(_ p: Provider) {
        let d = UserDefaults.standard
        key = ProviderSettings.apiKey(p)
        model = d.string(forKey: "provider.\(p.id).model") ?? ""
        baseURL = d.string(forKey: "provider.\(p.id).baseURL") ?? ""
        account = ProviderSettings.account(p)
        models = []; status = nil
    }

    private func save(_ p: Provider) {
        let d = UserDefaults.standard
        d.set(model.trimmingCharacters(in: .whitespaces), forKey: "provider.\(p.id).model")
        d.set(baseURL.trimmingCharacters(in: .whitespaces), forKey: "provider.\(p.id).baseURL")
        d.set(account.trimmingCharacters(in: .whitespaces), forKey: "provider.\(p.id).account")
        ProviderSettings.setAPIKey(key, for: p)
        app.providerRevision += 1
    }

    private func test(_ p: Provider) async {
        save(p)
        testing = true; status = nil
        defer { testing = false }
        do {
            models = try await RemoteEngine.listModels(p)
            status = models.isEmpty ? "Connected. The service did not list any models." : "Connected. \(models.count) models available."
        } catch {
            status = "Could not reach \(p.name): \(error.localizedDescription)"
        }
    }
}

// MARK: - Local model

private struct LocalModelPane: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingKey.modelPath) private var modelPath = ""
    @AppStorage(SettingKey.llamaServerPath) private var serverPath = ""
    @AppStorage(SettingKey.port) private var port = 8089
    @AppStorage(SettingKey.contextSize) private var ctx = 65536
    @AppStorage(SettingKey.temperature) private var temperature = 0.8
    @AppStorage(SettingKey.autoStartServer) private var autoStart = true

    var body: some View {
        Form {
            Section {
                Picker("Weights", selection: $modelPath) {
                    ForEach(localModels(), id: \.self) { Text(Self.label($0)).tag($0) }
                    if !localModels().contains(modelPath) { Text((modelPath as NSString).lastPathComponent).tag(modelPath) }
                }
                LabeledContent("Status", value: stateText)
                HStack {
                    if app.provider.id != "local" {
                        Button("Use for generation") { app.selectProvider("local") }
                    }
                    Button("Restart model") { Task { await app.server.restart() } }
                    Button("Add weights…") { choose() }
                }
            } footer: {
                Text("MLX models run inside the app on the GPU: 4-bit is fastest, 6-bit is closest to the original. GGUF files run through llama-server.")
            }
            Section("Downloads") {
                LabeledContent("MLX tuned 4-bit (recommended)") {
                    if NativeEngine.isMLXModel(ModelDownloader.tunedPath) { Text("Downloaded").foregroundStyle(.secondary) } else {
                        Button("Download") { app.downloader.fetchTuned { modelPath = ModelDownloader.tunedPath } }
                            .disabled(app.downloader.active)
                    }
                }
                ForEach(ModelDownloader.files, id: \.self) { f in
                    let exists = FileManager.default.fileExists(atPath: Paths.defaultModelDir.appendingPathComponent(f).path)
                    LabeledContent(quant(f) + " GGUF") {
                        if exists { Text("Downloaded").foregroundStyle(.secondary) } else {
                            Button("Download") { app.downloader.download(f) { modelPath = Paths.defaultModelDir.appendingPathComponent(f).path } }
                                .disabled(app.downloader.active)
                        }
                    }
                }
                if app.downloader.active { ProgressView(value: app.downloader.progress) }
                if let e = app.downloader.error { Text(e).foregroundStyle(Theme.warning).font(.callout) }
            }
            Section("Sampling") {
                Picker("Context", selection: $ctx) {
                    ForEach([16384, 32768, 49152, 65536, 131072, 262144], id: \.self) { Text("\($0 / 1024)K").tag($0) }
                }
                LabeledContent("Temperature") {
                    HStack {
                        Slider(value: $temperature, in: 0.1...1.2, step: 0.05).frame(maxWidth: 220)
                        Text(String(format: "%.2f", temperature)).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Load the model when Sirpi opens", isOn: $autoStart)
            }
            Section {
                DisclosureGroup("llama.cpp server") {
                    LabeledContent("llama-server") { TextField("Path", text: $serverPath).labelsHidden() }
                    LabeledContent("Port") { TextField("Port", value: $port, format: .number.grouping(.never)).labelsHidden().frame(width: 90) }
                }
                DisclosureGroup("Log") {
                    ResizablePanel(key: "serverLog", defaultHeight: 140, range: 80...420) {
                        ScrollView {
                            Text(app.server.log.suffix(120).joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } header: { Text("Advanced") }
        }
        .formStyle(.grouped)
        .onChange(of: modelPath) { _, _ in if app.provider.kind == .local { Task { await app.server.restart() } } }
    }

    var stateText: String {
        switch app.server.state {
        case .ready(let ext): ext ? "Using an already-running server" : "Loaded"
        case .starting: "Loading"
        case .stopped: "Not loaded"
        case .failed(let m): m
        }
    }

    static func label(_ path: String) -> String {
        let n = (path as NSString).lastPathComponent
        switch n {
        case "mlx-4bit": return "MLX 4-bit, in-app, fastest"
        case "mlx-6bit": return "MLX 6-bit, in-app, balanced"
        case "mlx-tuned-4bit": return "MLX tuned 4-bit, game + print"
        case "mlx-tuned-6bit": return "MLX tuned 6-bit, game + print"
        case "mlx-bf16", "mlx-tuned-bf16": return n + " (full precision, slow)"
        default: return n.hasSuffix(".gguf") ? "\(n) (llama-server)" : n
        }
    }

    func quant(_ f: String) -> String { f.contains("Q8") ? "Q8_0" : "Q4_K_M" }

    func localModels() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.defaultModelDir.path)) ?? []
        return files.filter { ($0.hasSuffix(".gguf") && !$0.hasPrefix("mmproj"))
                || NativeEngine.isMLXModel(Paths.defaultModelDir.appendingPathComponent($0).path) }
            .sorted { a, b in a.hasPrefix("mlx") != b.hasPrefix("mlx") ? a.hasPrefix("mlx") : a < b }
            .map { Paths.defaultModelDir.appendingPathComponent($0).path }
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowedContentTypes = [.data]
        p.directoryURL = Paths.defaultModelDir
        if p.runModal() == .OK, let u = p.url { modelPath = u.path }
    }
}

// MARK: - Printer

private struct PrinterPane: View {
    @Environment(AppModel.self) private var app
    @AppStorage(PrinterProfile.key) private var model = "P2S"
    @AppStorage(SettingKey.nozzle) private var nozzle = "0.4"

    var body: some View {
        let profile = PrinterProfile.current
        Form {
            Section {
                Picker("Printer", selection: $model) {
                    ForEach(PrinterProfile.all) { Text("Bambu Lab \($0.id)").tag($0.id) }
                }
                LabeledContent("Build volume", value: profile.volumeText + (profile.note.isEmpty ? "" : " (\(profile.note))"))
                Picker("Nozzle", selection: $nozzle) {
                    ForEach(["0.2", "0.4", "0.6", "0.8"], id: \.self) { Text("\($0) mm").tag($0) }
                }
            } header: {
                Text("Target")
            } footer: {
                Text("3D-print generations are sized to fit this volume, and Prepare draws this plate. Loaded AMS colours are used when the printer is connected.")
            }
            Section("Connection") {
                LabeledContent("Status", value: app.printer.connection == .connected ? "Connected, \(app.printer.status.stateLabel)" : "Not connected")
                PrinterSetupForm(compact: true)
            }
        }
        .formStyle(.grouped)
        .onChange(of: nozzle) { _, _ in app.slicer.refreshPresets() }
    }
}

// MARK: - Slicer

private struct SlicerPane: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingKey.bambuStudioPath) private var studio = ""
    var body: some View {
        Form {
            Section {
                LabeledContent("Bambu Studio") { TextField("App path", text: $studio).labelsHidden() }
                LabeledContent("Status", value: app.slicer.available
                               ? "Found, \(app.slicer.processes.count) process presets for this printer" : "Not found")
            } footer: {
                Text("Slicing runs Bambu Studio in the background with the presets for your printer and nozzle.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: studio) { _, _ in app.slicer.refreshPresets() }
    }
}
