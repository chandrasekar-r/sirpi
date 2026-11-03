import Foundation

// MARK: - Search/replace patches for refinements

/// Small fixes come back as SEARCH/REPLACE blocks instead of a whole new file, so a one-line fix to a 20k-token asset
/// costs a few hundred tokens. If a block doesn't match the code, the caller falls back to a full rewrite.
enum Patch {
    static let enabledKey = "patchRefinements"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    struct Block { let search: String; let replace: String }

    static let instruction = """
    Reply with only the changes, as one or more edit blocks in exactly this format:

    <<<<<<< SEARCH
    (lines copied exactly from the current file, including indentation)
    =======
    (the lines that replace them)
    >>>>>>> REPLACE

    Rules: copy each SEARCH section character for character from the current file; keep it short (usually 2 to 15 \
    lines) but long enough to match only one place; use several blocks for changes in different places; to insert \
    code, SEARCH for the line before the insertion point and repeat it in the replacement. Do not return the whole \
    file and do not explain. Only if the change rewrites most of the file, return the complete file in one ```html block instead.
    """

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var rest = Substring(text)
        while let s = rest.range(of: "<<<<<<< SEARCH") {
            let afterS = rest[s.upperBound...]
            guard let mid = afterS.range(of: "\n=======") else { break }
            let afterMid = afterS[mid.upperBound...]
            guard let end = afterMid.range(of: ">>>>>>> REPLACE") else { break }
            let search = trimOneNewline(String(afterS[..<mid.lowerBound]))
            let replace = trimOneNewline(String(afterMid[..<end.lowerBound]))
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(Block(search: search, replace: replace)) }
            rest = afterMid[end.upperBound...]
        }
        return blocks
    }

    /// True when the text has started a patch, even if it is not finished yet.
    static func looksLikePatch(_ text: String) -> Bool { text.contains("<<<<<<< SEARCH") }

    /// Applies blocks in order. Returns nil, with the failing block's index, if any block matches nowhere.
    static func apply(_ blocks: [Block], to source: String) -> (html: String?, failed: Int?) {
        var html = source
        for (i, b) in blocks.enumerated() {
            if let r = html.range(of: b.search) {
                html.replaceSubrange(r, with: b.replace)
            } else if let patched = applyLoose(b, to: html) {
                html = patched
            } else {
                return (nil, i)
            }
        }
        return (html, nil)
    }

    /// Matches line by line ignoring leading/trailing whitespace, which small models often get wrong.
    private static func applyLoose(_ b: Block, to html: String) -> String? {
        let lines = html.components(separatedBy: "\n")
        var want = b.search.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        while want.first?.isEmpty == true { want.removeFirst() }
        while want.last?.isEmpty == true { want.removeLast() }
        guard !want.isEmpty, lines.count >= want.count else { return nil }
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        for start in 0...(lines.count - want.count) where trimmed[start] == want[0] {
            if Array(trimmed[start..<(start + want.count)]) == want {
                // Keep the file's indentation for the first replaced line when the model dropped it.
                let indent = String(lines[start].prefix { $0 == " " || $0 == "\t" })
                var rep = b.replace.components(separatedBy: "\n")
                if let first = rep.first, !first.hasPrefix(" "), !first.hasPrefix("\t"), !first.isEmpty { rep[0] = indent + first }
                var out = lines
                out.replaceSubrange(start..<(start + want.count), with: rep)
                return out.joined(separator: "\n")
            }
        }
        return nil
    }

    private static func trimOneNewline(_ s: String) -> String {
        var s = s
        if s.hasPrefix("\n") { s.removeFirst() }
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }
}

// MARK: - Cut-off answers

enum Continuation {
    /// True when an HTML answer stops before the file is complete.
    static func isTruncated(_ html: String) -> Bool {
        let l = html.lowercased()
        if l.contains("</html>") { return false }
        guard let open = l.range(of: "<script", options: .backwards) else { return true }
        return !l[open.upperBound...].contains("</script>")
    }

    static func request(tail: String) -> String {
        """
        Your answer was cut off before the file was finished. Continue it from exactly where it stops: start with the \
        very next character, do not repeat anything already written, do not open a new code block and do not explain. \
        Finish the file, including the closing </script>, </body> and </html> tags and the closing ``` fence. \
        Your answer currently ends with:

        \(tail)
        """
    }

    /// Joins the partial answer and its continuation, dropping a repeated overlap or a re-opened code fence.
    static func join(_ partial: String, _ continuation: String) -> String {
        var cont = continuation
        // A model that restarts the file from the top: keep the restart if it is complete.
        let lc = cont.lowercased()
        if let d = lc.range(of: "<!doctype") ?? lc.range(of: "<html"), lc.distance(from: lc.startIndex, to: d.lowerBound) < 40,
           lc.contains("</html>") {
            return cont
        }
        if cont.hasPrefix("```") { cont = String(cont.drop { $0 != "\n" }.dropFirst()) }
        let maxK = min(2000, cont.count, partial.count)
        if maxK >= 12 {
            for k in stride(from: maxK, through: 12, by: -1) where partial.hasSuffix(cont.prefix(k)) {
                cont = String(cont.dropFirst(k)); break
            }
        }
        return partial + cont
    }
}
