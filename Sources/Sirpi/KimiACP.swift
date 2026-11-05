import Foundation

/// Runs Kimi Code through its Agent Client Protocol server (`kimi acp`), which streams the answer word by word.
/// `kimi -p` only prints each message once it is complete, so a long asset showed "Waiting for Kimi Code" for
/// minutes with no code and no live preview.
///
/// The working folder gets a project agent named `agent` with `override: true`. It replaces Kimi's default
/// coding agent for this session only: no tools, no MCP servers and Sirpi's own system prompt, which keeps the
/// first word to a few seconds instead of loading hundreds of tools and a 40k-character prompt.
enum KimiACP {
    typealias Piece = NativeEngine.Piece

    static func stream(_ p: Provider, messages: [[String: String]], image: ReferenceImage? = nil,
                       systemOverride: String? = nil, modelOverride: String? = nil) -> AsyncThrowingStream<Piece, Error> {
        AsyncThrowingStream { cont in
            let proc = Process()
            let task = Task.detached(priority: .userInitiated) {
                let exe = ProviderSettings.executable(p)
                guard let path = CLIRunner.resolvedPath(exe) else {
                    cont.finish(throwing: ForgeError("\(exe) was not found. Install it, or set its full path in Settings › Coding Agents.")); return
                }
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("assetforge-\(UUID().uuidString)", isDirectory: true)
                let agents = work.appendingPathComponent(".kimi-code/agents", isDirectory: true)
                try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }

                let system = systemOverride ?? RemotePrompt.system(for: RemotePrompt.purpose(of: messages))
                let header = "---\nname: agent\noverride: true\ndescription: Writes one complete answer for Sirpi without tools\ntools: []\nsubagents: []\n---\n\n"
                try? (header + system).write(to: agents.appendingPathComponent("agent.md"), atomically: true, encoding: .utf8)
                let turns = messages.filter { $0["role"] != "system" }
                let body = turns.count == 1 ? (turns[0]["content"] ?? "") : turns.map { m in
                    m["role"] == "assistant" ? "Your previous file:\n" + (m["content"] ?? "") : "Request: " + (m["content"] ?? "")
                }.joined(separator: "\n\n")
                var model = modelOverride ?? ProviderSettings.model(p)
                if !model.isEmpty && !model.contains("/") { model = "kimi-code/" + model }

                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = ["acp"]
                proc.currentDirectoryURL = work
                var env = CLIRunner.shellEnvironment
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
                let writer = inp.fileHandleForWriting
                func send(_ obj: [String: Any]) {
                    guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
                    d.append(0x0A)
                    try? writer.write(contentsOf: d)
                }
                func request(_ id: Int, _ method: String, _ params: [String: Any]) {
                    send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                }
                func stop() {
                    err.fileHandleForReading.readabilityHandler = nil
                    if proc.isRunning { proc.terminate() }
                }

                // 1 initialize → 2 session/new → (3 model) → 4 session/prompt
                request(1, "initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any]()])
                var sessionID = ""
                var sawContent = false
                var finished = false
                var pending = Data()
                let handle = out.fileHandleForReading

                func prompt() {
                    var blocks: [[String: Any]] = []
                    if let image { blocks.append(["type": "image", "mimeType": "image/jpeg", "data": image.base64]) }
                    blocks.append(["type": "text", "text": body])
                    request(4, "session/prompt", ["sessionId": sessionID, "prompt": blocks])
                }

                func handleLine(_ obj: [String: Any]) -> Error? {
                    // A request from the agent (permissions, files): this session has no tools, so refuse anything.
                    if let method = obj["method"] as? String, let id = obj["id"] {
                        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by Sirpi: \(method)"]])
                        return nil
                    }
                    if obj["method"] as? String == "session/update",
                       let params = obj["params"] as? [String: Any], let u = params["update"] as? [String: Any] {
                        let kind = u["sessionUpdate"] as? String ?? ""
                        let text = (u["content"] as? [String: Any])?["text"] as? String ?? ""
                        guard !text.isEmpty else { return nil }
                        if kind == "agent_message_chunk" { sawContent = true; cont.yield(.content(text, tokens: approxTokens(text))) }
                        else if kind == "agent_thought_chunk" { cont.yield(.reasoning(text, tokens: approxTokens(text))) }
                        return nil
                    }
                    guard let id = obj["id"] as? Int else { return nil }
                    if let e = obj["error"] as? [String: Any] {
                        var msg = e["message"] as? String ?? "failed"
                        if let data = e["data"] { msg += " (\(data))" }
                        if id == 1 || id == 2, msg.lowercased().contains("auth") {
                            msg = "Kimi Code is not logged in. Run `kimi` in Terminal and use /login."
                        } else if id == 3 {
                            msg = "Kimi does not know the model \"\(model)\". \(msg)"
                        }
                        return ForgeError("\(p.name): \(msg)")
                    }
                    let result = obj["result"] as? [String: Any] ?? [:]
                    switch id {
                    case 1:
                        request(2, "session/new", ["cwd": work.path, "mcpServers": [Any]()])
                    case 2:
                        sessionID = result["sessionId"] as? String ?? ""
                        if model.isEmpty { prompt() }
                        else { request(3, "session/set_config_option", ["sessionId": sessionID, "configId": "model", "value": model]) }
                    case 3:
                        prompt()
                    case 4:
                        finished = true
                        let reason = result["stopReason"] as? String ?? "end_turn"
                        if reason == "refusal" { return ForgeError("\(p.name) declined this request.") }
                        if reason == "max_tokens" && !sawContent { return ForgeError("\(p.name) ran out of tokens before writing anything.") }
                    default: break
                    }
                    return nil
                }

                var failure: Error?
                outer: while !finished {
                    let chunk = handle.availableData
                    if chunk.isEmpty || Task.isCancelled { break }
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                        if let e = handleLine(obj) { failure = e; break outer }
                        if finished { break outer }
                    }
                }
                stop()
                if Task.isCancelled { cont.finish(); return }
                if let failure { cont.finish(throwing: failure); return }
                if !finished && !sawContent {
                    let tail = errText.split(separator: "\n").suffix(4).joined(separator: " ")
                    cont.finish(throwing: ForgeError("\(p.name) stopped before answering. \(tail)")); return
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
