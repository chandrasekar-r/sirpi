import Foundation

/// When a model rewrites a whole file to change one thing, it sometimes leaves out a helper function the rest of the
/// code still calls (`addBolt is not defined`), which breaks a page that only needed a one-line fix. This puts back
/// any `function name(...)` the new file calls but no longer defines, copied from the earlier versions.
enum HelperRestore {
    /// Returns the file with missing helpers restored, and their names (empty when nothing was missing).
    static func restore(_ html: String, from earlier: [String]) -> (html: String, restored: [String]) {
        guard let close = html.range(of: "</script>", options: .backwards) else { return (html, []) }
        var defs: [String] = [], names: [String] = []
        for name in calledButUndefined(html) {
            guard let body = earlier.lazy.compactMap({ definition(of: name, in: $0) }).first else { continue }
            defs.append(body); names.append(name)
        }
        guard !defs.isEmpty else { return (html, []) }
        // Function declarations are hoisted, so the end of the last script is in scope for every call above it.
        var out = html
        out.insert(contentsOf: "\n    // Restored from the previous version.\n" + defs.joined(separator: "\n\n") + "\n  ",
                   at: close.lowerBound)
        return (out, names)
    }

    /// Plain calls `name(` (not `.name(` or `new name(`) to names the file never declares.
    static func calledButUndefined(_ html: String) -> [String] {
        let calls = matches(#"(?<![\w$.])(?<!new )([A-Za-z_$][\w$]*)\s*\("#, in: html)
        let declared = Set(matches(#"\bfunction\s*\*?\s*([A-Za-z_$][\w$]*)"#, in: html)
            + matches(#"\b(?:const|let|var|class)\s+([A-Za-z_$][\w$]*)"#, in: html)
            + matches(#"\bimport\s*\{([^}]*)\}"#, in: html).flatMap { $0.split(separator: ",").map {
                String($0.split(separator: " ").last ?? "").trimmingCharacters(in: .whitespaces) } }
            + matches(#"\bimport\s+\*\s+as\s+([A-Za-z_$][\w$]*)"#, in: html)
            + matches(#"\bimport\s+([A-Za-z_$][\w$]*)\s+from"#, in: html))
        var seen = Set<String>(), out: [String] = []
        for c in calls where !declared.contains(c) && !builtins.contains(c) && seen.insert(c).inserted { out.append(c) }
        return out
    }

    /// The whole `function name(...) { ... }` declaration, with its leading indentation, or nil.
    static func definition(of name: String, in html: String) -> String? {
        let esc = NSRegularExpression.escapedPattern(for: name)
        guard let re = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(?:async[ \t]+)?function[ \t]+"# + esc + #"\s*\("#),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let start = Range(m.range, in: html)?.lowerBound,
              let open = html[start...].firstIndex(of: "{") else { return nil }
        // Brace matching that skips strings, template literals and comments.
        var depth = 0, i = open, quote: Character? = nil, lineComment = false, blockComment = false
        while i < html.endIndex {
            let c = html[i]
            let next = html.index(after: i) < html.endIndex ? html[html.index(after: i)] : nil
            if lineComment { if c == "\n" { lineComment = false } }
            else if blockComment { if c == "*" && next == "/" { blockComment = false; i = html.index(after: i) } }
            else if let q = quote {
                if c == "\\" { i = html.index(after: i) } else if c == q { quote = nil }
            } else if c == "/" && next == "/" { lineComment = true }
            else if c == "/" && next == "*" { blockComment = true }
            else if c == "\"" || c == "'" || c == "`" { quote = c }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(html[start...i]) } }
            if i < html.endIndex { i = html.index(after: i) }
        }
        return nil
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    private static let builtins: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "function", "typeof", "await", "import", "super", "with",
        "requestAnimationFrame", "setTimeout", "setInterval", "clearTimeout", "clearInterval", "fetch", "alert",
        "parseInt", "parseFloat", "isNaN", "isFinite", "Number", "String", "Boolean", "Array", "Object", "Math",
        "Date", "JSON", "Promise", "Symbol", "Error", "TypeError", "Map", "Set", "WeakMap", "BigInt", "Proxy",
        "Uint8Array", "Uint16Array", "Uint32Array", "Int8Array", "Int16Array", "Int32Array", "Float32Array",
        "Float64Array", "ArrayBuffer", "DataView", "Blob", "URL", "encodeURIComponent", "decodeURIComponent",
        "atob", "btoa", "structuredClone", "queueMicrotask", "getComputedStyle", "matchMedia", "rgb", "rgba",
        "hsl", "hsla", "calc", "min", "max", "clamp", "var", "url", "translate", "translateX", "translateY",
        "scale", "rotate", "blur", "drop", "linear", "radial", "conic", "cubic", "steps", "minmax", "repeat",
        "env", "attr", "inset", "polygon", "circle", "ellipse", "local", "format", "not", "is", "where", "has",
    ]
}
