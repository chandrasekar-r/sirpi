import Foundation
import Observation

/// Follow-up questions asked before a generation, so the model gets the details a designer would ask for.
struct BriefQuestion: Identifiable, Codable, Hashable {
    var id: String
    var question: String
    var options: [String]
    var multi: Bool = false
}

@Observable @MainActor
final class Brief {
    var prompt: String
    var purpose: AssetPurpose
    var questions: [BriefQuestion] = []
    var answers: [String: Set<String>] = [:]
    var notes: [String: String] = [:]
    var loading = true
    var source = ""          // which model wrote the questions, or "built-in"

    init(prompt: String, purpose: AssetPurpose) {
        self.prompt = prompt
        self.purpose = purpose
    }

    static let enabledKey = "askFollowUps"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// The answers as a short spec appended to the user's request.
    var spec: String {
        let lines = questions.compactMap { q -> String? in
            var parts = Array(answers[q.id] ?? []).sorted()
            if let n = notes[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { parts.append(n) }
            return parts.isEmpty ? nil : "- \(q.question) \(parts.joined(separator: ", "))"
        }
        return lines.isEmpty ? "" : "Details from the user:\n" + lines.joined(separator: "\n")
    }

    // MARK: question writing

    private static let instruction = """
    You help a user brief a 3D modeller. Read the request and write 3 to 5 short follow-up questions that would change \
    how the model is built, skipping anything the request already answers. Each question gets 3 to 5 short answer \
    options (2-4 words each). Reply with JSON only, no prose:
    {"questions":[{"id":"style","question":"Which style?","options":["Low-poly","Cartoon","Realistic"],"multi":false}]}
    """

    func load(context: String) async {
        loading = true
        defer { loading = false }
        let kind: String
        switch purpose {
        case .print: kind = "This will be 3D printed (FDM). \(context)"
        case .scene: kind = "This is a whole 3D environment scene (a place with many objects) that the user will customise later."
        case .game: kind = "This is a game asset for Godot."
        }
        let ask = "\(kind)\n\nRequest: \(prompt)"
        if let (qs, who) = try? await Self.askModel(ask), !qs.isEmpty {
            questions = qs
            source = who
        } else {
            questions = Self.builtIn(purpose)
            source = "built-in"
        }
    }

    /// The fastest signed-in model writes the questions: Claude Code (Haiku), then any cloud API with a key.
    private static func askModel(_ text: String) async throws -> ([BriefQuestion], String) {
        let order = ["claude-code", "anthropic", "openai", "gemini", "xai", "openrouter", "groq"]
        guard let p = order.map(Providers.find).first(where: { p in
            p.kind == .cli ? CLIRunner.resolvedPath(ProviderSettings.executable(p)) != nil : ProviderSettings.problem(p) == nil
        }) else { return ([], "") }
        let messages = [["role": "user", "content": text]]
        let stream = p.kind == .cli
            ? CLIRunner.stream(p, messages: messages, systemOverride: instruction, modelOverride: "haiku")
            : RemoteEngine.stream(p, messages: messages, thinking: false, systemOverride: instruction)
        let collected = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var out = ""
                for try await piece in stream { if case .content(let t, _) = piece { out += t } }
                return out
            }
            group.addTask { try await Task.sleep(for: .seconds(30)); throw ForgeError("timeout") }
            let first = try await group.next() ?? ""
            group.cancelAll()
            return first
        }
        guard let start = collected.firstIndex(of: "{"), let end = collected.lastIndex(of: "}"),
              let data = String(collected[start...end]).data(using: .utf8) else { return ([], "") }
        struct Wrapper: Decodable { var questions: [BriefQuestion] }
        let qs = try JSONDecoder().decode(Wrapper.self, from: data).questions
            .filter { !$0.question.isEmpty && !$0.options.isEmpty }
            .prefix(5)
        return (Array(qs), p.kind == .cli ? "\(p.name) · haiku" : p.name)
    }

    static func builtIn(_ purpose: AssetPurpose) -> [BriefQuestion] {
        switch purpose {
        case .game:
            return [
                .init(id: "style", question: "Which visual style?", options: ["Low-poly stylised", "Cartoon", "Realistic", "Voxel"]),
                .init(id: "colours", question: "What colour palette?", options: ["Earthy, muted", "Bright, saturated", "Dark fantasy", "Match the prompt"]),
                .init(id: "scale", question: "How big is it in the game?", options: ["Hand-held", "Human-sized", "Vehicle-sized", "Building-sized"]),
                .init(id: "animation", question: "Does it need animation?", options: ["No, static", "Idle loop", "Opens / closes", "Spins"]),
            ]
        case .scene:
            return [
                .init(id: "place", question: "What kind of place?", options: ["City street", "House interior", "Village square", "Park or garden", "Sci-fi base"]),
                .init(id: "time", question: "Time of day and mood?", options: ["Bright day", "Golden hour", "Night, lit by lamps", "Rainy and grey"]),
                .init(id: "size", question: "How big?", options: ["One room", "One street block", "A small neighbourhood"]),
                .init(id: "density", question: "How busy?", options: ["Sparse", "Lived-in", "Packed with props"]),
                .init(id: "style", question: "Which style?", options: ["Low-poly stylised", "Realistic", "Cartoon"]),
            ]
        case .print:
            return [
                .init(id: "size", question: "How big should it be?", options: ["About 50 mm", "About 100 mm", "About 150 mm", "As large as fits"]),
                .init(id: "use", question: "What is it for?", options: ["Decorative", "Functional, light use", "Functional, load-bearing"]),
                .init(id: "material", question: "Which filament?", options: ["PLA", "PETG", "TPU (flexible)"]),
                .init(id: "colour", question: "Colours?", options: ["Single colour", "Multi-colour (AMS)"]),
                .init(id: "supports", question: "Supports?", options: ["Design to print without supports", "Supports are fine"]),
            ]
        }
    }
}
