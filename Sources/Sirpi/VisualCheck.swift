import Foundation
import AppKit

// MARK: - Compare a generated asset with its reference picture

/// After a picture-guided generation, renders the asset from four sides next to the reference picture, asks a vision
/// model what differs, and turns its answer into one automatic refinement.
enum VisualCheck {
    static let enabledKey = "autoRefineFromPicture"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// A score at or above this skips the refinement.
    static let goodEnough = 8

    struct Verdict {
        let score: Int
        let fixes: [String]
        let checker: String
        var needsRefinement: Bool { score < VisualCheck.goodEnough && !fixes.isEmpty }

        /// The refinement request sent to the model that wrote the asset.
        var refinement: String {
            "If an image is attached, its left half is the reference picture and its right half shows renders of your current model. "
                + "Compared with the reference picture, the model has these problems. Fix all of them, keep everything that already matches, "
                + "and keep it one asset:\n" + fixes.map { "- " + $0 }.joined(separator: "\n")
        }
    }

    static func instruction(prompt: String, purpose: AssetPurpose) -> String {
        """
        The image has two halves. LEFT: a reference picture of an object. RIGHT: four renders (front, right side, \
        three-quarter, back) of a 3D model that was built to match it. The request was: "\(prompt)". \
        The model is a \(purpose == .print ? "3D print, so it is one solid colour per part and must stay printable" : "game asset").

        Compare the 3D model with the reference: overall silhouette and proportions, which parts exist and where they \
        attach, the shape of each part, colours, materials, and notable details. Ignore the background, lighting, \
        camera angle and that the model is simpler than a photo. The view labels are camera positions, so the \
        model's own front may appear in a different panel; that is not a fault unless it clearly faces the wrong way.

        Reply with only a JSON object, no other text:
        {"score": <0-10, how well the model matches the reference; 8+ means only minor differences>,
         "fixes": [<up to 8 specific, actionable instructions for a programmer editing the three.js code, most \
        important first, each naming the part and the change, e.g. "Make the blade about twice as long as the handle" \
        or "Colour the roof dark red (#7a1f1f) instead of grey">]}
        """
    }

    /// Who looks at the comparison: the selected provider when it can see pictures, otherwise the describer.
    static var checker: (Provider, String?)? {
        let selected = ProviderSettings.selected
        if selected.seesImages { return (selected, nil) }
        guard let p = ImageDescriber.describer else { return nil }
        // Comparing shapes needs a stronger model than describing one.
        return (p, p.id == "claude-code" ? "sonnet" : nil)
    }

    static func critique(sheet: ReferenceImage, prompt: String, purpose: AssetPurpose) async throws -> Verdict {
        guard let (p, model) = checker else {
            throw ForgeError("No vision model is available to compare the asset with the picture.")
        }
        let messages = [["role": "user", "content": instruction(prompt: prompt, purpose: purpose)]]
        let system = "You are a meticulous 3D art director reviewing a model against its reference. You reply with JSON only."
        let stream = p.kind == .cli
            ? CLIRunner.stream(p, messages: messages, image: sheet, systemOverride: system, modelOverride: model)
            : RemoteEngine.stream(p, messages: messages, thinking: false, image: sheet, systemOverride: system)
        var text = ""
        for try await piece in stream { if case .content(let t, _) = piece { text += t } }
        return try parse(text, checker: ProviderSettings.label(p))
    }

    static func parse(_ text: String, checker: String) throws -> Verdict {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw ForgeError("The vision model's comparison could not be read.")
        }
        let score = (obj["score"] as? NSNumber)?.intValue ?? Int(obj["score"] as? String ?? "") ?? 0
        let fixes = (obj["fixes"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Verdict(score: max(0, min(10, score)), fixes: Array(fixes.prefix(8)), checker: checker)
    }
}
