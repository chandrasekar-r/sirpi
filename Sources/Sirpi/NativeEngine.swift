import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// In-process inference with MLX: no server, no HTTP. The model folder is an MLX conversion
/// (config.json + model.safetensors) of the GLB coder, produced by tools/gguf_to_hf.py + mlx_lm.convert.
///
/// Measured on an M4 Pro, 2 500-token generation:
///   MLX 4-bit  82.7 tok/s · 2.65 GB peak      llama.cpp Q8_0  43 tok/s · ~5.6 GB
///   MLX 6-bit  60.6 tok/s · 3.70 GB peak      llama.cpp Q4_K_M 58 tok/s
@MainActor
final class NativeEngine {
    enum Piece: Sendable {
        case reasoning(String, tokens: Int), content(String, tokens: Int)
        case stats(tokens: Int, perSecond: Double)
    }

    private(set) var container: ModelContainer?
    private(set) var loadedPath: String?

    /// A folder (not a .gguf file) holding config.json selects the MLX engine.
    nonisolated static func isMLXModel(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
            && FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("config.json"))
    }

    func load(path: String) async throws {
        if loadedPath == path, container != nil { return }
        unload()
        // Keep freed GPU buffers for reuse between tokens, but bounded so idle memory stays low.
        Memory.cacheLimit = 512 * 1024 * 1024
        let c = try await loadModelContainer(from: URL(fileURLWithPath: path), using: TransformersTokenizerLoader())
        container = c
        loadedPath = path
        // Warm up: compiles the Metal kernels so the first real generation starts immediately.
        let input = LMInput(tokens: MLXArray(await c.encode("<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n")))
        let warm = try await c.generate(input: input, parameters: GenerateParameters(maxTokens: 2, temperature: 0))
        for await _ in warm {}
    }

    func unload() {
        container = nil
        loadedPath = nil
        Memory.clearCache()
    }

    /// ChatML prompt exactly as the model's chat template renders it (Qwen3.5).
    static func prompt(messages: [[String: String]], thinking: Bool) -> String {
        var s = ""
        for m in messages {
            s += "<|im_start|>\(m["role"] ?? "user")\n\(m["content"] ?? "")<|im_end|>\n"
        }
        s += "<|im_start|>assistant\n"
        s += thinking ? "<think>\n" : "<think>\n\n</think>\n\n"
        return s
    }

    /// Streams reasoning and content in ~10 Hz batches. Cancelling the consuming task stops generation.
    /// The token loop runs off the main actor, so UI rendering never stalls the GPU pipeline.
    func stream(messages: [[String: String]], thinking: Bool, temperature: Double, maxTokens: Int)
        -> AsyncThrowingStream<Piece, Error>
    {
        let container = self.container
        let prompt = Self.prompt(messages: messages, thinking: thinking)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                guard let c = container else {
                    continuation.finish(throwing: ForgeError("The model is not loaded.")); return
                }
                // Keep the Mac from napping, coalescing timers or sleeping while it generates.
                let activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                    reason: "Generating a 3D asset")
                defer { ProcessInfo.processInfo.endActivity(activity) }
                do {
                    let tokens = await c.encode(prompt)
                    let params = GenerateParameters(
                        maxTokens: maxTokens, temperature: Float(temperature), topP: 0.95, topK: 40, minP: 0.0)
                    let events = try await c.generate(input: LMInput(tokens: MLXArray(tokens)), parameters: params)
                    var inThink = thinking
                    var pending = ""            // undecided text (may hold a partial </think>)
                    var out = "", outTokens = 0 // batch for the current section
                    var lastYield = Date()
                    func send() {
                        guard !out.isEmpty || outTokens > 0 else { return }
                        continuation.yield(inThink ? .reasoning(out, tokens: outTokens) : .content(out, tokens: outTokens))
                        out = ""; outTokens = 0; lastYield = Date()
                    }
                    for await event in events {
                        if Task.isCancelled { break }
                        if let info = event.info {
                            continuation.yield(.stats(tokens: info.generationTokenCount, perSecond: info.tokensPerSecond))
                            continue
                        }
                        guard let text = event.chunk else { continue }
                        pending += text; outTokens += 1
                        if inThink, let r = pending.range(of: "</think>") {
                            out += pending[..<r.lowerBound]
                            send()
                            pending = String(pending[r.upperBound...].drop { $0 == "\n" })
                            inThink = false
                        }
                        let hold = inThink ? 8 : 0
                        if pending.count > hold {
                            out += pending.dropLast(hold)
                            pending = String(pending.suffix(hold))
                        }
                        if Date().timeIntervalSince(lastYield) > 0.1 { send() }
                    }
                    out += pending
                    send()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - swift-transformers tokenizer adapter

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
