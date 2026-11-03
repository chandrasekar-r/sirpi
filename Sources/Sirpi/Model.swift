import Foundation
import Observation
import AppKit

// MARK: - llama-server lifecycle

@Observable @MainActor
final class LlamaServer {
    enum State: Equatable {
        case stopped, starting, ready(external: Bool), failed(String)
        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    var state: State = .stopped
    var log: [String] = []
    var modelName: String = ""
    private var process: Process?
    /// In-process MLX engine; used when the selected model is an MLX folder rather than a .gguf.
    let native = NativeEngine()
    var usesNative: Bool { NativeEngine.isMLXModel(Settings.modelPath) }
    /// Observable copy of the active model file name, for labels.
    var activeModel = ""

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func healthy() async -> Bool {
        var req = URLRequest(url: Settings.serverBase.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("ok")
    }

    /// Adopts an already-running server on the port, otherwise launches one.
    func start() async {
        if case .starting = state { return }
        state = .starting
        activeModel = (Settings.modelPath as NSString).lastPathComponent
        if usesNative {
            let path = Settings.modelPath
            log.append("Loading \((path as NSString).lastPathComponent) in-process with MLX")
            do {
                try await native.load(path: path)
                modelName = (path as NSString).lastPathComponent
                log.append("Model ready")
                state = .ready(external: false)
            } catch {
                state = .failed("Could not load the MLX model: \(error.localizedDescription)")
            }
            return
        }
        native.unload()
        if await healthy() {
            await refreshModelName()
            state = .ready(external: process == nil)
            return
        }
        let exe = Settings.llamaServerPath, model = Settings.modelPath
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            state = .failed("llama-server not found at \(exe). Install with: brew install llama.cpp"); return
        }
        guard FileManager.default.fileExists(atPath: model) else {
            state = .failed("Model file missing: \(model). Download it in Settings."); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", String(Settings.port),
                       "-ngl", "99", "-c", String(Settings.contextSize), "-np", "1", "--jinja",
                       "--temp", "0.8", "--top-k", "40", "--top-p", "0.95", "--min-p", "0.0"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard !s.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.log.append(contentsOf: s.split(separator: "\n").map(String.init))
                if self.log.count > 400 { self.log.removeFirst(self.log.count - 400) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                if case .stopped = self.state { return }
                self.state = .failed("llama-server exited (code \(proc.terminationStatus)). See log in Settings.")
            }
        }
        do { try p.run() } catch { state = .failed(error.localizedDescription); return }
        process = p
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            if process == nil { return }
            if await healthy() {
                await refreshModelName()
                state = .ready(external: false)
                return
            }
        }
        state = .failed("Timed out waiting for llama-server to load the model.")
    }

    func stop() {
        state = .stopped
        native.unload()
        process?.terminate()
        process = nil
    }

    func restart() async {
        stop()
        try? await Task.sleep(for: .milliseconds(800))
        await start()
    }

    private func refreshModelName() async {
        guard let (data, _) = try? await URLSession.shared.data(from: Settings.serverBase.appendingPathComponent("v1/models")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["data"] as? [[String: Any]])?.first, let id = first["id"] as? String else { return }
        modelName = (id as NSString).lastPathComponent
    }
}

// MARK: - Generation

let systemPrompt = """
Create game assets for the Godot editor, which uses GLB files. Create whatever the user requests as a good-quality low-poly asset using only Three.js in one complete standalone HTML file. The HTML must show the asset and include an Export GLB button that downloads a working GLB. If the requested asset needs animation, add it and include the animation in the exported GLB; otherwise make it static.
"""

/// Same text the fine-tune was trained with (finetune/tools/gen.py PRINT_SYSTEM); keep them identical.
let printSystemPrompt = """
Create objects for FDM 3D printing (Bambu Lab printer, 256 mm build plate) using only Three.js in one complete standalone HTML file. Model the requested object at its real size in millimetres (1 unit = 1 mm) as one solid, watertight piece: parts must overlap so they fuse, nothing may float, it must stand on a flat base resting on y = 0, walls must be at least 2 mm thick, and overhangs should stay under 45 degrees where possible. The HTML must show the object, state its size in mm, and include an Export GLB button that downloads a working GLB of the object only.
"""

/// A whole environment (street, room, square) built from separately named objects so it can be customised afterwards.
let sceneSystemPrompt = """
Create a complete 3D environment scene using only Three.js in one complete standalone HTML file. Build the requested place at real-world scale (1 unit = 1 metre) with a ground or floor, sensible lighting and a camera that frames the whole scene. Make every distinct object (each building, wall, door, window, lamp, tree, bench, vehicle, piece of furniture, prop) its own THREE.Group with a clear descriptive name (for example group.name = "Street lamp 2"), added directly to one top-level group named "Scene", so each object can be selected and moved later. Reuse geometries and materials for repeated objects. The HTML must show the scene, include OrbitControls, and include an Export GLB button that downloads a working GLB of the "Scene" group.
"""

/// What the asset is for: a game-engine GLB, a physical FDM print, or a customisable environment. Picks the system prompt.
enum AssetPurpose: String, CaseIterable, Identifiable {
    case game, print, scene
    var id: String { rawValue }
    static let key = "assetPurpose"
    static var current: AssetPurpose { AssetPurpose(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .game }
    var title: String {
        switch self { case .game: "Game asset"; case .print: "3D print"; case .scene: "3D scene" }
    }
    var symbol: String {
        switch self { case .game: "gamecontroller"; case .print: "printer"; case .scene: "building.2" }
    }
    var system: String {
        switch self { case .game: systemPrompt; case .print: printSystemPrompt; case .scene: sceneSystemPrompt }
    }
}

struct ExamplePrompt: Identifiable { let id = UUID(); let domain: String; let text: String }

let examplePrompts: [ExamplePrompt] = [
    .init(domain: "Characters", text: "Create a village blacksmith wearing a blue apron."),
    .init(domain: "Enemies", text: "Create a swamp goblin scout with a wooden shield."),
    .init(domain: "Bosses", text: "Create a stone golem boss with glowing green crystals."),
    .init(domain: "Companions", text: "Create a tiny fox companion wearing a red scarf."),
    .init(domain: "Weapons", text: "Create a short iron sword with a leather-wrapped grip."),
    .init(domain: "Items", text: "Create a blue mana potion in a hexagonal glass bottle."),
    .init(domain: "Props", text: "Create a weathered wooden workbench with a small lantern."),
    .init(domain: "Nature", text: "Create a pine tree growing on a rocky mound."),
    .init(domain: "Architecture", text: "Create a stone dungeon doorway module with an iron frame."),
    .init(domain: "Interactive", text: "Create a wooden gate with an opening animation."),
    .init(domain: "Vehicles", text: "Create a compact courier motorcycle with cargo boxes."),
    .init(domain: "Aircraft", text: "Create a small cargo airship with twin propellers."),
    .init(domain: "Watercraft", text: "Create a weathered fishing skiff with nets and wooden crates."),
    .init(domain: "Machinery", text: "Create a compact mining conveyor with metal support legs."),
    .init(domain: "Traps", text: "Create a hidden spiked floor trap with stone tiles."),
    .init(domain: "Puzzles", text: "Create a glowing rune sequence console with three stone buttons."),
    .init(domain: "Battlefield", text: "Build a jungle siege platform"),
    .init(domain: "Orcs", text: "Create a red orc Leader"),
]

@Observable @MainActor
final class Generator {
    enum Phase: Equatable { case idle, waiting, thinking, writing, done, failed(String), cancelled }

    var phase: Phase = .idle
    var reasoning = ""
    var content = ""
    var tokens = 0
    var started: Date?
    var finished: Date?
    var title = ""

    private var task: Task<Void, Never>?

    var isRunning: Bool { [.waiting, .thinking, .writing].contains(phase) }
    var thinkingStarted: Date?
    var writingStarted: Date?
    var reasoningTokens = 0
    var codeTokens = 0
    /// Decode speed reported by the engine for the last finished generation.
    var measuredSpeed: Double?
    /// Which provider/model is writing the current asset.
    var engineLabel = ""
    /// Game asset or 3D print, fixed for the whole generation.
    var purpose: AssetPurpose = .game
    /// Picture guiding the current generation, if any.
    var reference: ReferenceImage?
    /// Shown while a vision model reads the picture for a text-only engine.
    var statusNote: String?
    /// Picture shown to engines that can see, in place of `reference` (e.g. the reference-vs-render comparison sheet).
    private var attachment: ReferenceImage?

    enum Mode: Equatable { case fresh, patch, rewrite, continuation }
    /// How the current answer is turned into a file.
    private(set) var mode: Mode = .fresh
    /// The file a patch applies to.
    private var baseHTML = ""
    /// The partial answer being continued; `content` starts with it.
    private var prefix = ""

    /// Everything needed to repeat or continue the last request.
    private struct Request {
        var messages: [[String: String]]
        var prompt: String
        var base: Asset?
        var refinement: String?
        var image: ReferenceImage?
        var attachment: ReferenceImage?
        var context: String?
        var purpose: AssetPurpose
        var onDone: (Asset) -> Void
        /// Engine that wrote it; a continuation uses the same one.
        var providerID: String
    }
    /// Set for one run: the engine to use instead of the selected one.
    private var providerOverride: Provider?

    /// Engine a continuation will use.
    var continueProvider: Provider? { last.map { Providers.find($0.providerID) } }
    private var last: Request?
    /// Context of a new asset, saved with it (refinements inherit their parent's).
    private var briefToSave: String?
    private weak var lastLibrary: AssetLibrary?

    /// A stopped or cut-off answer that can be continued instead of starting over.
    var canContinue: Bool {
        guard last != nil, !content.isEmpty, mode != .patch else { return false }
        switch phase {
        case .failed, .cancelled:
            if let html = Self.extractHTML(content) { return Continuation.isTruncated(html) }
            return content.count > 200
        default: return false
        }
    }

    var phaseLabel: String {
        switch phase {
        case .waiting: "Waiting for model"
        case .thinking: "Planning"
        case .writing: "Writing code"
        case .done: "Done"
        case .cancelled: "Stopped"
        case .failed: "Failed"
        case .idle: ""
        }
    }

    var shortTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 40 ? String(t.prefix(38)) + "…" : (t.prefix(1).uppercased() + t.dropFirst())
    }
    var elapsed: Double { ((finished ?? Date()).timeIntervalSince(started ?? Date())) }
    var tokensPerSecond: Double { elapsed > 0.5 ? Double(tokens) / elapsed : 0 }

    /// Starts a generation. `base` + `refinement` turns it into a follow-up edit of an existing asset.
    func generate(prompt: String, base: Asset? = nil, refinement: String? = nil, image: ReferenceImage? = nil,
                  attachment: ReferenceImage? = nil, context: String? = nil, fullRewrite: Bool = false,
                  library: AssetLibrary, onDone: @escaping (Asset) -> Void) {
        cancel()
        reasoning = ""; content = ""; tokens = 0; started = Date(); finished = nil
        thinkingStarted = nil; writingStarted = nil; reasoningTokens = 0; codeTokens = 0
        phase = .waiting
        title = refinement ?? prompt
        prefix = ""
        mode = .fresh
        statusNote = nil

        let purpose = base.flatMap { AssetPurpose(rawValue: $0.purpose ?? "") } ?? AssetPurpose.current
        self.purpose = purpose
        var messages: [[String: String]] = [["role": "system", "content": purpose.system]]
        // Imported GLBs show a generic viewer page; there is no generated code to patch.
        if let base, let refinement, base.imported != true, let html = try? String(contentsOf: base.htmlURL, encoding: .utf8) {
            messages.append(["role": "user", "content": base.fullRequest])
            messages.append(["role": "assistant", "content": "```html\n\(html)\n```"])
            let patch = Patch.enabled && !fullRewrite
            mode = patch ? .patch : .rewrite
            baseHTML = html
            messages.append(["role": "user", "content": refinement + "\n\n"
                             + (patch ? Patch.instruction : "Return the complete updated standalone HTML file.")])
        } else {
            messages.append(["role": "user", "content": prompt + DetailLevel.current.promptSuffix
                             + (context.map { "\n\n" + $0 } ?? "")])
        }
        reference = image
        self.attachment = attachment
        briefToSave = base == nil ? context : nil
        last = Request(messages: messages, prompt: prompt, base: base, refinement: refinement, image: image,
                       attachment: attachment, context: context, purpose: purpose, onDone: onDone,
                       providerID: ProviderSettings.selected.id)
        lastLibrary = library

        task = Task(priority: .userInitiated) { [weak self] in
            await self?.run(messages: messages, prompt: prompt, base: base, refinement: refinement, library: library, onDone: onDone)
        }
    }

    /// Continues a stopped or cut-off answer from where it ends; the new tokens are appended to the partial file.
    func continueLast() {
        guard canContinue, var req = last, let library = lastLibrary else { return }
        let partial = content
        let tail = String(partial.suffix(600))
        req.messages.append(["role": "assistant", "content": partial])
        req.messages.append(["role": "user", "content": Continuation.request(tail: tail)])
        task?.cancel(); task = nil
        reasoning = ""; tokens = 0; started = Date(); finished = nil
        thinkingStarted = nil; writingStarted = nil; reasoningTokens = 0; codeTokens = 0
        phase = .waiting
        purpose = req.purpose
        prefix = partial
        mode = .continuation
        providerOverride = Providers.find(req.providerID)
        let messages = req.messages
        task = Task(priority: .userInitiated) { [weak self] in
            await self?.run(messages: messages, prompt: req.prompt, base: req.base, refinement: req.refinement,
                            library: library, onDone: req.onDone)
        }
    }

    /// Forgets a stopped answer so the Continue banner goes away.
    func discardPartial() {
        guard !isRunning else { return }
        content = ""; reasoning = ""; prefix = ""; last = nil; phase = .idle
    }

    func cancel() {
        task?.cancel(); task = nil
        if isRunning { phase = .cancelled; finished = Date() }
    }

    /// Set by AppModel: the in-process engine when an MLX model is selected.
    weak var server: LlamaServer?

    private func run(messages: [[String: String]], prompt: String, base: Asset?, refinement: String?,
                     library: AssetLibrary, onDone: @escaping (Asset) -> Void) async {
        let provider = providerOverride ?? ProviderSettings.selected
        providerOverride = nil
        engineLabel = ProviderSettings.label(provider)
        var messages = messages
        var nativeImage: ReferenceImage?
        if reference == nil, let attachment, provider.seesImages, mode != .continuation {
            nativeImage = attachment // e.g. the review renders, for engines that can see them
        }
        if let image = reference, mode != .continuation {
            if provider.seesImages {
                nativeImage = attachment ?? image
            } else {
                // Text-only engine: a vision model turns the picture into a modelling brief first.
                statusNote = "Reading the reference picture with \(ImageDescriber.describer?.name ?? "a vision model")…"
                do {
                    let brief = try await ImageDescriber.describe(image)
                    if Task.isCancelled { return }
                    reasoning = "Reference picture, described for the model:\n\(brief)\n\n"
                    if let i = messages.lastIndex(where: { $0["role"] == "user" }) {
                        messages[i]["content"] = (messages[i]["content"] ?? "")
                            + "\n\nMatch this reference picture of the object:\n" + brief
                    }
                } catch {
                    if Task.isCancelled { return }
                    statusNote = nil
                    phase = .failed(error.localizedDescription); finished = Date(); return
                }
                statusNote = nil
            }
        }
        switch provider.kind {
        case .openAI, .anthropic:
            await consume(RemoteEngine.stream(provider, messages: messages, thinking: Settings.enableThinking, image: nativeImage),
                          prompt: prompt, base: base, refinement: refinement, library: library, onDone: onDone)
            return
        case .cli:
            await consume(CLIRunner.stream(provider, messages: messages, image: nativeImage),
                          prompt: prompt, base: base, refinement: refinement, library: library, onDone: onDone)
            return
        case .local:
            break
        }
        if let server, server.usesNative {
            let engine = server.native
            await consume(engine.stream(messages: messages, thinking: Settings.enableThinking,
                                        temperature: Settings.temperature, maxTokens: Settings.contextSize),
                          prompt: prompt, base: base, refinement: refinement, library: library, onDone: onDone)
            return
        }
        var body: [String: Any] = [
            "messages": messages, "stream": true,
            "temperature": Settings.temperature, "top_k": 40, "top_p": 0.95, "min_p": 0.0,
        ]
        if !Settings.enableThinking { body["chat_template_kwargs"] = ["enable_thinking": false] }
        var req = URLRequest(url: Settings.serverBase.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 1800

        var rBuf = "", cBuf = "", lastFlush = Date()
        func flush() {
            if !rBuf.isEmpty { reasoning += rBuf; rBuf = "" }
            if !cBuf.isEmpty { content += cBuf; cBuf = "" }
            lastFlush = Date()
        }
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                var msg = ""
                for try await line in bytes.lines { msg += line }
                phase = .failed("Server error \(http.statusCode): \(msg.prefix(300))"); finished = Date(); return
            }
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let choice = (obj["choices"] as? [[String: Any]])?.first,
                      let delta = choice["delta"] as? [String: Any] else { continue }
                if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                    rBuf += r; tokens += 1; reasoningTokens += 1
                    if phase != .thinking { phase = .thinking; thinkingStarted = Date() }
                }
                if let c = delta["content"] as? String, !c.isEmpty {
                    cBuf += c; tokens += 1; codeTokens += 1
                    if phase != .writing { flush(); phase = .writing; writingStarted = Date() }
                }
                if Date().timeIntervalSince(lastFlush) > 0.12 { flush() }
            }
            flush()
        } catch {
            if Task.isCancelled { return }
            flush()
            phase = .failed("Connection failed: \(error.localizedDescription)"); finished = Date(); return
        }
        await finish(prompt: prompt, base: base, refinement: refinement, library: library, onDone: onDone)
    }

    /// Reads any engine's piece stream into the live reasoning/content buffers, then saves the asset.
    private func consume(_ stream: AsyncThrowingStream<NativeEngine.Piece, Error>, prompt: String, base: Asset?,
                         refinement: String?, library: AssetLibrary, onDone: @escaping (Asset) -> Void) async {
        var rBuf = "", cBuf = "", lastFlush = Date()
        func flush() {
            if !rBuf.isEmpty { reasoning += rBuf; rBuf = "" }
            if !cBuf.isEmpty { content += cBuf; cBuf = "" }
            lastFlush = Date()
        }
        do {
            for try await piece in stream {
                if Task.isCancelled { return }
                switch piece {
                case .reasoning(let r, let n):
                    if phase != .thinking { phase = .thinking; thinkingStarted = Date() }
                    rBuf += r; tokens += n; reasoningTokens += n
                case .content(let c, let n):
                    if phase != .writing { flush(); phase = .writing; writingStarted = Date() }
                    cBuf += c; tokens += n; codeTokens += n
                case .stats(let n, let tps):
                    server?.log.append(String(format: "Generated %d tokens at %.1f tok/s", n, tps))
                    measuredSpeed = tps
                }
                flush()
            }
            flush()
        } catch {
            if Task.isCancelled { return }
            flush()
            phase = .failed("Generation failed: \(error.localizedDescription)"); finished = Date(); return
        }
        if Task.isCancelled { return }
        await finish(prompt: prompt, base: base, refinement: refinement, library: library, onDone: onDone)
    }

    private func finish(prompt: String, base: Asset?, refinement: String?, library: AssetLibrary,
                        onDone: @escaping (Asset) -> Void) async {
        finished = Date()
        var answer = content
        if mode == .continuation {
            answer = Continuation.join(prefix, String(content.dropFirst(prefix.count)))
            content = answer
        }
        if mode == .patch {
            let blocks = Patch.parse(answer)
            if !blocks.isEmpty {
                let (patched, failed) = Patch.apply(blocks, to: baseHTML)
                if let patched {
                    save(html: patched, prompt: prompt, base: base, refinement: refinement, library: library, onDone: onDone)
                } else {
                    // The model misquoted the code: redo it as a full rewrite rather than fail.
                    statusNote = "Edit \((failed ?? 0) + 1) of \(blocks.count) didn't match the code, so the model is rewriting the whole file."
                    rewriteAfterFailedPatch()
                }
                return
            }
            // No edit blocks: the model returned a whole file instead, which is allowed.
        }
        guard let html = Self.extractHTML(answer) else {
            phase = .failed("The model did not return an HTML file. Try again or rephrase the prompt."); return
        }
        if Continuation.isTruncated(html) {
            phase = .failed("The answer was cut off before the file was finished. Continue it to finish the file.")
            return
        }
        save(html: html, prompt: prompt, base: base, refinement: refinement, library: library, onDone: onDone)
    }

    private func rewriteAfterFailedPatch() {
        guard let req = last, let library = lastLibrary else { phase = .failed("The fix could not be applied."); return }
        let note = statusNote
        generate(prompt: req.prompt, base: req.base, refinement: req.refinement, image: req.image, attachment: req.attachment,
                 context: req.context, fullRewrite: true, library: library, onDone: req.onDone)
        statusNote = note
    }

    private func save(html: String, prompt: String, base: Asset?, refinement: String?, library: AssetLibrary,
                      onDone: @escaping (Asset) -> Void) {
        do {
            let a = try library.create(prompt: prompt, html: html, parent: base, refinement: refinement,
                                       seconds: elapsed, tokens: tokens, engine: engineLabel, reference: reference?.jpeg,
                                       purpose: purpose.rawValue, brief: briefToSave)
            phase = .done
            onDone(a)
        } catch {
            phase = .failed("Could not save asset: \(error.localizedDescription)")
        }
    }

    static func extractHTML(_ text: String) -> String? {
        // Prefer a fenced ```html block; tolerate a missing closing fence (truncated output).
        if let r = text.range(of: "```html", options: .caseInsensitive) ?? text.range(of: "```") {
            var body = String(text[r.upperBound...])
            if let end = body.range(of: "\n```") { body = String(body[..<end.lowerBound]) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.lowercased().contains("<html") || body.lowercased().contains("<script") { return body }
        }
        if let r = text.range(of: "<!doctype", options: .caseInsensitive) ?? text.range(of: "<html", options: .caseInsensitive) {
            var body = String(text[r.lowerBound...])
            if let end = body.range(of: "</html>", options: [.caseInsensitive, .backwards]) {
                body = String(body[..<end.upperBound])
            }
            return body
        }
        return nil
    }
}

// MARK: - Model download (Hugging Face)

@Observable @MainActor
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    var progress: Double = 0
    var active = false
    var error: String?
    private var destination: URL?
    private var onDone: (() -> Void)?

    static let repo = "https://huggingface.co/ccore/Qwen3.5-4B-GLB-3D-Coder/resolve/main/"
    static let files = ["Qwen3.5-4B-GLB-3D-Coder-Q8_0.gguf", "Qwen3.5-4B-GLB-3D-Coder-Q4_K_M.gguf"]

    func download(_ file: String, onDone: @escaping () -> Void) {
        guard !active, let url = URL(string: Self.repo + file + "?download=true") else { return }
        try? FileManager.default.createDirectory(at: Paths.defaultModelDir, withIntermediateDirectories: true)
        destination = Paths.defaultModelDir.appendingPathComponent(file)
        self.onDone = onDone
        active = true; progress = 0; error = nil
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session.downloadTask(with: url).resume()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        MainActor.assumeIsolated { self.progress = p }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let dest = destination else { return }
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: location, to: dest) } catch { self.error = error.localizedDescription }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            active = false
            if let error { self.error = error.localizedDescription } else { onDone?() }
            session.finishTasksAndInvalidate()
        }
    }
}
