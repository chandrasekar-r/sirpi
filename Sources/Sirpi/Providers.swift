import Foundation

/// Remote engines stream text chunks, not token ids; about 4 characters of code per token.
func approxTokens(_ s: String) -> Int { max(1, (s.utf8.count + 3) / 4) }

// MARK: - Provider catalogue
//
// Four ways to get an asset written:
//   local      the bundled 3D Coder model (MLX in-process, or llama-server for GGUF files)
//   openAI     any OpenAI-compatible /chat/completions endpoint (OpenAI, xAI Grok, Gemini, Cloudflare
//              Workers AI, OpenRouter, Groq, DeepSeek, Mistral, Ollama, LM Studio, custom)
//   anthropic  the Claude API (Messages, streamed)
//   cli        a coding-agent CLI already signed in on this Mac (Claude Code, opencode, Grok, pi,
//              Gemini CLI, Codex, Cursor Agent), run headless in an empty folder

enum ProviderKind: String { case local, openAI, anthropic, cli }

/// How a CLI's stdout is read.
enum CLIFormat { case claude, grok, opencode, kimi, plain }

struct Provider: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: ProviderKind
    let symbol: String
    var baseURL = ""
    var defaultModel = ""
    var needsKey = true
    var needsAccount = false
    var keyURL = ""
    var tokenParam = "max_tokens"
    var executable = ""
    var cliFormat: CLIFormat = .plain
    var note = ""

    static func == (a: Provider, b: Provider) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var group: String {
        switch kind {
        case .local: "On this Mac"
        case .cli: "Coding agents (CLI)"
        case .anthropic, .openAI: needsKey ? "Cloud APIs" : "Local servers"
        }
    }
}

enum Providers {
    static let local = Provider(id: "local", name: "3D Coder (on this Mac)", kind: .local, symbol: "cpu", needsKey: false,
                                note: "The fine-tuned Qwen3.5 4B GLB coder. Free, private, works offline.")

    static let all: [Provider] = [
        local,
        // CLI agents: use the account you are already signed in with.
        Provider(id: "claude-code", name: "Claude Code", kind: .cli, symbol: "terminal", needsKey: false,
                 executable: "claude", cliFormat: .claude,
                 note: "Runs `claude -p` with tools, MCP servers and hooks turned off. Uses your Claude login. Model: opus, sonnet, haiku or a full ID; blank uses your default."),
        Provider(id: "opencode", name: "opencode", kind: .cli, symbol: "terminal", needsKey: false,
                 executable: "opencode", cliFormat: .opencode,
                 note: "Runs `opencode run`. Model is provider/model, e.g. cloudflare-workers-ai/@cf/moonshotai/kimi-k2.7-code. Blank uses opencode's default."),
        Provider(id: "grok-cli", name: "Grok CLI", kind: .cli, symbol: "terminal", needsKey: false,
                 executable: "grok", cliFormat: .grok,
                 note: "Runs `grok -p` headless with web search off. Uses your Grok login."),
        Provider(id: "kimi", name: "Kimi Code", kind: .cli, symbol: "terminal", needsKey: false,
                 executable: "kimi", cliFormat: .kimi,
                 note: "Runs `kimi acp` with your Kimi login and streams the answer. Models come from your Kimi config (k3, k3.1-pro, kimi-for-coding…)."),
        Provider(id: "pi", name: "pi", kind: .cli, symbol: "terminal", needsKey: false,
                 executable: "pi", cliFormat: .plain,
                 note: "Runs `pi -p`. Install: npm i -g @mariozechner/pi-coding-agent"),
        Provider(id: "gemini-cli", name: "Gemini CLI", kind: .cli, symbol: "terminal", needsKey: false,
                 executable: "gemini", cliFormat: .plain,
                 note: "Runs `gemini -p`. Sign in once in Terminal, or set GEMINI_API_KEY in your shell profile."),
        Provider(id: "codex", name: "Codex CLI", kind: .cli, symbol: "terminal", needsKey: false,
                 executable: "codex", cliFormat: .plain, note: "Runs `codex exec` in a read-only sandbox."),
        Provider(id: "cursor-agent", name: "Cursor Agent", kind: .cli, symbol: "terminal", needsKey: false,
                 executable: "cursor-agent", cliFormat: .plain, note: "Runs `cursor-agent -p`. Sign in first with `cursor-agent login`."),

        // Cloud APIs.
        Provider(id: "anthropic", name: "Claude API", kind: .anthropic, symbol: "cloud",
                 baseURL: "https://api.anthropic.com/v1", defaultModel: "claude-opus-5-5",
                 keyURL: "https://platform.claude.com/settings/keys",
                 note: "Adaptive thinking with streamed summaries. Think first maps to high effort, off to low."),
        Provider(id: "openai", name: "OpenAI", kind: .openAI, symbol: "cloud",
                 baseURL: "https://api.openai.com/v1", defaultModel: "gpt-5", keyURL: "https://platform.openai.com/api-keys",
                 tokenParam: "max_completion_tokens"),
        Provider(id: "xai", name: "xAI Grok", kind: .openAI, symbol: "cloud",
                 baseURL: "https://api.x.ai/v1", defaultModel: "grok-4", keyURL: "https://console.x.ai"),
        Provider(id: "gemini", name: "Google Gemini", kind: .openAI, symbol: "cloud",
                 baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-2.5-pro",
                 keyURL: "https://aistudio.google.com/apikey"),
        Provider(id: "cloudflare", name: "Cloudflare Workers AI", kind: .openAI, symbol: "cloud",
                 baseURL: "https://api.cloudflare.com/client/v4/accounts/{account}/ai/v1",
                 defaultModel: "@cf/moonshotai/kimi-k2.7-code", needsAccount: true,
                 keyURL: "https://dash.cloudflare.com/profile/api-tokens",
                 note: "Needs an API token with Workers AI read access and your account ID."),
        Provider(id: "openrouter", name: "OpenRouter", kind: .openAI, symbol: "cloud",
                 baseURL: "https://openrouter.ai/api/v1", defaultModel: "openrouter/auto", keyURL: "https://openrouter.ai/keys"),
        Provider(id: "groq", name: "Groq", kind: .openAI, symbol: "cloud",
                 baseURL: "https://api.groq.com/openai/v1", defaultModel: "openai/gpt-oss-120b", keyURL: "https://console.groq.com/keys"),
        Provider(id: "deepseek", name: "DeepSeek", kind: .openAI, symbol: "cloud",
                 baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat", keyURL: "https://platform.deepseek.com/api_keys"),
        Provider(id: "mistral", name: "Mistral", kind: .openAI, symbol: "cloud",
                 baseURL: "https://api.mistral.ai/v1", defaultModel: "codestral-latest", keyURL: "https://console.mistral.ai/api-keys"),

        // Local servers.
        Provider(id: "ollama", name: "Ollama", kind: .openAI, symbol: "server.rack",
                 baseURL: "http://127.0.0.1:11434/v1", defaultModel: "qwen3-coder", needsKey: false),
        Provider(id: "lmstudio", name: "LM Studio", kind: .openAI, symbol: "server.rack",
                 baseURL: "http://127.0.0.1:1234/v1", defaultModel: "", needsKey: false),
        Provider(id: "custom", name: "Custom (OpenAI-compatible)", kind: .openAI, symbol: "server.rack",
                 baseURL: "http://127.0.0.1:8000/v1", defaultModel: "", needsKey: false,
                 note: "Any server that speaks /v1/chat/completions. Add a key if it needs one."),
    ]

    static func find(_ id: String) -> Provider { all.first { $0.id == id } ?? local }
    static var groups: [(String, [Provider])] {
        let order = ["On this Mac", "Coding agents (CLI)", "Cloud APIs", "Local servers"]
        return order.map { g in (g, all.filter { $0.group == g }) }
    }
}

// MARK: - Per-provider settings

enum ProviderSettings {
    static let selectedKey = "provider"
    static var d: UserDefaults { .standard }

    static var selected: Provider { Providers.find(d.string(forKey: selectedKey) ?? "local") }

    static func model(_ p: Provider) -> String {
        let v = d.string(forKey: "provider.\(p.id).model") ?? ""
        return v.isEmpty ? p.defaultModel : v
    }
    static func baseURL(_ p: Provider) -> String {
        let v = d.string(forKey: "provider.\(p.id).baseURL") ?? ""
        return v.isEmpty ? p.baseURL : v
    }
    static func account(_ p: Provider) -> String { d.string(forKey: "provider.\(p.id).account") ?? "" }
    static func executable(_ p: Provider) -> String {
        let v = d.string(forKey: "provider.\(p.id).executable") ?? ""
        return v.isEmpty ? p.executable : v
    }
    static var maxOutputTokens: Int {
        let v = d.integer(forKey: "provider.maxOutputTokens")
        return v > 0 ? v : 32000
    }
    static func apiKey(_ p: Provider) -> String { SecretStore.get("apikey-\(p.id)") ?? "" }
    static func setAPIKey(_ v: String, for p: Provider) { SecretStore.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: "apikey-\(p.id)") }

    /// What to type in Terminal to sign a CLI in.
    static func loginCommand(_ p: Provider) -> String {
        switch p.id {
        case "claude-code": "claude   (then /login)"
        case "opencode": "opencode auth login"
        case "grok-cli": "grok   (then sign in)"
        case "kimi": "kimi   (then /login)"
        case "cursor-agent": "cursor-agent login"
        case "codex": "codex login"
        case "gemini-cli": "gemini   (then sign in with Google)"
        default: p.executable
        }
    }

    /// Why the provider can't run yet, or nil when it can.
    static func problem(_ p: Provider) -> String? {
        switch p.kind {
        case .local: return nil
        case .cli: return CLIRunner.resolvedPath(executable(p)) == nil ? "\(executable(p)) is not installed or not on your shell PATH." : nil
        case .openAI, .anthropic:
            if p.needsKey && apiKey(p).isEmpty { return "Add an API key for \(p.name) in Settings › Cloud APIs." }
            if p.needsAccount && account(p).isEmpty { return "Add your Cloudflare account ID in Settings › Cloud APIs." }
            if model(p).isEmpty { return "Choose a model for \(p.name) in Settings › Cloud APIs." }
            return nil
        }
    }

    /// Short label for task bars and asset metadata, e.g. "Claude Code · sonnet".
    static func label(_ p: Provider) -> String {
        if p.kind == .local { return "3D Coder · " + (Settings.modelPath as NSString).lastPathComponent }
        let m = model(p)
        return m.isEmpty ? p.name : "\(p.name) · \(m)"
    }
}

// MARK: - Prompt shaping for general-purpose models

enum RemotePrompt {
    /// General models get firmer output rules than the fine-tuned coder, which already knows the format.
    static let rules = """

    Output rules:
    - Reply with the complete HTML file in a single ```html code block. No commentary before or after it.
    - Load Three.js and its addons (GLTFExporter, OrbitControls) from a CDN with an import map, e.g. https://cdn.jsdelivr.net/npm/three@0.170.0/.
    - Build the model from three.js geometries and materials in code; no external textures or model files.
    - If a reference picture is attached, match its shape, proportions, colours and details as closely as you can.
    - Rest the asset on y = 0, centred on the origin, about 1 to 2 units tall, with soft lights and a dark ground plane.
    - The Export GLB button must call GLTFExporter with { binary: true } on the asset group only (not the ground or lights) and download asset.glb.
    - Do not use tools, read or write files, or run commands.
    """

    /// Modelling craft for general models, distilled for three.js from Scenario's MIT-licensed Blender hard-surface and
    /// game-asset skills (github.com/scenario-labs/skills). Not sent to the local 3D Coder: long prompts hurt that model.
    static let craft = """

    Modelling craft:
    - Silhouette first: get the big masses and proportions right before adding detail, and make the object read \
    clearly from the front, side and three-quarter views.
    - Edges catch light: bevel hard edges (RoundedBoxGeometry, ExtrudeGeometry with bevelEnabled, chamfered \
    LatheGeometry profiles). Leave an edge razor-sharp only when the object really is.
    - Curves look smooth, flat faces stay flat: flatShading false on curved parts, enough segments that round \
    silhouettes never look faceted (32+ radial segments on visible cylinders and spheres), and computeVertexNormals() \
    on hand-built geometry.
    - Parts connect: every part touches or slightly overlaps what it attaches to, with no floating gaps, and decals or \
    panels sit 0.001 to 0.002 units proud of the surface below them so nothing flickers.
    - Three levels of form: large shapes, then medium (trims, straps, panels), then small (rivets, seams, grooves) \
    only where they read at a normal camera distance.
    - Materials read as materials: distinct roughness and metalness per material, a harmonised palette of 3 to 6 \
    colours, no pure black or pure white, and emissive only for things that really glow.
    - Real-world proportions, front facing +Z, every mesh named after its part (e.g. "Blade", "Handle"), related \
    parts grouped, geometries and materials reused, and under about 150,000 triangles unless asked for more.
    """

    static var printRules: String {
        rules.replacingOccurrences(of: "\n    - Rest the asset on y = 0, centred on the origin, about 1 to 2 units tall, with soft lights and a dark ground plane.", with: "")
            .replacingOccurrences(of: "- Rest the asset on y = 0, centred on the origin, about 1 to 2 units tall, with soft lights and a dark ground plane.\n", with: "")
            + "\n- Keep 1 unit = 1 mm. Fuse touching parts by overlapping them by at least 1 mm; give it a flat bottom on y = 0.\n"
    }

    static var sceneRules: String {
        rules.replacingOccurrences(of: "- Rest the asset on y = 0, centred on the origin, about 1 to 2 units tall, with soft lights and a dark ground plane.\n", with: "")
            + "\n- Keep 1 unit = 1 metre. Put every object in its own named THREE.Group inside one group named \"Scene\"; export that group.\n"
    }

    static func system(for purpose: AssetPurpose) -> String {
        if purpose == .print { return printSystemPrompt + printRules }
        if purpose == .scene {
            let base = DetailLevel.current == .lowPoly ? sceneSystemPrompt : sceneSystemPrompt + " Make it richly detailed."
            return base + sceneRules + craft
        }
        let base = DetailLevel.current == .lowPoly ? systemPrompt
            : systemPrompt.replacingOccurrences(of: "good-quality low-poly asset", with: "high-quality, finely detailed asset")
        return base + rules + craft
    }

    static var system: String { system(for: AssetPurpose.current) }

    /// The purpose a conversation was started with, read from its system message.
    static func purpose(of messages: [[String: String]]) -> AssetPurpose {
        switch messages.first(where: { $0["role"] == "system" })?["content"] {
        case printSystemPrompt?: .print
        case sceneSystemPrompt?: .scene
        default: .game
        }
    }

    /// Flattens a chat into one prompt for CLIs that take a single message.
    static func flatten(_ messages: [[String: String]]) -> String {
        var out = system(for: purpose(of: messages)) + "\n\n"
        let turns = messages.filter { $0["role"] != "system" }
        if turns.count == 1 { return out + "Request: " + (turns[0]["content"] ?? "") }
        for m in turns {
            switch m["role"] {
            case "assistant": out += "Your previous file:\n" + (m["content"] ?? "") + "\n\n"
            default: out += "Request: " + (m["content"] ?? "") + "\n\n"
            }
        }
        return out
    }
}

// MARK: - HTTP streaming (OpenAI-compatible and Claude API)

enum RemoteEngine {
    typealias Piece = NativeEngine.Piece

    static func stream(_ p: Provider, messages: [[String: String]], thinking: Bool, image: ReferenceImage? = nil,
                       systemOverride: String? = nil) -> AsyncThrowingStream<Piece, Error> {
        AsyncThrowingStream { cont in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let req = try request(p, messages: messages, thinking: thinking, image: image, systemOverride: systemOverride)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
                        throw ForgeError("\(p.name) returned \(http.statusCode): \(errorMessage(body))")
                    }
                    var buf = "", bufReasoning = "", n = 0, nr = 0, last = Date()
                    func send() {
                        if !bufReasoning.isEmpty { cont.yield(.reasoning(bufReasoning, tokens: nr)); bufReasoning = ""; nr = 0 }
                        if !buf.isEmpty { cont.yield(.content(buf, tokens: n)); buf = ""; n = 0 }
                        last = Date()
                    }
                    var event = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if p.kind == .anthropic {
                            let type = obj["type"] as? String ?? event
                            if type == "error" { throw ForgeError("\(p.name): \(errorMessage(payload))") }
                            if type == "message_delta", let d = obj["delta"] as? [String: Any], d["stop_reason"] as? String == "refusal" {
                                throw ForgeError("\(p.name) declined this request.")
                            }
                            guard type == "content_block_delta", let d = obj["delta"] as? [String: Any] else { continue }
                            if let t = d["text"] as? String { buf += t; n += approxTokens(t) }
                            if let t = d["thinking"] as? String { bufReasoning += t; nr += approxTokens(t) }
                        } else {
                            if let e = obj["error"] { throw ForgeError("\(p.name): \(errorMessage(String(describing: e)))") }
                            guard let delta = ((obj["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else { continue }
                            if let r = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !r.isEmpty { bufReasoning += r; nr += approxTokens(r) }
                            if let c = delta["content"] as? String, !c.isEmpty { buf += c; n += approxTokens(c) }
                        }
                        if Date().timeIntervalSince(last) > 0.1 { send() }
                    }
                    send()
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func request(_ p: Provider, messages: [[String: String]], thinking: Bool, image: ReferenceImage? = nil,
                        systemOverride: String? = nil) throws -> URLRequest {
        var base = ProviderSettings.baseURL(p).replacingOccurrences(of: "{account}", with: ProviderSettings.account(p))
        while base.hasSuffix("/") { base.removeLast() }
        let key = ProviderSettings.apiKey(p), model = ProviderSettings.model(p)
        let maxTokens = ProviderSettings.maxOutputTokens
        let system = systemOverride ?? RemotePrompt.system(for: RemotePrompt.purpose(of: messages))
        var msgs = messages
        if let i = msgs.firstIndex(where: { $0["role"] == "system" }) { msgs[i]["content"] = system }
        let lastUser = msgs.lastIndex { $0["role"] == "user" }

        var req: URLRequest
        var body: [String: Any]
        if p.kind == .anthropic {
            guard let url = URL(string: base + "/messages") else { throw ForgeError("Invalid base URL for \(p.name).") }
            req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model, "max_tokens": maxTokens, "stream": true,
                "system": system,
                "messages": msgs.indices.filter { msgs[$0]["role"] != "system" }.map { i -> [String: Any] in
                    let text = msgs[i]["content"] ?? ""
                    guard i == lastUser, let image else { return ["role": msgs[i]["role"] ?? "user", "content": text] }
                    return ["role": "user", "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64]],
                        ["type": "text", "text": text],
                    ]]
                },
                "thinking": ["type": "adaptive", "display": "summarized"],
                "output_config": ["effort": thinking ? "high" : "low"],
            ]
            // Server-side refusal fallback on the models that accept it.
            if ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model) {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        } else {
            guard let url = URL(string: base + "/chat/completions") else { throw ForgeError("Invalid base URL for \(p.name).") }
            req = URLRequest(url: url)
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            if p.id == "openrouter" {
                req.setValue("https://github.com/assetforge", forHTTPHeaderField: "HTTP-Referer")
                req.setValue("Sirpi", forHTTPHeaderField: "X-Title")
            }
            let wire: [[String: Any]] = msgs.indices.map { i in
                let text = msgs[i]["content"] ?? ""
                guard i == lastUser, let image else { return ["role": msgs[i]["role"] ?? "user", "content": text] }
                return ["role": "user", "content": [
                    ["type": "text", "text": text],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64)"]],
                ]]
            }
            body = ["model": model, "messages": wire, "stream": true, p.tokenParam: maxTokens]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 1800
        return req
    }

    /// Lists model IDs from GET /models (OpenAI-compatible and Claude API).
    static func listModels(_ p: Provider) async throws -> [String] {
        var base = ProviderSettings.baseURL(p).replacingOccurrences(of: "{account}", with: ProviderSettings.account(p))
        while base.hasSuffix("/") { base.removeLast() }
        // Cloudflare's OpenAI-compatible root has no /models; its catalogue lives under /ai/models/search.
        let path = p.id == "cloudflare" ? base.replacingOccurrences(of: "/ai/v1", with: "/ai/models/search?task=Text%20Generation&per_page=200") : base + "/models"
        guard let url = URL(string: path) else { throw ForgeError("Invalid base URL.") }
        var req = URLRequest(url: url)
        let key = ProviderSettings.apiKey(p)
        if p.kind == .anthropic {
            req.setValue(key, forHTTPHeaderField: "x-api-key"); req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw ForgeError("\(http.statusCode): \(errorMessage(String(decoding: data, as: UTF8.self)))")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (obj?["data"] as? [[String: Any]]) ?? (obj?["result"] as? [[String: Any]]) ?? (obj?["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] ?? $0["name"]) as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .sorted()
    }

    static func errorMessage(_ body: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = obj["message"] as? String { return m }
            if let errs = obj["errors"] as? [[String: Any]], let m = errs.first?["message"] as? String { return m }
        }
        return String(body.prefix(300))
    }
}

// MARK: - CLI agents

enum CLIRunner {
    typealias Piece = NativeEngine.Piece

    /// The login shell's environment (PATH etc.). GUI apps start with a bare PATH, so node-based CLIs
    /// such as opencode, pi and gemini would not be found without it. Read once, off the main thread.
    nonisolated(unsafe) private static var cachedEnv: [String: String]?
    private static let lock = NSLock()

    static var shellEnvironment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let e = cachedEnv { return e }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "env -0"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            for entry in data.split(separator: 0) {
                let s = String(decoding: entry, as: UTF8.self)
                if let eq = s.firstIndex(of: "=") { env[String(s[..<eq])] = String(s[s.index(after: eq)...]) }
            }
        }
        cachedEnv = env
        return env
    }

    /// Loads the shell environment in the background so the first CLI lookup never blocks the UI.
    static func warmUp() { Task.detached(priority: .utility) { _ = shellEnvironment } }

    private static var envIfReady: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return cachedEnv ?? ProcessInfo.processInfo.environment
    }

    static func resolvedPath(_ exe: String) -> String? {
        if exe.contains("/") { return FileManager.default.isExecutableFile(atPath: exe) ? exe : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "\(home)/.opencode/bin", "\(home)/.grok/bin", "\(home)/.kimi-code/bin", "\(home)/.bun/bin",
                     "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let dirs = (envIfReady["PATH"] ?? "").split(separator: ":").map(String.init) + extra
        return dirs.map { "\($0)/\(exe)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Arguments plus what goes to stdin (nil: nothing).
    static func command(_ p: Provider, messages: [[String: String]], workDir: URL, image: ReferenceImage? = nil,
                        systemOverride: String? = nil, modelOverride: String? = nil) -> ([String], String?) {
        let model = modelOverride ?? ProviderSettings.model(p)
        let system = systemOverride ?? RemotePrompt.system(for: RemotePrompt.purpose(of: messages))
        var user = systemOverride == nil ? RemotePrompt.flatten(messages)
            : system + "\n\n" + messages.filter { $0["role"] != "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
        // The picture goes in the working folder; CLIs that read files get pointed at it.
        let imagePath = workDir.appendingPathComponent("reference.jpg")
        if let image { try? image.jpeg.write(to: imagePath) }
        if image != nil && p.id == "gemini-cli" { user += "\n\nReference picture: @reference.jpg" }
        switch p.id {
        case "claude-code":
            var a = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                     "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#,
                     "--exclude-dynamic-system-prompt-sections",
                     "--system-prompt", system]
            if !model.isEmpty { a += ["--model", model] }
            let turns = messages.filter { $0["role"] != "system" }
            let body = turns.count == 1 ? (turns[0]["content"] ?? "") : RemotePrompt.flatten(messages)
            guard let image else { return (a, body) }
            // Images travel as a stream-json user message with an image block.
            a += ["--input-format", "stream-json"]
            let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64]],
                ["type": "text", "text": body],
            ]]]
            let line = (try? JSONSerialization.data(withJSONObject: msg)).map { String(decoding: $0, as: UTF8.self) } ?? body
            return (a, line + "\n")
        case "grok-cli":
            let file = workDir.appendingPathComponent("prompt.txt")
            try? user.write(to: file, atomically: true, encoding: .utf8)
            var a = ["--prompt-file", file.path, "--output-format", "streaming-json", "--disable-web-search", "--no-plan"]
            if !model.isEmpty { a += ["-m", model] }
            return (a, nil)
        case "opencode":
            var a = ["run", "--format", "json"]
            if !model.isEmpty { a += ["-m", model] }
            if image != nil { a += ["-f", imagePath.path] }
            return (a + [user], nil)
        case "kimi":
            // A one-off agent with no tools and Sirpi's own system prompt. Without it Kimi sends every MCP tool the
            // user has installed (hundreds) and its 38k-character coding-agent prompt with each request, which can
            // take minutes before the first word.
            let agent = workDir.appendingPathComponent("sirpi-agent.md")
            let header = "---\nname: sirpi-writer\ndescription: Writes one complete answer for Sirpi without tools\ntools: []\nsubagents: []\n---\n\n"
            try? (header + system).write(to: agent, atomically: true, encoding: .utf8)
            let turns = messages.filter { $0["role"] != "system" }
            let body = turns.count == 1 ? (turns[0]["content"] ?? "") : turns.map { m in
                m["role"] == "assistant" ? "Your previous file:\n" + (m["content"] ?? "") : "Request: " + (m["content"] ?? "")
            }.joined(separator: "\n\n")
            var a = ["-p", body, "--output-format", "stream-json", "--agent-file", agent.path]
            if !model.isEmpty { a += ["-m", model] }
            return (a, nil)
        case "pi":
            var a = ["-p"]
            if !model.isEmpty { a += ["--model", model] }
            return (a + [user], nil)
        case "gemini-cli":
            var a = ["-p", user]
            if !model.isEmpty { a += ["-m", model] }
            return (a, nil)
        case "codex":
            var a = ["exec", "--skip-git-repo-check", "--sandbox", "read-only"]
            if !model.isEmpty { a += ["-m", model] }
            if image != nil { a += ["-i", imagePath.path] }
            return (a + ["-"], user)
        case "cursor-agent":
            var a = ["-p", "--output-format", "text"]
            if !model.isEmpty { a += ["--model", model] }
            return (a + [user], nil)
        default:
            return (["-p", user], nil)
        }
    }

    static func stream(_ p: Provider, messages: [[String: String]], image: ReferenceImage? = nil,
                       systemOverride: String? = nil, modelOverride: String? = nil) -> AsyncThrowingStream<Piece, Error> {
        if p.id == "kimi" {
            return KimiACP.stream(p, messages: messages, image: image, systemOverride: systemOverride, modelOverride: modelOverride)
        }
        return AsyncThrowingStream { cont in
            let proc = Process()
            let task = Task.detached(priority: .userInitiated) {
                let exe = ProviderSettings.executable(p)
                guard let path = resolvedPath(exe) else {
                    cont.finish(throwing: ForgeError("\(exe) was not found. Install it, or set its full path in Settings › Coding Agents.")); return
                }
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("assetforge-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let (args, stdin) = command(p, messages: messages, workDir: work, image: image,
                                            systemOverride: systemOverride, modelOverride: modelOverride)
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                proc.currentDirectoryURL = work
                var env = shellEnvironment
                env["NO_COLOR"] = "1"; env["TERM"] = "dumb"; env["CI"] = "1"
                proc.environment = env
                let out = Pipe(), err = Pipe(), inp = Pipe()
                proc.standardOutput = out; proc.standardError = err; proc.standardInput = inp
                var errText = ""
                err.fileHandleForReading.readabilityHandler = { h in
                    let s = String(decoding: h.availableData, as: UTF8.self)
                    if !s.isEmpty { errText = String((errText + s).suffix(4000)) }
                }
                do { try proc.run() } catch { cont.finish(throwing: error); return }
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()

                var parser = CLIParser(format: p.cliFormat)
                var pending = Data()
                var failure: String?
                let handle = out.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if Task.isCancelled { break }
                    if p.cliFormat == .plain {
                        let s = String(decoding: chunk, as: UTF8.self)
                        cont.yield(.content(s, tokens: approxTokens(s)))
                        continue
                    }
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        for piece in parser.parse(line: Data(line)) {
                            if case .failed(let m) = piece { failure = m } else if let pc = piece.piece { cont.yield(pc) }
                        }
                    }
                }
                if !pending.isEmpty { for piece in parser.parse(line: pending) { if let pc = piece.piece { cont.yield(pc) } } }
                proc.waitUntilExit()
                err.fileHandleForReading.readabilityHandler = nil
                if Task.isCancelled { cont.finish(); return }
                if let failure { cont.finish(throwing: ForgeError("\(p.name): \(failure)")); return }
                if proc.terminationStatus != 0 && !parser.sawContent {
                    let tail = errText.split(separator: "\n").suffix(4).joined(separator: " ")
                    cont.finish(throwing: ForgeError("\(p.name) exited with code \(proc.terminationStatus). \(tail)")); return
                }
                cont.finish()
            }
            cont.onTermination = { _ in
                task.cancel()
                if proc.isRunning { proc.terminate() }
            }
        }
    }
}

/// Turns one JSON line from a CLI into stream pieces.
struct CLIParser {
    enum Out { case piece(NativeEngine.Piece), failed(String)
        var piece: NativeEngine.Piece? { if case .piece(let p) = self { return p }; return nil }
    }
    let format: CLIFormat
    var sawContent = false
    private var sawDeltas = false

    init(format: CLIFormat) { self.format = format }

    mutating func parse(line: Data) -> [Out] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        let type = (obj["type"] as? String) ?? ""
        if type.isEmpty && format != .kimi { return [] }
        switch format {
        case .claude:
            if type == "stream_event", let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
               let d = ev["delta"] as? [String: Any] {
                sawDeltas = true
                if let t = d["text"] as? String { sawContent = true; return [.piece(.content(t, tokens: approxTokens(t)))] }
                if let t = d["thinking"] as? String { return [.piece(.reasoning(t, tokens: approxTokens(t)))] }
            }
            // Without partial messages, fall back to whole assistant messages.
            if type == "assistant", !sawDeltas, let m = obj["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { sawContent = true; return [.piece(.content(text, tokens: approxTokens(text)))] }
            }
            if type == "result", obj["is_error"] as? Bool == true {
                return [.failed((obj["result"] as? String) ?? (obj["subtype"] as? String) ?? "failed")]
            }
        case .grok:
            if type == "text", let t = obj["data"] as? String { sawContent = true; return [.piece(.content(t, tokens: approxTokens(t)))] }
            if type == "thought", let t = obj["data"] as? String { return [.piece(.reasoning(t, tokens: approxTokens(t)))] }
            if type == "error" { return [.failed((obj["message"] ?? obj["data"]).map { "\($0)" } ?? "failed")] }
        case .opencode:
            if let part = obj["part"] as? [String: Any], let t = part["text"] as? String, !t.isEmpty {
                if type == "text" { sawContent = true; return [.piece(.content(t, tokens: approxTokens(t)))] }
                if type == "reasoning" { return [.piece(.reasoning(t, tokens: approxTokens(t)))] }
            }
            if type == "error", let e = obj["error"] as? [String: Any] { return [.failed(e["message"] as? String ?? "failed")] }
        case .kimi:
            // {"role":"assistant","content":"..."} whole messages; meta lines carry role "meta".
            guard (obj["role"] as? String) == "assistant" else {
                if (obj["role"] as? String) == "error" || type.contains("error") {
                    return [.failed((obj["content"] as? String) ?? (obj["message"] as? String) ?? "failed")]
                }
                return []
            }
            var out: [Out] = []
            if let r = (obj["reasoning_content"] ?? obj["thinking"]) as? String, !r.isEmpty { out.append(.piece(.reasoning(r, tokens: approxTokens(r)))) }
            if let c = obj["content"] as? String, !c.isEmpty { sawContent = true; out.append(.piece(.content(c, tokens: approxTokens(c)))) }
            return out
        case .plain:
            break
        }
        return []
    }
}
