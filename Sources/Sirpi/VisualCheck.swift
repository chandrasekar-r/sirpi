import Foundation
import AppKit

// MARK: - Compare a generated asset with its reference picture

/// After a picture-guided generation, renders the asset from four sides next to the reference picture, asks a vision
/// model what differs, and turns its answer into one automatic refinement.
enum VisualCheck {
    /// Key kept from 1.1.0, when only picture-based assets were reviewed.
    static let enabledKey = "autoRefineFromPicture"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// A score at or above this skips the refinement.
    static let goodEnough = 8

    struct Verdict {
        let score: Int
        let fixes: [String]
        let checker: String
        var hasReference = true
        var needsRefinement: Bool { score < VisualCheck.goodEnough && !fixes.isEmpty }

        /// The refinement request sent to the model that wrote the asset.
        var refinement: String {
            let source = hasReference ? "Compared with the reference picture" : "A review against the request"
            let image = hasReference
                ? "If an image is attached, its left half is the reference picture and its right half shows renders of your current model."
                : "If an image is attached, it shows renders of your current model from four sides."
            // Starts with a short label: it doubles as the version's title in the sidebar.
            return (hasReference ? "Picture match fixes:\n" : "Review fixes:\n") + fixes.map { "- " + $0 }.joined(separator: "\n")
                + "\n\n\(source) found these problems. Fix all of them, keep everything that already works and keep it one asset. \(image)"
        }
    }

    static func instruction(prompt: String, purpose: AssetPurpose, hasReference: Bool) -> String {
        let kind: String
        switch purpose {
        case .print: kind = "a 3D print, so it must be one solid object with a flat base, no floating or disconnected parts, and colours only per whole part"
        case .scene: kind = "a 3D scene, so it must read as one coherent place with sensibly sized, grounded objects"
        case .game: kind = "a game asset"
        }
        let what = hasReference
            ? """
            The image has two halves. LEFT: a reference picture of an object. RIGHT: four renders (front, right side, \
            three-quarter, back) of a 3D model that was built to match it. Compare the 3D model with the reference: \
            overall silhouette and proportions, which parts exist and where they attach, the shape of each part, \
            colours, materials, and notable details. Ignore the background, lighting and that the model is simpler than \
            a photo.
            """
            : """
            The image shows four renders (front, right side, three-quarter, back) of a 3D model. Review it against the \
            request below as a checklist: every object, part, colour, size and style it asks for, and every detail the \
            user gave. Also look for visible defects: parts floating in the air or sunk into others by mistake, missing \
            parts, parts facing the wrong way, broken or black faces, implausible proportions, and a model that doesn't \
            stand on the ground.
            """
        let scoreMeaning = hasReference ? "how well the model matches the reference" : "how well the model fulfils the request"
        return """
        \(what) The view labels are camera positions, so the model's own front may appear in a different panel; that \
        is not a fault unless it clearly faces the wrong way. The model is \(kind).

        The request was:
        \(prompt)

        Reply with only a JSON object, no other text:
        {"score": <0-10, \(scoreMeaning); 8+ means only minor issues>,
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

    static func critique(sheet: ReferenceImage, prompt: String, purpose: AssetPurpose, hasReference: Bool) async throws -> Verdict {
        guard let (p, model) = checker else {
            throw ForgeError("No vision model is available to compare the asset with the picture.")
        }
        let messages = [["role": "user", "content": instruction(prompt: prompt, purpose: purpose, hasReference: hasReference)]]
        let system = "You are a meticulous 3D art director reviewing a model\(hasReference ? " against its reference" : " against its brief"). You reply with JSON only."
        let stream = p.kind == .cli
            ? CLIRunner.stream(p, messages: messages, image: sheet, systemOverride: system, modelOverride: model)
            : RemoteEngine.stream(p, messages: messages, thinking: false, image: sheet, systemOverride: system)
        var text = ""
        for try await piece in stream { if case .content(let t, _) = piece { text += t } }
        return try parse(text, checker: ProviderSettings.label(p), hasReference: hasReference)
    }

    static func parse(_ text: String, checker: String, hasReference: Bool = true) throws -> Verdict {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw ForgeError("The vision model's comparison could not be read.")
        }
        let score = (obj["score"] as? NSNumber)?.intValue ?? Int(obj["score"] as? String ?? "") ?? 0
        let fixes = (obj["fixes"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Verdict(score: max(0, min(10, score)), fixes: Array(fixes.prefix(8)), checker: checker, hasReference: hasReference)
    }
}
