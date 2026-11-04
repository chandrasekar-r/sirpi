import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

@main
struct SirpiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppModel()

    init() { Settings.registerDefaults() }

    var body: some Scene {
        WindowGroup("Sirpi") {
            RootView()
                .environment(app)
                .frame(minWidth: 740, minHeight: 560)
                .preferredColorScheme(.dark)
                .task { delegate.app = app; await app.boot() }
        }
        .windowToolbarStyle(.unified)
        .commands { ForgeCommands(app: app) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var app: AppModel?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Clicking a notification opens the asset at the stage it refers to.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = info["assetID"] as? String
        let stageRaw = info["stage"] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let id { app?.selectedAssetID = id }
            if let stageRaw, let stage = Stage(rawValue: stageRaw) { app?.stage = stage }
        }
    }
}

enum Stage: String, CaseIterable, Identifiable {
    case generate, prepare, slice, print
    var id: String { rawValue }
    var title: String {
        switch self { case .generate: "Generate"; case .prepare: "Prepare"; case .slice: "Slice"; case .print: "Print" }
    }
    var symbol: String {
        switch self { case .generate: "sparkles"; case .prepare: "cube"; case .slice: "square.3.layers.3d"; case .print: "printer" }
    }
}

enum AppPage { case workspace, settings, help }

// MARK: - App model

@Observable @MainActor
final class AppModel {
    var stage: Stage = .generate
    /// Settings and Help open inside the main window, in place of the library and stages.
    var page: AppPage = .workspace
    var helpTopic: HelpTopic = .start
    /// Whether the Print stage shows the live chamber camera.
    var showCamera = UserDefaults.standard.object(forKey: PrinterCamera.shownKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCamera, forKey: PrinterCamera.shownKey) }
    }
    var selectedAssetID: String? {
        didSet { if oldValue != selectedAssetID { pickMode = false; pickedPart = nil } }
    }
    var showInspector = true
    /// Live window width, for toolbar items that must shrink with the window.
    var windowWidth: CGFloat = 1200
    var showTasks = false
    var composerText = ""
    /// Picture attached in the composer to guide the next generation.
    var composerImage: ReferenceImage?
    /// Scene customiser for the selected asset (nil when not editing).
    var sceneEditor: SceneEditor?
    /// Follow-up questions shown before a generation starts (nil when not briefing).
    var brief: Brief?
    /// Set while "Smooth & add detail" runs.
    var enhancing = false
    /// Headless page that subdivides GLBs (created on first use).
    @ObservationIgnored private var enhanceWeb: WebController?
    /// Offscreen page that exports GLBs for the picture check without touching the visible preview.
    @ObservationIgnored private var checkWeb: WebController?
    /// Offscreen turntable renderer (turntable.html).
    @ObservationIgnored private var turntableWeb: WebController?
    @ObservationIgnored private var turntableBusy = false
    /// Asset whose turntable export sheet is open.
    var turntableAsset: Asset?
    var refineFocusToken = 0
    var showPrintSheet = false
    var confirmStopPrint = false
    var alert: String?

    let library = AssetLibrary()
    let server = LlamaServer()
    let generator = Generator()
    let slicer = Slicer()
    let printer = PrinterManager()
    let discovery = PrinterDiscovery()
    let downloader = ModelDownloader()
    let tasks = TaskCenter()
    /// Coding-agent CLIs on this Mac, their sign-in state and models.
    let clis = CLIDiscovery()
    /// NVIDIA SimReady catalogue and importer.
    let simready = SimReadyLibrary()
    var showSimReady = false
    var simReadyIntoScene = false
    let prep = PrepState()
    /// Preview of the selected asset (bridge injected); also used to pull GLBs out of pages.
    let preview = WebController(injectBridge: true)
    /// Runs code while it is being written.
    let live = LivePreview()
    /// Click-to-select in the preview, and the part picked.
    var pickMode = false
    var pickedPart: PickedPart?

    private var generateTaskID: UUID?
    private var printTaskID: UUID?

    var selectedAsset: Asset? { library.asset(selectedAssetID) }

    // MARK: provider

    /// Bumped when the provider or its settings change, so views re-read ProviderSettings.
    var providerRevision = 0
    var provider: Provider { _ = providerRevision; return ProviderSettings.selected }
    /// Why the selected provider can't generate right now (nil when it can).
    var engineProblem: String? {
        let p = provider
        if p.kind == .local {
            switch server.state {
            case .ready: return nil
            case .starting: return "Loading the 3D Coder model into memory…"
            case .failed(let m): return m
            case .stopped: return "The 3D Coder model is stopped. Start it from the Model menu."
            }
        }
        if p.kind == .cli, let i = clis.info[p.id] {
            if !i.installed { return "\(p.name) is not installed on this Mac." }
            if i.signedIn == false { return "\(p.name) is not signed in. In Terminal run: \(ProviderSettings.loginCommand(p))" }
        }
        return ProviderSettings.problem(p)
    }

    /// Picks a provider and, optionally, one of its models in one step.
    func select(_ p: Provider, model: String?) {
        if let model { UserDefaults.standard.set(model, forKey: "provider.\(p.id).model") }
        selectProvider(p.id)
        providerRevision += 1
    }
    var engineReady: Bool { engineProblem == nil }

    func selectProvider(_ id: String) {
        let old = ProviderSettings.selected
        UserDefaults.standard.set(id, forKey: ProviderSettings.selectedKey)
        providerRevision += 1
        let new = ProviderSettings.selected
        guard old.id != new.id else { return }
        // The local model holds 2 to 6 GB; free it while another provider writes the assets.
        if new.kind == .local { Task { await server.start() } } else if old.kind == .local { server.stop() }
    }
    var isComposing: Bool { selectedAssetID == nil }

    func boot() async {
        generator.server = server
        preview.onMessage = { [weak self] m in self?.handlePreviewMessage(m) }
        Settings.migrateToMLXIfAvailable()
        slicer.refreshPresets()
        printer.onJobEnded = { [weak self] name, ok in self?.printEnded(name: name, success: ok) }
        if printer.isConfigured { printer.connect() }
        CLIRunner.warmUp()
        Task { await clis.scan() }
        if ProviderSettings.selected.kind == .local && UserDefaults.standard.bool(forKey: SettingKey.autoStartServer) {
            await server.start()
        }
    }

    // MARK: navigation

    func newAsset() { selectedAssetID = nil; stage = .generate }

    func go(_ s: Stage) {
        if (s == .prepare || s == .slice) && selectedAsset == nil { return }
        stage = s
        page = .workspace
    }

    func canGo(_ s: Stage) -> Bool { s == .generate || s == .print || selectedAsset != nil }

    // MARK: generate

    func generate() {
        var p = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty, composerImage != nil { p = "Create the object shown in the reference picture." }
        guard !p.isEmpty, engineReady, !generator.isRunning, brief == nil else { return }
        selectedAssetID = nil
        stage = .generate
        if Brief.enabled {
            // Ask follow-up questions first; generation starts from finishBrief().
            let b = Brief(prompt: p, purpose: AssetPurpose.current)
            brief = b
            let ctx = b.purpose == .print ? printContext() : ""
            Task { await b.load(context: ctx) }
            return
        }
        launch(p, spec: nil)
    }

    /// Starts the generation from the brief. `skip` ignores the answers.
    func finishBrief(skip: Bool) {
        guard let b = brief else { return }
        brief = nil
        launch(b.prompt, spec: skip ? nil : b.spec)
    }

    func cancelBrief() { brief = nil }

    private func launch(_ p: String, spec: String?) {
        let parts = [AssetPurpose.current == .print ? printContext() : nil, spec?.isEmpty == false ? spec : nil].compactMap { $0 }
        startGeneration(prompt: p, base: nil, refinement: nil, image: composerImage,
                        context: parts.isEmpty ? nil : parts.joined(separator: "\n\n"))
        composerImage = nil
    }

    /// Asks the model for a new version of the selected asset. The asset stays selected: the preview shows the new
    /// code as it is written and the request joins the asset's conversation. With a picked part, only that part changes.
    func refine(_ text: String, label: String? = nil, part: PickedPart? = nil) {
        guard let a = selectedAsset, !text.trimmingCharacters(in: .whitespaces).isEmpty, engineReady, !generator.isRunning else { return }
        var request = text
        var shown = label
        if let part, let html = try? String(contentsOf: a.htmlURL, encoding: .utf8) {
            request = part.instruction(text, html: html)
            shown = shown ?? "\(part.label): \(text)"
        }
        startGeneration(prompt: a.prompt, base: a, refinement: request, label: shown)
        pickMode = false
        pickedPart = nil
        stage = .generate
    }

    func fixErrors() {
        guard selectedAsset != nil, !preview.errors.isEmpty else { return }
        let errs = preview.errors.prefix(8).joined(separator: "\n")
        refine("The page throws these JavaScript errors. Fix them without changing the asset design:\n\(errs)",
               label: "Fix \(preview.errors.count == 1 ? "the script error" : "\(preview.errors.count) script errors")")
    }

    /// Turns click-to-select on or off; the preview reloads with or without the picking hooks.
    func setPickMode(_ on: Bool) {
        guard let a = selectedAsset, pickMode != on else { return }
        pickMode = on
        pickedPart = nil
        preview.load(on ? a.pickURL : a.pageURL)
    }

    func handlePreviewMessage(_ m: [String: Any]) {
        guard m["type"] as? String == "part" else { return }
        pickedPart = PickedPart(m)
        if pickedPart != nil { refineFocusToken += 1 }
    }

    /// Printer facts for print-mode prompts: build volume, nozzle and the filaments loaded right now.
    func printContext() -> String {
        let p = PrinterProfile.current
        var s = "Target printer: Bambu Lab \(p.id), build volume \(p.volumeText), \(Settings.nozzle) mm nozzle. "
        s += "The finished object must fit inside the build volume with a 5 mm margin; if the requested size would not fit, "
        s += "scale it down to fit and say so. Keep walls at least \(String(format: "%.1f", max(2.0, (Double(Settings.nozzle) ?? 0.4) * 4))) mm thick."
        let trays = printer.knownTrays.filter { !$0.isExternal }
        if !trays.isEmpty {
            let list = trays.map { "\($0.name) #\($0.colorHex)" }.joined(separator: ", ")
            s += " Loaded filaments: \(list). Colour the parts using only these filament colours."
        }
        return s
    }

    private func startGeneration(prompt: String, base: Asset?, refinement: String?, label: String? = nil, image: ReferenceImage? = nil,
                                 attachment: ReferenceImage? = nil, context: String? = nil, title: String? = nil) {
        let title = title ?? refinement.map { _ in "Refining \(base?.shortTitle ?? "asset")" } ?? prompt
        live.begin()
        generateTaskID = tasks.start(.generate, title: title, detail: "Waiting for model", stage: .generate,
                                     cancel: { [weak self] in self?.generator.cancel() })
        generator.generate(prompt: prompt, base: base, refinement: refinement, label: label, image: image, attachment: attachment,
                           context: context, library: library) { [weak self] asset in
            guard let self else { return }
            // Each new asset is reviewed once (against its picture, if it has one) and fixed if it falls short.
            let check = refinement == nil && VisualCheck.enabled
            // Watching the generation, or the version it started from: move on to the new version.
            if self.selectedAssetID == nil || (base != nil && self.selectedAssetID == base?.id) { self.selectedAssetID = asset.id }
            if let id = self.generateTaskID {
                self.tasks.finish(id, success: true, title: "\(asset.shortTitle) is ready",
                                  detail: "Generated in \(formatDuration(asset.genSeconds ?? 0)). Open it to refine it or prepare it for print.")
                if let i = self.tasks.tasks.firstIndex(where: { $0.id == id }) { self.tasks.tasks[i].assetID = asset.id }
            }
            if check { Task { await self.reviewAsset(asset) } }
        }
    }

    /// Reviews a new asset once: renders it from four sides (beside its reference picture, if it has one), has a vision
    /// model check it against the request and the follow-up answers, and starts one quick fix if it falls short.
    func reviewAsset(_ asset: Asset) async {
        guard VisualCheck.checker != nil, asset.imported != true else { return } // no vision model available: skip quietly
        let reference = asset.has(asset.referenceURL) ? ReferenceImage(url: asset.referenceURL) : nil
        let name = asset.shortTitle
        let task = tasks.start(.generate, title: reference != nil ? "Comparing \(name) with the picture" : "Reviewing \(name)",
                               detail: "Rendering four views", assetID: asset.id, stage: .generate)
        do {
            if !asset.has(asset.glbURL) {
                tasks.update(task, detail: "Exporting GLB")
                let web = checkWeb ?? WebController(injectBridge: true)
                checkWeb = web
                library.write(try await GLBExtractor.extract(using: web, asset: asset), to: asset.glbURL)
                web.load(URL(string: "about:blank")!)
                tasks.update(task, detail: "Rendering four views")
            }
            let ref = reference != nil ? "'forge://lib/\(asset.id)/reference.jpg'" : "null"
            let (jpeg, _) = try await runGLBTool(asset, ops: "{ views: { reference: \(ref), cell: 384 } }")
            guard let img = NSImage(data: jpeg), let sheet = ReferenceImage(image: img, maxSide: 1536) else {
                throw ForgeError("The renders could not be read.")
            }
            library.write(sheet.jpeg, to: asset.comparisonURL)
            tasks.update(task, detail: "Asking \(VisualCheck.checker?.0.name ?? "a vision model") to check it")
            let verdict = try await VisualCheck.critique(sheet: sheet, prompt: asset.fullRequest,
                                                         purpose: AssetPurpose(rawValue: asset.purpose ?? "") ?? .game,
                                                         hasReference: reference != nil)
            guard verdict.needsRefinement else {
                tasks.finish(task, success: true, title: reference != nil ? "\(name) matches the picture" : "\(name) passed review",
                             detail: "\(verdict.checker) scored it \(verdict.score)/10.", thumb: asset.thumbURL)
                return
            }
            guard engineReady, !generator.isRunning, brief == nil else {
                tasks.finish(task, success: true, title: "\(name) scored \(verdict.score)/10",
                             detail: "Not fixed because another generation is running. Suggested: " + verdict.fixes.prefix(3).joined(separator: "; "))
                return
            }
            tasks.finish(task, success: true, title: "Fixing \(name) after review",
                         detail: "\(verdict.checker) scored it \(verdict.score)/10 and found \(verdict.fixes.count) issue\(verdict.fixes.count == 1 ? "" : "s").")
            let follow = selectedAssetID == asset.id
            startGeneration(prompt: asset.prompt, base: asset, refinement: verdict.refinement,
                            label: (reference != nil ? "Match the picture: " : "Review fixes: ") + verdict.fixes.prefix(3).joined(separator: "; "),
                            image: reference, attachment: sheet,
                            title: reference != nil ? "Matching \(name) to the picture" : "Fixing \(name) after review")
            if follow { stage = .generate }
        } catch {
            tasks.finish(task, success: false, title: "Could not review \(name)", detail: error.localizedDescription)
        }
    }

    /// Called by the generator when it fails or is cancelled.
    func generationEnded() {
        guard let id = generateTaskID else { return }
        switch generator.phase {
        case .failed(let m):
            tasks.finish(id, success: false, detail: m,
                         retry: generator.canContinue ? { [weak self] in self?.continueGeneration() } : nil,
                         retryTitle: generator.canContinue ? "Continue" : nil)
        case .cancelled: tasks.remove(id)
        default: break
        }
    }

    /// The engine that wrote the partial answer is available (the local model must be loaded; others are always on).
    var canContinueNow: Bool {
        guard let p = generator.continueProvider else { return false }
        return p.kind == .local ? (provider.kind == .local && engineReady) : true
    }

    /// Picks up a stopped or cut-off generation where it ended instead of starting again.
    func continueGeneration() {
        guard generator.canContinue, canContinueNow, !generator.isRunning else { return }
        let partialTokens = generator.codeTokens
        generateTaskID = tasks.start(.generate, title: "Continuing \(generator.shortTitle)",
                                     detail: "Picking up after \(partialTokens.formatted()) tokens", stage: .generate,
                                     cancel: { [weak self] in self?.generator.cancel() })
        selectedAssetID = generator.baseID
        stage = .generate
        generator.continueLast()
    }

    func stopGenerating() { generator.cancel(); generationEnded() }

    // MARK: detail

    /// Subdivides the selected asset's meshes (crease-aware Loop subdivision) into a new, smoother version.
    func enhanceDetail(levels: Int, creaseAngle: Double) async {
        guard let a = selectedAsset, !enhancing else { return }
        enhancing = true
        defer { enhancing = false }
        let factor = Int(pow(4.0, Double(levels)))
        let task = tasks.start(.slice, title: "Adding detail to \(a.shortTitle)", detail: "Exporting GLB", assetID: a.id, stage: .generate)
        do {
            try await ensureGLB(a)
            tasks.update(task, detail: "Subdividing ×\(factor)")
            let (glb, result) = try await runGLBTool(a, ops: "{ subdivide: { levels: \(levels), creaseAngle: \(creaseAngle) } }")
            let stats = (result["stats"] as? [String: Any])?["subdivide"] as? [String: Any] ?? [:]
            let before = (stats["before"] as? NSNumber)?.intValue ?? 0, after = (stats["after"] as? NSNumber)?.intValue ?? 0
            let used = (stats["levels"] as? NSNumber)?.intValue ?? levels
            let label = "Smooth detail ×\(Int(pow(4.0, Double(used)))) (\(after.formatted()) triangles)"
            let new = try library.createDerived(from: a, glb: glb, label: label)
            selectedAssetID = new.id
            tasks.finish(task, success: true, title: "\(a.shortTitle) refined",
                         detail: "\(before.formatted()) → \(after.formatted()) triangles, saved as a new version.")
            if used < levels { alert = "Subdivided \(used) level\(used == 1 ? "" : "s") instead of \(levels) to stay under 1.5 million triangles." }
        } catch {
            tasks.finish(task, success: false, title: "Could not add detail", detail: error.localizedDescription)
        }
    }

    /// Runs passes on an asset's GLB in the headless tool page (enhance.html, three.js r187) and returns the new file.
    /// `ops` is a JS object literal: { subdivide: {...}, lightmapUVs: {...}, format: 'glb' | 'obj' }.
    func runGLBTool(_ a: Asset, ops: String) async throws -> (Data, [String: Any]) {
        try await ensureGLB(a)
        let web = enhanceWeb ?? WebController(injectBridge: false)
        enhanceWeb = web
        if web.loadedURL == nil {
            var ready = false
            web.onMessage = { m in if m["type"] as? String == "enhanceReady" { ready = true } }
            web.load(URL(string: "forge://app/enhance.html")!)
            for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(100)) }
            guard ready else { enhanceWeb = nil; throw ForgeError("The GLB tools page did not start.") }
        }
        let id = UUID().uuidString
        let result: [String: Any] = try await withCheckedThrowingContinuation { cont in
            var done = false
            web.onMessage = { m in
                guard !done, m["type"] as? String == "glbTool", m["requestId"] as? String == id else { return }
                done = true
                if let err = m["error"] as? String {
                    // Show the message itself, not the JS stack.
                    let first = err.components(separatedBy: "\n").first ?? err
                    cont.resume(throwing: ForgeError(first.replacingOccurrences(of: "Error: ", with: "").prefix(300).description))
                }
                else { cont.resume(returning: m) }
            }
            Task {
                let url = "forge://lib/\(a.id)/asset.glb?t=\(Date().timeIntervalSince1970)"
                await web.eval("window.glbTool('\(url)', \(ops), '\(id)'); true")
                try? await Task.sleep(for: .seconds(300))
                if !done { done = true; cont.resume(throwing: ForgeError("GLB processing took more than 5 minutes and was stopped.")) }
            }
        }
        guard let b64 = result["data"] as? String, let data = Data(base64Encoded: b64) else { throw ForgeError("No file came back.") }
        return (data, result)
    }

    /// GLB bytes for export: the stored file, or a copy with lightmap UVs (TEXCOORD_1) when that option is on.
    func exportableGLB(_ a: Asset) async throws -> Data {
        try await ensureGLB(a)
        guard UserDefaults.standard.bool(forKey: "exportLightmapUVs") else { return try Data(contentsOf: a.glbURL) }
        let res = UserDefaults.standard.integer(forKey: "lightmapResolution")
        return try await runGLBTool(a, ops: "{ lightmapUVs: { resolution: \(res > 0 ? res : 1024) } }").0
    }

    // MARK: prepare / slice

    func ensureGLB(_ a: Asset) async throws {
        if a.has(a.glbURL) { return }
        let data = try await GLBExtractor.extract(using: preview, asset: a)
        library.write(data, to: a.glbURL)
    }

    func loadPrep(_ a: Asset) async {
        if prep.assetID == a.id && prep.ready { return }
        prep.reset(for: a, slicer: slicer)
        prep.busy = "Exporting GLB from the generated scene…"
        do { try await ensureGLB(a) } catch {
            prep.busy = nil; alert = error.localizedDescription; return
        }
        prep.busy = nil
        prep.prepWeb.load(URL(string: "forge://app/prep.html")!)
        for _ in 0..<150 where !prep.ready { try? await Task.sleep(for: .milliseconds(100)) }
        let printer = PrinterProfile.current
        let native = a.purpose == "print"
        await prep.prepWeb.eval("window.prep.setPlate(\(printer.x), \(printer.y), \(printer.z))\(native ? "; window.prep.setFit('native')" : "")")
        pushPalette()
        prep.pushRepair()
        prep.pushColors()
        await prep.prepWeb.eval("\(native ? "" : "window.prep.setHeight(\(prep.targetHeight)); ")window.prep.load('forge://lib/\(a.id)/asset.glb?t=\(Date().timeIntervalSince1970)')")
        if a.has(a.gcodeURL) { loadGcodePreview(a) }
    }

    func pushPalette() {
        let trays = printer.knownTrays.filter { !$0.isExternal }
        let slots = trays.map { ["key": "tray:\($0.id)", "hex": "#" + $0.colorHex, "label": "\($0.label) · \($0.name)"] }
        if let data = try? JSONSerialization.data(withJSONObject: slots), let json = String(data: data, encoding: .utf8) {
            prep.push("window.prep.setPalette(\(json))")
        }
    }

    func loadGcodePreview(_ a: Asset) {
        let r = Slicer.loadResult(a)
        let colors = (r?.filaments ?? []).map { $0.hex.replacingOccurrences(of: "#", with: "") }.joined(separator: ",")
        let rot = r?.arrangeRotation ?? 0
        prep.gcodeWeb.load(URL(string: "forge://app/gcode.html?src=forge://lib/\(a.id)/plate_1.gcode&colors=\(colors)&rot=\(rot)&t=\(Date().timeIntervalSince1970)")!)
    }

    private func writeFilaments(_ fils: [ExportedFilament], to dir: URL) throws -> [SliceFilament] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let trays = printer.knownTrays
        return try fils.enumerated().map { i, f in
            let url = dir.appendingPathComponent("part_\(i + 1).stl")
            try f.data.write(to: url)
            let tray = f.slot.hasPrefix("tray:") ? trays.first { "tray:\($0.id)" == f.slot } : nil
            return SliceFilament(stl: url, hex: f.hex, slot: f.slot, type: tray?.type, tray: tray)
        }
    }

    func slice() async {
        guard let a = selectedAsset else { return }
        await loadPrep(a)
        guard prep.ready, prep.busy == nil else { return }
        stage = .slice
        let task = tasks.start(.slice, title: "Slicing \(a.shortTitle)", detail: "Repairing mesh", assetID: a.id, stage: .slice)
        prep.busy = prep.repair ? "Repairing mesh…" : "Exporting STL…"
        defer { prep.busy = nil }
        do {
            var (fils, report) = try await prep.export()
            prep.lastReport = report
            guard !fils.isEmpty else { throw ForgeError("Nothing to print: no parts selected.") }
            // Check every STL for holes, flipped faces and stray faces, and repair them before Bambu Studio sees them.
            prep.busy = "Checking the STL files…"
            tasks.update(task, detail: "Checking the STL files for holes and flipped faces")
            let raw = fils.map(\.data)
            let checked = await Task.detached(priority: .userInitiated) { raw.map { MeshRepair.repair($0) } }.value
            var health = MeshHealth()
            for i in fils.indices { fils[i].data = checked[i].data; health.add(checked[i].health) }
            let parts = try writeFilaments(fils, to: a.dir.appendingPathComponent("print", isDirectory: true))
            library.write(fils.count == 1 ? fils[0].data : combinedSTL(fils.map(\.data)), to: a.stlURL)
            prep.busy = "Checking overhangs…"
            tasks.update(task, detail: "Checking overhangs and contact with the plate")
            let stls = parts.map(\.stl)
            let mesh = await Task.detached(priority: .userInitiated) { MeshCheck.analyse(stls) }.value
            let options = prep.options.resolved(needsSupports: mesh?.needsSupports ?? true)
            prep.busy = fils.count > 1 ? "Slicing \(fils.count) colours…" : "Slicing…"
            tasks.update(task, detail: "Bambu Studio, \(fils.count) colour\(fils.count == 1 ? "" : "s")\(options.supports ? ", with supports" : "")")
            let r = try await slicer.slice(filaments: parts, options: options, outDir: a.dir, outName: a.threeMFURL.lastPathComponent)
            Slicer.save(r, for: a)
            prep.result = r
            prep.busy = "Checking the slice…"
            await runPrintCheck(a, mesh: mesh, health: health, passthrough: report.passthroughParts, options: options, result: r)
            library.touch()
            loadGcodePreview(a)
            tasks.finish(task, success: true, title: "\(a.shortTitle) sliced",
                         detail: "\(formatDuration(r.seconds)), \(String(format: "%.0f g", r.weightGrams))", thumb: a.thumbURL)
            if prep.multicolor && prep.variants.isEmpty { await compareVariants() }
        } catch {
            tasks.finish(task, success: false, title: "Slicing \(a.shortTitle) failed", detail: error.localizedDescription)
        }
    }

    func compareVariants() async {
        guard let a = selectedAsset, !prep.comparing else { return }
        prep.comparing = true; prep.variants = []
        let task = tasks.start(.compare, title: "Comparing colour counts", detail: a.shortTitle, assetID: a.id, stage: .slice)
        defer { prep.comparing = false }
        for k in 1...max(1, prep.maxColors) {
            tasks.update(task, detail: "\(k) colour\(k == 1 ? "" : "s")", progress: Double(k - 1) / Double(max(1, prep.maxColors)))
            do {
                let (fils, _) = try await prep.export(maxColors: k)
                if let last = prep.variants.last, last.hexes == fils.map(\.hex) { continue }
                let dir = a.dir.appendingPathComponent("variants/\(k)", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                let parts = try writeFilaments(fils, to: dir)
                let stls = parts.map(\.stl)
                let mesh = await Task.detached(priority: .userInitiated) { MeshCheck.analyse(stls) }.value
                let options = prep.options.resolved(needsSupports: mesh?.needsSupports ?? true)
                let r = try await slicer.slice(filaments: parts, options: options, outDir: dir, outName: "variant.gcode.3mf")
                prep.variants.append(ColorVariant(colors: fils.count, hexes: fils.map(\.hex), seconds: r.seconds, grams: r.weightGrams, changes: r.changes ?? 0))
            } catch {
                tasks.finish(task, success: false, detail: error.localizedDescription); return
            }
        }
        try? FileManager.default.removeItem(at: a.dir.appendingPathComponent("variants"))
        tasks.finish(task, success: true, title: "Compared colour counts", detail: "\(prep.variants.count) options for \(a.shortTitle)")
    }

    // MARK: print check

    /// Predicts print problems from the model and the G-code, and saves the report beside the slice.
    func runPrintCheck(_ a: Asset, mesh: MeshStats?, health: MeshHealth, passthrough: Int, options: SliceOptions, result: SliceResult) async {
        let url = a.gcodeURL
        let gcode = await Task.detached(priority: .userInitiated) { GcodeCheck.analyse(url) }.value
        let preset = result.filaments?.count ?? 0 > 1 ? options.filament : (gcode?.settings["filament_settings_id"]
            .map { $0.split(separator: ";").first.map(String.init) ?? $0 }?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? options.filament)
        let material = PrintRules.material(fromPreset: result.filamentType.isEmpty ? preset : result.filamentType)
        let ctx = PrintRules.Context(mesh: mesh, gcode: gcode, material: material, filamentPreset: preset,
                                     supportMode: options.supportMode, supportsOn: options.supports, brim: options.brim,
                                     noSupportsWanted: a.fullRequest.contains("Design to print without supports"))
        var findings = PrintRules.findings(ctx)
        if let f = PrintRules.stlFinding(health, passthrough: passthrough, repairOn: prep.repair) { findings.insert(f, at: 0) }
        let report = PrintReport(findings: findings.sorted { $0.severity > $1.severity }, mesh: mesh, gcode: gcode,
                                 material: material, checkedAt: Date(), health: health)
        PrintCheckStore.save(report, for: a)
        if prep.assetID == a.id { prep.check = report }
    }

    /// Applies a print-check fix: slicer settings are changed and the asset re-sliced; model fixes go to the model.
    func applyPrintFix(_ fix: PrintFix) async {
        if let text = fix.refine {
            refine(text)
            return
        }
        guard let settings = fix.settings else { return }
        for (k, v) in settings {
            switch k {
            case "supports":
                prep.options.supportMode = v
                UserDefaults.standard.set(v, forKey: SliceOptions.supportModeKey)
            case "brim": prep.options.brim = v == "1"
            case "repair": prep.repair = v == "1"; prep.pushRepair(); try? await Task.sleep(for: .milliseconds(300))
            case "wallLoops": if let n = Int(v) { prep.options.wallLoops = n }
            case "infill": if let n = Int(v) { prep.options.infill = n }
            default:
                if k.hasPrefix("p.") { prep.options.processOverrides[String(k.dropFirst(2))] = v }
                else if k.hasPrefix("f.") { prep.options.filamentOverrides[String(k.dropFirst(2))] = v }
            }
        }
        await slice()
    }

    /// Has a language model read the measurements and suggest further fixes, limited to settings Sirpi can apply.
    func reviewPrint() async {
        guard let a = selectedAsset, let report = prep.check, !prep.reviewingPrint else { return }
        prep.reviewingPrint = true
        defer { prep.reviewingPrint = false }
        let task = tasks.start(.slice, title: "Reviewing the print of \(a.shortTitle)", detail: "Asking an AI model", assetID: a.id, stage: .slice)
        do {
            let r = try await PrintReview.review(report: report, options: prep.options, request: a.fullRequest)
            var updated = report
            updated.findings.removeAll { $0.source != nil }
            updated.findings += r.findings
            updated.aiSummary = r.summary
            PrintCheckStore.save(updated, for: a)
            if prep.assetID == a.id { prep.check = updated }
            tasks.finish(task, success: true, title: "Print review ready", detail: r.findings.isEmpty ? "No further changes suggested" : "\(r.findings.count) suggestion\(r.findings.count == 1 ? "" : "s")")
        } catch {
            tasks.finish(task, success: false, title: "Print review failed", detail: error.localizedDescription)
        }
    }

    func useVariant(_ v: ColorVariant) async {
        prep.multicolor = v.colors > 1
        if v.colors > 1 { prep.maxColors = v.colors }
        prep.pushColors()
        try? await Task.sleep(for: .milliseconds(300))
        let keep = prep.variants
        await slice()
        prep.variants = keep
    }

    private func combinedSTL(_ stls: [Data]) -> Data {
        var count: UInt32 = 0
        var body = Data()
        for d in stls where d.count > 84 {
            count += d.subdata(in: 80..<84).withUnsafeBytes { $0.load(as: UInt32.self) }
            body.append(d.subdata(in: 84..<d.count))
        }
        var out = Data(count: 80)
        withUnsafeBytes(of: count.littleEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    // MARK: print

    func startPrint(_ a: Asset, options: PrinterManager.PrintOptions) async {
        let task = tasks.start(.upload, title: "Sending \(a.shortTitle) to P2S", detail: "Uploading over FTPS", assetID: a.id, stage: .print)
        do {
            try await printer.startPrint(threeMF: a.threeMFURL, name: a.fileStem, options: options)
            tasks.remove(task)
            printTaskID = tasks.start(.print, title: "Printing \(a.shortTitle)", detail: "Starting", assetID: a.id, stage: .print)
            stage = .print
        } catch {
            tasks.finish(task, success: false, title: "Upload did not finish", detail: error.localizedDescription,
                         retry: { [weak self] in Task { await self?.startPrint(a, options: options) } })
        }
    }

    private func printEnded(name: String, success: Bool) {
        let asset = library.assets.first { $0.fileStem == name }
        if let id = printTaskID ?? tasks.running.first(where: { $0.kind == .print })?.id {
            tasks.finish(id, success: success, title: success ? "\(asset?.shortTitle ?? name) printed" : "Print failed",
                         detail: success ? "Take it off the plate." : "Check the printer screen.", thumb: asset?.thumbURL)
        } else {
            tasks.announce(title: success ? "Print finished" : "Print failed", detail: name, isError: !success)
        }
        printTaskID = nil
    }

    // MARK: files

    func exportGLB() async {
        guard let a = selectedAsset else { return }
        do {
            let data = try await exportableGLB(a)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "glb") ?? .data]
            panel.nameFieldStringValue = a.fileStem + ".glb"
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url) }
        } catch { alert = error.localizedDescription }
    }

    /// OBJ with material colours baked into vertex colours (three.js r187 OBJExporter), for tools without GLB support.
    // MARK: turntable video

    private func turntablePage() async throws -> WebController {
        if let w = turntableWeb { return w }
        let web = WebController(injectBridge: false)
        var ready = false
        web.onMessage = { m in if m["type"] as? String == "turntableReady" { ready = true } }
        web.load(URL(string: "forge://app/turntable.html")!)
        for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(100)) }
        guard ready else { throw ForgeError("The turntable renderer did not start.") }
        turntableWeb = web
        return web
    }

    private static func decodeFrame(_ value: Any?) -> CGImage? {
        guard let s = value as? String, let comma = s.firstIndex(of: ","),
              let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// First frame at preview size for the export sheet.
    func turntablePreview(_ a: Asset, options o: TurntableOptions) async throws -> NSImage? {
        guard !turntableBusy else { return nil }
        turntableBusy = true
        defer { turntableBusy = false }
        try await ensureGLB(a)
        let web = try await turntablePage()
        _ = try await web.evalThrowing("window.turntableSetup('forge://lib/\(a.id)/asset.glb?t=\(a.id)', \(o.js(maxSide: 640)))")
        guard let cg = Self.decodeFrame(try await web.evalThrowing("window.turntableFrame(0)")) else {
            throw ForgeError("The renderer returned no picture.")
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Renders a seamless 360° turntable of `a` and encodes it to MP4 (or HEVC-with-alpha MOV).
    func exportTurntable(_ a: Asset, options o: TurntableOptions) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [o.fileType]
        panel.nameFieldStringValue = "\(a.fileStem)-turntable.\(o.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        for _ in 0..<50 where turntableBusy { try? await Task.sleep(for: .milliseconds(100)) }
        turntableBusy = true
        defer { turntableBusy = false }
        var cancelled = false
        let total = o.frames
        let task = tasks.start(.download, title: "Turntable video of \(a.shortTitle)", detail: "Preparing",
                               assetID: a.id, stage: .generate, cancel: { cancelled = true })
        var encoder: TurntableEncoder?
        do {
            try await ensureGLB(a)
            let web = try await turntablePage()
            _ = try await web.evalThrowing("window.turntableSetup('forge://lib/\(a.id)/asset.glb?t=\(Date().timeIntervalSince1970)', \(o.js))")
            let (w, h) = o.resolution.size
            let enc = try TurntableEncoder(url: url, width: w, height: h, fps: o.fps, alpha: o.transparent)
            encoder = enc
            let perTurn = max(2, total / max(1, o.loops))
            let started = Date()
            for i in 0..<total {
                if cancelled { throw CancellationError() }
                guard let frame = Self.decodeFrame(try await web.evalThrowing("window.turntableFrame(\(i % perTurn))")) else {
                    throw ForgeError("Frame \(i + 1) could not be rendered.")
                }
                try await enc.append(frame, index: i)
                if i % 6 == 0 || i == total - 1 {
                    let done = Double(i + 1) / Double(total)
                    let left = Date().timeIntervalSince(started) / done * (1 - done)
                    tasks.update(task, detail: "Frame \(i + 1) of \(total) · about \(formatDuration(left)) left", progress: done)
                }
            }
            tasks.update(task, detail: "Finishing the file")
            try await enc.finish()
            _ = await web.eval("window.turntableDispose()")
            let mb = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1_000_000
            tasks.finish(task, success: true, title: "Turntable video saved",
                         detail: "\(url.lastPathComponent) · \(o.resolution.title), \(Int(o.seconds)) s, \(mb) MB", thumb: a.thumbURL)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            encoder?.cancel()
            try? FileManager.default.removeItem(at: url)
            _ = await turntableWeb?.eval("window.turntableDispose()")
            if error is CancellationError { tasks.remove(task); return }
            tasks.finish(task, success: false, title: "Could not make the turntable video", detail: error.localizedDescription)
        }
    }

    func exportOBJ() async {
        guard let a = selectedAsset else { return }
        do {
            let (data, _) = try await runGLBTool(a, ops: "{ format: 'obj' }")
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "obj") ?? .data]
            panel.nameFieldStringValue = a.fileStem + ".obj"
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url) }
        } catch { alert = error.localizedDescription }
    }

    func exportSTLs() {
        guard let a = selectedAsset else { return }
        let dir = a.dir.appendingPathComponent("print")
        let parts = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "stl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !parts.isEmpty || a.has(a.stlURL) else { alert = "Slice the asset first to produce STL files."; return }
        if parts.count <= 1 { saveCopy(of: a.stlURL, name: a.fileStem + ".stl"); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save \(parts.count) STLs here"
        if panel.runModal() == .OK, let dest = panel.url {
            for (i, p) in parts.enumerated() {
                let target = dest.appendingPathComponent("\(a.fileStem)_colour\(i + 1).stl")
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: p, to: target)
            }
        }
    }

    func saveSliced() {
        guard let a = selectedAsset, a.has(a.threeMFURL) else { alert = "Nothing sliced yet."; return }
        saveCopy(of: a.threeMFURL, name: a.threeMFURL.lastPathComponent)
    }

    private func saveCopy(of url: URL, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    /// Copies the GLB into `<godot project>/assets/assetforge/`, asking for the project once.
    func copyToGodot() async {
        guard let a = selectedAsset else { return }
        var project = UserDefaults.standard.url(forKey: "godotProject")
        if project == nil || !FileManager.default.fileExists(atPath: project!.appendingPathComponent("project.godot").path) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.message = "Choose your Godot project folder (the one with project.godot)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("project.godot").path) else {
                alert = "That folder has no project.godot file."; return
            }
            UserDefaults.standard.set(url, forKey: "godotProject")
            project = url
        }
        do {
            let data = try await exportableGLB(a)
            let dir = project!.appendingPathComponent("assets/assetforge", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(a.fileStem + ".glb")
            try data.write(to: dest)
            let uv2 = UserDefaults.standard.bool(forKey: "exportLightmapUVs") ? " with lightmap UV2" : ""
            tasks.announce(title: "Copied to Godot\(uv2)", detail: "res://assets/assetforge/\(dest.lastPathComponent)", assetID: a.id)
        } catch { alert = error.localizedDescription }
    }

    func importGLB() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "glb") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let src = panel.url else { return }
        do {
            let a = try library.importGLB(from: src)
            selectedAssetID = a.id
            stage = .prepare
        } catch { alert = error.localizedDescription }
    }

    func openSettings(_ pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane") }
        page = .settings
    }

    func openHelp(_ topic: HelpTopic = .start) {
        helpTopic = topic
        page = .help
    }

    /// The camera feed lives on the Print stage.
    func watchCamera() {
        showCamera = true
        stage = .print
        page = .workspace
    }

    func openInStudio(_ url: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: Settings.bambuStudioPath),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Group {
                switch app.page {
                case .workspace: Sidebar()
                case .settings: SettingsSidebar()
                case .help: HelpSidebar()
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 264, max: 340)
        } detail: {
            switch app.page {
            case .workspace:
                DetailWithInspector()
                    .navigationTitle(app.selectedAsset?.shortTitle ?? (app.generator.isRunning ? app.generator.shortTitle : "New asset"))
            case .settings:
                SettingsView().navigationTitle("Settings")
            case .help:
                HelpView().navigationTitle("Help")
            }
        }
        .toolbar {
            if app.page != .workspace {
                ToolbarItem(placement: .navigation) {
                    Button { app.page = .workspace } label: { Label("Back", systemImage: "chevron.left") }
                        .keyboardShortcut(.cancelAction)
                        .help("Back to \(app.stage.title) (Esc)")
                }
            }
            // Computed here so the toolbar closure itself depends on the width and is rebuilt when it changes.
            ToolbarItem(placement: .principal) { StagePicker(compact: app.windowWidth < 1140).id(app.windowWidth < 1140) }
            ToolbarItem(placement: .primaryAction) { TasksButton() }
            if app.page == .workspace {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { app.showInspector.toggle() }
                    } label: {
                        Label(app.showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                    }
                    .help(app.showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
                }
            }
        }
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 72) } // clears the viewport toolbars
        .background(WindowWidthReader { w in
            // Quantised so live resizing doesn't re-render the toolbar on every point.
            let q = (w / 20).rounded() * 20
            if q != app.windowWidth { app.windowWidth = q }
        })
        .alert("Something went wrong", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK") {}
        } message: { Text(app.alert ?? "") }
        .confirmationDialog("Stop the current print?", isPresented: $app.confirmStopPrint) {
            Button("Stop Print", role: .destructive) { app.printer.stop() }
        } message: { Text("This cancels the job. It cannot be resumed.") }
        .sheet(isPresented: $app.showPrintSheet) { PrintSheet() }
        .sheet(isPresented: $app.showSimReady) { SimReadyBrowser(intoScene: app.simReadyIntoScene) }
        .sheet(item: $app.turntableAsset) { TurntableSheet(asset: $0) }
        .onChange(of: app.printer.knownTrays) { _, _ in app.pushPalette() }
        .onChange(of: app.generator.phase) { _, p in
            if case .failed = p { app.generationEnded() }
        }
    }
}

/// Switches the main window between the workspace (library and stages), Settings and Help.
struct PageSwitcher: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 4) {
            item(.workspace, "Library", "square.stack.3d.up")
            item(.settings, "Settings", "gearshape")
            item(.help, "Help", "questionmark.circle")
        }
        .padding(.horizontal, 8).padding(.bottom, 8).padding(.top, 2)
    }

    private func item(_ page: AppPage, _ title: String, _ symbol: String) -> some View {
        let active = app.page == page
        return Button { app.page = page } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(active ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(active ? Theme.accent : .secondary)
                .background(active ? Theme.accent.opacity(0.14) : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// Reports the hosting NSWindow's real width. SwiftUI geometry inside a NavigationSplitView did not track window
/// resizes reliably, which left the toolbar picker at full width in narrow windows.
struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = Probe(); v.onChange = onChange; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.onChange = onChange }

    final class Probe: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var token: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] n in
                guard let w = (n.object as? NSWindow)?.frame.width else { return }
                MainActor.assumeIsolated { self?.onChange?(w) }
            }
            let w = window.frame.width
            DispatchQueue.main.async { [weak self] in self?.onChange?(w) }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

struct StagePicker: View {
    @Environment(AppModel.self) private var app
    let compact: Bool
    var body: some View {
        // The picker sits over the middle column. With titles it is ~320 pt wide, which no longer fits once
        // the window narrows with both sidebars open, and an unfittable toolbar item loops AppKit's
        // constraint pass (crash). Below 1060 pt it drops to icons (~170 pt); the titles stay in tooltips.
        Picker("Stage", selection: Binding(get: { app.stage }, set: { app.go($0) })) {
            ForEach(Stage.allCases) { s in
                Group {
                    if compact { Image(systemName: s.symbol).help(s.title) } else { Label(s.title, systemImage: s.symbol) }
                }
                .tag(s)
                .selectionDisabled(!app.canGo(s))
                .accessibilityLabel(s.title)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }
}

struct StageViewport: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        // GeometryReader reports a zero minimum size, so stage content can never push a minimum width up
        // into the split view. A content-driven minimum wider than the window (e.g. on an 820 pt display)
        // makes AppKit loop its update-constraints pass and abort.
        GeometryReader { geo in
            ZStack {
                Theme.viewport.ignoresSafeArea().backgroundExtensionEffect()
                switch app.stage {
                case .generate: GenerateViewport()
                case .prepare: PrepareViewport()
                case .slice: SliceViewport()
                case .print: PrintViewport()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The stage viewport plus the right-hand inspector, laid out by hand rather than with `.inspector`.
/// The native inspector is an NSSplitView column whose minimum width AppKit renegotiates every layout
/// pass; in a window narrower than ~830 pt that never settles and AppKit aborts ("more Update
/// Constraints in Window passes than there are views"). Here both widths are computed from the
/// available space, so nothing can overflow, and the inspector's width is dragged from its edge.
struct DetailWithInspector: View {
    @Environment(AppModel.self) private var app
    @AppStorage("inspectorWidth") private var storedWidth: Double = 300
    @State private var dragStart: Double?
    @State private var hoverEdge = false
    /// True while the inspector is hidden only because the window got too narrow; it returns when there is room.
    @State private var autoHidden = false

    static let range: ClosedRange<Double> = 240...480
    static let minViewport: Double = 460

    var body: some View {
        GeometryReader { geo in
            let total = Double(geo.size.width)
            // Too narrow for side by side: the inspector floats over the viewport instead of crushing it.
            // A zero width comes from the first layout pass, before the window has a size; don't treat it as narrow.
            let floating = total > 1 && total < Self.minViewport + Self.range.lowerBound
            let w = app.showInspector ? (floating ? min(storedWidth, total * 0.88) : Self.fit(storedWidth, total: total)) : 0
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    StageViewport()
                        .frame(width: max(0, total - (floating ? 0 : w)))
                        .clipped()
                    if !floating { Color.clear.frame(width: w) }
                }
                if app.showInspector {
                    StageInspector()
                        .frame(width: w)
                        .background(Theme.inspector.ignoresSafeArea())
                        .overlay(alignment: .leading) { edge(total: total) }
                        .shadow(color: .black.opacity(floating ? 0.45 : 0), radius: 18, x: -6)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Entering the narrow layout hides the inspector so it doesn't cover the stage; it can still be opened
            // on demand as an overlay.
            .onChange(of: floating, initial: true) { _, now in
                if now && app.showInspector { app.showInspector = false; autoHidden = true }
                else if !now && autoHidden { autoHidden = false; withAnimation(.snappy(duration: 0.25)) { app.showInspector = true } }
            }
            .onChange(of: app.showInspector) { _, shown in if shown { autoHidden = false } }
        }
    }

    /// Clamp to the user's range, then give the viewport at least `minViewport` (or 55 % when tight).
    static func fit(_ want: Double, total: Double) -> Double {
        let w = min(range.upperBound, max(range.lowerBound, want))
        let room = max(total * 0.45, total - minViewport)
        return max(0, min(w, room))
    }

    private func edge(total: Double) -> some View {
        Rectangle()
            .fill(hoverEdge || dragStart != nil ? Theme.accent.opacity(0.45) : Theme.hairline)
            .frame(width: hoverEdge || dragStart != nil ? 2 : 1)
            // Grab area lies inside the inspector: the viewport's web view would take any hits left of the edge.
            .frame(width: 8, alignment: .leading)
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onHover { inside in
                hoverEdge = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStart == nil { dragStart = Self.fit(storedWidth, total: total) }
                        let next = (dragStart ?? storedWidth) - v.translation.width
                        storedWidth = min(Self.range.upperBound, max(Self.range.lowerBound, next))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { withAnimation(.snappy) { storedWidth = 300 } }
            .help("Drag to resize the inspector · double-click to reset")
    }
}

struct StageInspector: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        GeometryReader { geo in
            Group {
                switch app.stage {
                case .generate: GenerateInspector()
                case .prepare: PrepareInspector()
                case .slice: SliceInspector()
                case .print: PrintInspector()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""

    var body: some View {
        let items = app.library.assets.filter {
            search.isEmpty || $0.prompt.localizedCaseInsensitiveContains(search) || ($0.refinement ?? "").localizedCaseInsensitiveContains(search)
        }
        let today = items.filter { Calendar.current.isDateInToday($0.created) }
        let earlier = items.filter { !Calendar.current.isDateInToday($0.created) }
        List(selection: Binding(get: { app.selectedAssetID }, set: { id in
            app.selectedAssetID = id
            if id == nil || (app.stage == .print) { app.stage = .generate }
        })) {
            if app.generator.isRunning {
                Section("Now") {
                    Button { app.selectedAssetID = app.generator.baseID; app.stage = .generate } label: { GeneratingRow() }
                        .buttonStyle(.plain)
                }
            }
            if !today.isEmpty { Section("Today") { rows(today) } }
            if !earlier.isEmpty { Section("Earlier") { rows(earlier) } }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .overlay {
            if app.library.assets.isEmpty && !app.generator.isRunning {
                ContentUnavailableView("No assets yet", systemImage: "cube", description: Text("Describe something to generate your first asset."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Opaque backing so list rows scrolling underneath never show through the card.
            VStack(spacing: 0) {
                PrinterDock().padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 8)
                PageSwitcher()
            }
            .background(.bar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .toolbar {
            ToolbarItem {
                Button("New Asset", systemImage: "plus") { app.newAsset() }.help("New asset (⌘N)")
            }
        }
    }

    private func rows(_ list: [Asset]) -> some View {
        ForEach(list) { (a: Asset) in
            AssetRow(asset: a)
                .tag(Optional(a.id))
                .contextMenu { menu(a) }
        }
    }

    @ViewBuilder private func menu(_ a: Asset) -> some View {
        Button("Prepare for Print") { app.selectedAssetID = a.id; app.stage = .prepare }
        Button("Reveal in Finder") { app.library.reveal(a) }
        Button("Open Preview in Browser") { NSWorkspace.shared.open(a.htmlURL) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            if app.selectedAssetID == a.id { app.selectedAssetID = nil }
            app.library.trash(a)
        }
    }
}

struct GeneratingRow: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).frame(width: 40, height: 40)
                .overlay { Image(systemName: "sparkles").foregroundStyle(Theme.accent).symbolEffect(.pulse) }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.generator.shortTitle).lineLimit(2).fontWeight(.medium)
                Text(app.generator.phaseLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AssetRow: View {
    @Environment(AppModel.self) private var app
    let asset: Asset
    var body: some View {
        let _ = app.library.revision
        HStack(spacing: 10) {
            Group {
                if let img = NSImage(contentsOf: asset.thumbURL) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "cube").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 40, height: 40)
            .background(.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.title).lineLimit(2).fontWeight(.medium)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        if app.printer.status.isPrinting && app.printer.status.jobName == asset.fileStem { return "Printing" }
        if let r = Slicer.loadResult(asset) {
            let n = r.filaments?.count ?? 1
            return n > 1 ? "Sliced in \(n) colours" : "Sliced"
        }
        if asset.imported == true {
            guard asset.parentId != nil else { return "Imported GLB" }
            return (asset.refinement ?? "").hasPrefix("Smooth") ? "Smoothed version" : "Edited version"
        }
        if asset.purpose == "print" { return "For 3D printing" }
        if asset.purpose == "scene" { return "3D scene" }
        return "Generated"
    }
}

struct PrinterDock: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let p = app.printer
        Button { app.stage = .print } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Bambu Lab P2S", systemImage: "printer").fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Text(stateText).monospacedDigit().foregroundStyle(p.status.isPrinting ? .primary : .secondary)
                }
                if p.status.isPrinting || p.status.isPaused {
                    ProgressView(value: Double(p.status.percent), total: 100).tint(Theme.accent)
                }
                let trays = p.status.trays.filter { !$0.isExternal }
                if !trays.isEmpty || !detailText.isEmpty {
                    HStack {
                        HStack(spacing: 5) { ForEach(trays) { Swatch(hex: $0.colorHex) } }
                        Spacer()
                        Text(detailText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(app.stage == .print ? 0.11 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07)))
    }

    private var stateText: String {
        let p = app.printer
        switch p.connection {
        case .connected: return p.status.isPrinting ? "\(p.status.percent)%" : p.status.stateLabel
        case .connecting: return "Connecting"
        default: return p.isConfigured ? "Offline" : "Set up"
        }
    }

    private var detailText: String {
        let s = app.printer.status
        if s.isPrinting || s.isPaused { return "\(formatDuration(Double(s.remainingMinutes) * 60)) left" }
        return app.printer.connection == .connected ? "Bed \(Int(s.bedTemp))°" : ""
    }
}

// MARK: - Tasks capsule + popover, toasts

struct TasksButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var app = app
        let running = runningCount
        Button { app.showTasks.toggle() } label: {
            HStack(spacing: 6) {
                if running > 0 {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                } else {
                    Image(systemName: "checklist")
                }
                Text(running == 0 ? "Tasks" : "\(running) task\(running == 1 ? "" : "s")").monospacedDigit()
            }
        }
        .help("Tasks (⌥⌘T)")
        .popover(isPresented: $app.showTasks, arrowEdge: .bottom) { TaskList().frame(width: 392) }
    }

    var runningCount: Int {
        var n = app.tasks.running.count
        if app.printer.status.isPrinting && !app.tasks.running.contains(where: { $0.kind == .print }) { n += 1 }
        return n
    }
}

struct TaskList: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tasks").font(.title3.weight(.semibold))
                Spacer()
                if !app.tasks.finished.isEmpty { Button("Clear finished") { app.tasks.clearFinished() }.controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)

            if app.tasks.tasks.isEmpty && !app.printer.status.isPrinting {
                Text("Nothing running. Generations, slices and prints show up here.")
                    .foregroundStyle(.secondary).padding(10)
            }
            if app.printer.status.isPrinting && !app.tasks.running.contains(where: { $0.kind == .print }) {
                TaskRow(task: ForgeTask(kind: .print, title: "Printing \(app.printer.status.jobName)", detail: "", stage: .print))
            }
            ForEach(app.tasks.running) { TaskRow(task: $0) }
            if !app.tasks.finished.isEmpty {
                Divider().padding(.horizontal, 10).padding(.vertical, 4)
                ForEach(app.tasks.finished.prefix(6)) { TaskRow(task: $0) }
            }
            Divider().padding(.top, 4)
            HStack {
                Text(serverText).foregroundStyle(.secondary)
                Spacer()
                SettingsButton(pane: .local) { Text("Model settings") }.controlSize(.small)
            }
            .padding(10)
        }
        .padding(8)
    }

    private var serverText: String {
        let p = app.provider
        if p.kind != .local { return app.engineProblem == nil ? "Using \(ProviderSettings.label(p))" : "\(p.name) needs setup" }
        return switch app.server.state {
        case .ready: !app.server.activeModel.hasSuffix(".gguf") ? "3D Coder ready · in-app (MLX)" : "3D Coder ready on port \(String(Settings.port))"
        case .starting: "3D Coder loading"
        case .failed: "3D Coder error"
        case .stopped: "3D Coder stopped"
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var app
    let task: ForgeTask

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(task.title).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(trailing).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(detail).foregroundStyle(.secondary).lineLimit(2)
                if task.state == .running {
                    if let p = progress { ProgressView(value: p).tint(Theme.accent) }
                    else { ProgressView().progressViewStyle(.linear).tint(Theme.accent) }
                }
            }
            actions
        }
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture { open() }
    }

    @ViewBuilder private var badge: some View {
        RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)).frame(width: 36, height: 36)
            .overlay {
                switch task.state {
                case .done: Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                case .running:
                    switch task.kind {
                    case .generate: Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    case .print: Image(systemName: "printer")
                    case .upload: Image(systemName: "arrow.up.circle")
                    case .download: Image(systemName: "arrow.down.circle")
                    case .slice, .compare: ProgressView().controlSize(.small)
                    }
                }
            }
    }

    @ViewBuilder private var actions: some View {
        if task.state == .running, let cancel = task.cancel {
            Button { cancel(); if task.kind == .generate { app.generationEnded() } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Stop")
        } else if task.state == .failed, let retry = task.retry {
            Button(task.retryTitle ?? "Retry") { retry() }.controlSize(.small)
        } else if task.kind == .print && task.state == .running {
            Button("Show") { open() }.controlSize(.small)
        }
    }

    private var isLivePrint: Bool { task.kind == .print && task.state == .running }
    private var progress: Double? {
        if isLivePrint { return Double(app.printer.status.percent) / 100 }
        if task.kind == .upload { return app.printer.uploadProgress }
        return task.progress
    }
    private var detail: String {
        if task.state != .running { return task.detail }
        if task.kind == .generate {
            return "\(app.generator.phaseLabel), \(Int(app.generator.tokensPerSecond)) tok/s"
        }
        if isLivePrint {
            let s = app.printer.status
            return "Layer \(s.layer) of \(s.totalLayers), \(formatDuration(Double(s.remainingMinutes) * 60)) left"
        }
        return task.detail
    }
    private var trailing: String {
        if isLivePrint { return "\(app.printer.status.percent)%" }
        if task.state == .running { return formatDuration(Date().timeIntervalSince(task.started)) }
        guard let f = task.finished else { return "" }
        return f.formatted(.relative(presentation: .numeric))
    }
    private func open() {
        if let id = task.assetID { app.selectedAssetID = id }
        if let s = task.stage { app.stage = s }
        app.showTasks = false
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let t = app.tasks.toast {
            HStack(spacing: 12) {
                if let thumb = t.thumb, let img = NSImage(contentsOf: thumb) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 32, height: 32).clipShape(Circle())
                } else {
                    Image(systemName: t.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(t.isError ? Theme.warning : Theme.accent).font(.title3)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.title).fontWeight(.medium)
                    Text(t.detail).foregroundStyle(.secondary).lineLimit(1)
                }
                if t.assetID != nil {
                    Button("Show") {
                        if let id = t.assetID { app.selectedAssetID = id }
                        if let s = t.stage { app.stage = s }
                        app.tasks.toast = nil
                    }
                    .buttonStyle(.glass)
                }
                Button { app.tasks.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .frame(maxWidth: 560)
        }
    }
}

// MARK: - Menu bar

struct ForgeCommands: Commands {
    let app: AppModel

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.openSettings() }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .help) { HelpMenuItems(app: app) }
        CommandGroup(after: .sidebar) {
            Button(app.showInspector ? "Hide Inspector" : "Show Inspector") {
                withAnimation(.snappy(duration: 0.25)) { app.showInspector.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandGroup(after: .appSettings) {
            Menu("Model") {
                Button("Start 3D Coder") { Task { await app.server.start() } }
                Button("Restart 3D Coder") { Task { await app.server.restart() } }
                Button("Stop 3D Coder") { app.server.stop() }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Asset") { app.newAsset() }.keyboardShortcut("n")
            Menu("New from Example") {
                ForEach(examplePrompts) { e in
                    Button("\(e.domain): \(e.text)") { app.newAsset(); app.composerText = e.text }
                }
            }
            Button("Import GLB…") { app.importGLB() }.keyboardShortcut("o")
            Button("Browse NVIDIA SimReady Library…") { app.simReadyIntoScene = false; app.showSimReady = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Generate from Picture…") {
                if let img = ReferenceImage.choose() { app.newAsset(); app.composerImage = img }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export GLB…") { Task { await app.exportGLB() } }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(app.selectedAsset == nil)
            Button("Export OBJ…") { Task { await app.exportOBJ() } }.disabled(app.selectedAsset == nil)
            Button("Open in Blender") { Task { await app.openInBlender() } }
                .keyboardShortcut("b", modifiers: [.command, .option]).disabled(app.selectedAsset == nil)
            Button("Save Blender File…") { Task { await app.saveBlendFile() } }.disabled(app.selectedAsset == nil)
            Button("Export STL…") { app.exportSTLs() }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option]).disabled(app.selectedAsset == nil)
            Button("Save Sliced File…") { app.saveSliced() }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(app.selectedAsset == nil)
            Button("Copy to Godot Project") { Task { await app.copyToGodot() } }
                .keyboardShortcut("g", modifiers: [.command, .option]).disabled(app.selectedAsset == nil)
            Divider()
            Button("Open in Bambu Studio") { if let a = app.selectedAsset { app.openInStudio(a.threeMFURL) } }
                .disabled(!(app.selectedAsset.map { $0.has($0.threeMFURL) } ?? false))
            Button("Open Preview in Browser") { if let a = app.selectedAsset { NSWorkspace.shared.open(a.htmlURL) } }
                .disabled(app.selectedAsset == nil)
            Button("Reveal in Finder") { if let a = app.selectedAsset { app.library.reveal(a) } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(app.selectedAsset == nil)
            Divider()
            Button("Move to Trash") {
                if let a = app.selectedAsset { app.selectedAssetID = nil; app.library.trash(a) }
            }
            .keyboardShortcut(.delete, modifiers: .command).disabled(app.selectedAsset == nil)
        }

        CommandMenu("Asset") {
            Button("Generate") { app.generate() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled((app.composerText.trimmingCharacters(in: .whitespaces).isEmpty && app.composerImage == nil) || !app.engineReady || app.generator.isRunning)
            Button("Refine…") { app.stage = .generate; app.showInspector = true; app.refineFocusToken += 1 }
                .keyboardShortcut("r").disabled(app.selectedAsset == nil || app.generator.isRunning)
            Button("Fix Script Errors") { app.fixErrors() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(app.preview.errors.isEmpty || app.selectedAsset == nil)
            Button("Stop Generating") { app.stopGenerating() }
                .keyboardShortcut(".").disabled(!app.generator.isRunning)
            Divider()
            ForEach(Array(Stage.allCases.enumerated()), id: \.element) { i, s in
                Button("Go to \(s.title)") { app.go(s) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    .disabled(!app.canGo(s))
            }
            Divider()
            Button("Lay Flat") { app.prep.push("window.prep.layFlat()") }
                .keyboardShortcut("f", modifiers: [.command, .option]).disabled(app.stage != .prepare)
            Toggle("Multi-colour", isOn: Binding(get: { app.prep.multicolor }, set: { app.prep.multicolor = $0; app.prep.variants = []; app.prep.pushColors() }))
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(app.selectedAsset == nil)
            Button("Slice Now") { Task { await app.slice() } }
                .keyboardShortcut("b").disabled(app.selectedAsset == nil || app.prep.busy != nil)
            Button("Send to Printer…") { app.showPrintSheet = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!(app.selectedAsset.map { $0.has($0.threeMFURL) } ?? false) || app.printer.connection != .connected)
        }

        CommandMenu("Printer") {
            let p = app.printer
            Text("Bambu Lab P2S: \(p.connection == .connected ? p.status.stateLabel : "Not connected")")
            if p.connection == .connected {
                Button("Disconnect") { p.disconnect() }
            } else {
                Button("Connect") { p.connect() }.disabled(!p.isConfigured)
            }
            Divider()
            if p.status.isPaused {
                Button("Resume Print") { p.resume() }.keyboardShortcut("p", modifiers: [.command, .option])
            } else {
                Button("Pause Print") { p.pause() }.keyboardShortcut("p", modifiers: [.command, .option]).disabled(!p.status.isPrinting)
            }
            Button("Stop Print…") { app.confirmStopPrint = true }.disabled(!(p.status.isPrinting || p.status.isPaused))
            Menu("Speed") {
                ForEach([(1, "Silent"), (2, "Standard"), (3, "Sport"), (4, "Ludicrous")], id: \.0) { lvl, name in
                    Button((p.status.speedLevel == lvl ? "✓ " : "") + name) { p.setSpeed(lvl) }
                }
            }
            .disabled(!p.status.isPrinting)
            Divider()
            Toggle("Chamber Light", isOn: Binding(get: { p.status.chamberLight }, set: { p.setLight($0) }))
                .keyboardShortcut("l", modifiers: [.command, .option]).disabled(p.connection != .connected)
            Button("Home Axes") { p.home() }.disabled(p.connection != .connected || p.status.isPrinting)
            Button("Watch Camera") { app.watchCamera() }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(!p.isConfigured)
            Divider()
            Button("Find Printers on Network") { app.stage = .print; app.discovery.scan() }
            Button("Printer Settings…") { app.openSettings(.printer) }
        }

        CommandGroup(before: .toolbar) {
            Button(app.showTasks ? "Hide Tasks" : "Show Tasks") { app.showTasks.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Reset 3D View") {
                app.prep.push("window.prep && window.prep.frame && window.prep.frame()")
                Task { await app.prep.gcodeWeb.eval("window.gview && window.gview.resetView()") }
            }
            .keyboardShortcut("0")
            Divider()
        }
    }
}
