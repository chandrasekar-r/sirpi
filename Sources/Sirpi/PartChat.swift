import SwiftUI

// MARK: - A part picked in the preview

/// The mesh the user clicked, as the page described it.
struct PickedPart: Equatable {
    var name: String
    var path: [String]
    var geometry: String
    var params: [String: Double]
    var colors: [String]
    var materialNames: [String]
    var centre: [Double]
    var size: [Double]
    var modelMin: [Double]
    var modelMax: [Double]
    var sharedGeometry: Int

    init?(_ m: [String: Any]) {
        guard m["cleared"] == nil else { return nil }
        func nums(_ k: String) -> [Double] { ((m[k] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue } }
        name = m["name"] as? String ?? ""
        path = m["path"] as? [String] ?? []
        geometry = m["geometry"] as? String ?? ""
        params = ((m["params"] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        colors = (m["colors"] as? [String] ?? []).filter { !$0.isEmpty }
        materialNames = (m["materialNames"] as? [String] ?? []).filter { !$0.isEmpty }
        centre = nums("centre"); size = nums("size"); modelMin = nums("modelMin"); modelMax = nums("modelMax")
        sharedGeometry = (m["sharedGeometry"] as? NSNumber)?.intValue ?? 0
    }

    /// Short label for the chip: "Roof · box, #7a1f1f".
    var label: String {
        let shape = geometry.replacingOccurrences(of: "Geometry", with: "").replacingOccurrences(of: "Buffer", with: "")
        let what = shape.isEmpty ? "part" : shape.lowercased()
        let title = name.isEmpty ? (path.last ?? what.prefix(1).uppercased() + what.dropFirst()) : name
        return [title, name.isEmpty ? nil : what, colors.first].compactMap { $0 }.joined(separator: " · ")
    }

    /// Where the part sits in the model, in words.
    private var placement: String {
        guard centre.count == 3, modelMin.count == 3, modelMax.count == 3 else { return "" }
        func frac(_ i: Int) -> Double {
            let span = modelMax[i] - modelMin[i]
            return span > 1e-6 ? (centre[i] - modelMin[i]) / span : 0.5
        }
        let y = frac(1), x = frac(0), z = frac(2)
        let height = y < 0.33 ? "low" : y < 0.66 ? "at mid height" : "high up"
        let side = x < 0.33 ? "on the -X side" : x > 0.66 ? "on the +X side" : "centred in X"
        let depth = z < 0.33 ? "toward -Z (back)" : z > 0.66 ? "toward +Z (front)" : "centred in Z"
        return "\(height), \(side), \(depth)"
    }

    /// The text that tells the model which part to change, with the code that most likely builds it.
    func instruction(_ change: String, html: String) -> String {
        func v(_ a: [Double]) -> String { a.map { String(format: "%.2f", $0) }.joined(separator: ", ") }
        var lines = ["Change only this part of the model: \(change)", "", "The part the user selected:"]
        if !name.isEmpty { lines.append("- name: \(name)") }
        if !path.isEmpty { lines.append("- inside: \(path.joined(separator: " > "))") }
        if !geometry.isEmpty {
            let p = params.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%g", $0.value))" }.joined(separator: ", ")
            lines.append("- geometry: \(geometry)\(p.isEmpty ? "" : " (\(p))")")
        }
        if !colors.isEmpty { lines.append("- colour: \(colors.joined(separator: ", "))\(materialNames.isEmpty ? "" : ", material \(materialNames.joined(separator: ", "))")") }
        if centre.count == 3 { lines.append("- centre (world): \(v(centre)); size: \(v(size)); \(placement)") }
        if sharedGeometry > 0 { lines.append("- \(sharedGeometry) other mesh\(sharedGeometry == 1 ? " shares" : "es share") this geometry (probably copies made in a loop); change them only if the request says so") }
        if let code = likelyCode(in: html) {
            lines.append("")
            lines.append("It is most likely built by this code:")
            lines.append("```js\n\(code)\n```")
        }
        lines.append("")
        lines.append("Leave every other part exactly as it is.")
        return lines.joined(separator: "\n")
    }

    /// Lines of the page most likely to create this mesh: by name, then colour, then geometry and its numbers.
    func likelyCode(in html: String) -> String? {
        let source = html.components(separatedBy: "\n")
        guard !source.isEmpty else { return nil }
        var score = [Int](repeating: 0, count: source.count)
        let hexes = colors.map { $0.replacingOccurrences(of: "#", with: "").lowercased() }
        let ctor = geometry.replacingOccurrences(of: "BufferGeometry", with: "Geometry")
        let numbers = params.values.map { n -> String in n == n.rounded() ? String(Int(n)) : String(format: "%g", n) }
        for (i, raw) in source.enumerated() {
            let l = raw.lowercased()
            if !name.isEmpty && (raw.contains("'\(name)'") || raw.contains("\"\(name)\"")) { score[i] += 8 }
            for h in hexes where !h.isEmpty && (l.contains("0x" + h) || l.contains("#" + h)) { score[i] += 4 }
            if !ctor.isEmpty && raw.contains(ctor) {
                score[i] += 3
                score[i] += numbers.filter { raw.contains($0) }.count
            }
        }
        // Best window of 8 lines.
        var best = 0, bestScore = 0
        for start in 0..<source.count {
            let s = score[start..<min(source.count, start + 8)].reduce(0, +)
            if s > bestScore { bestScore = s; best = start }
        }
        guard bestScore >= 4 else { return nil }
        let from = max(0, best - 2), to = min(source.count, best + 10)
        return source[from..<to].joined(separator: "\n")
    }
}

// MARK: - Live preview of code being written

@Observable @MainActor
final class LivePreview {
    let web = WebController(injectBridge: false)
    var ready = false
    var meshes = 0
    var note: String?
    private var lastSource = ""
    private var started = false

    init() {
        web.onMessage = { [weak self] m in
            guard let self else { return }
            switch m["type"] as? String {
            case "liveReady": self.ready = true
            case "live":
                self.meshes = (m["meshes"] as? NSNumber)?.intValue ?? 0
                self.note = m["note"] as? String
            default: break
            }
        }
    }

    /// Starts a fresh view for a new generation.
    func begin() {
        lastSource = ""; meshes = 0; note = nil
        if !started || !ready {
            started = true; ready = false
            web.load(URL(string: "forge://app/live.html")!)
        } else {
            Task { await web.eval("window.live.reset(); true") }
        }
    }

    /// Sends the page as written so far; the page keeps the part that runs.
    func show(_ html: String) async {
        guard ready, html != lastSource, html.count > 200 else { return }
        lastSource = html
        let json = (try? JSONSerialization.data(withJSONObject: [html])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        await web.eval("window.live.run(\(json)[0]); true")
    }
}

// MARK: - Conversation of an asset's versions

/// One step in an asset's history: what was asked and the version it produced.
struct ChatTurn: Identifiable {
    var id: String { asset.id }
    let asset: Asset
    let request: String
    let isFirst: Bool
}

extension AssetLibrary {
    /// The versions leading to `asset`, oldest first.
    func lineage(of asset: Asset) -> [Asset] {
        var chain: [Asset] = [asset]
        var seen: Set<String> = [asset.id]
        while let pid = chain.first?.parentId, let parent = self.asset(pid), !seen.contains(pid) {
            chain.insert(parent, at: 0); seen.insert(pid)
        }
        return chain
    }
}

// MARK: - Views

/// The page being written, run as far as it goes.
struct LivePane: View {
    @Environment(AppModel.self) private var app
    var compact = false

    var body: some View {
        let live = app.live
        ZStack(alignment: .topLeading) {
            ForgeWebView(controller: live.web)
            HStack(spacing: 8) {
                if app.generator.isRunning { ProgressView().controlSize(.small) }
                Text(status(live)).font(compact ? .caption : .callout).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .padding(12)
        }
        .task {
            while !Task.isCancelled {
                if let src = app.generator.liveSource { await live.show(src) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func status(_ live: LivePreview) -> String {
        if live.meshes > 0 { return "Live preview · \(live.meshes) part\(live.meshes == 1 ? "" : "s") so far" }
        switch app.generator.phase {
        case .waiting: return "Waiting for \(app.generator.engineLabel.isEmpty ? "the model" : app.generator.engineLabel)"
        case .thinking: return "Planning; the preview starts with the code"
        default: return live.note.map { "Live preview: \($0)" } ?? "Live preview"
        }
    }
}

/// The selected asset while a new version of it is being written: the new code runs live in place of the preview.
struct RefiningViewport: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ZStack(alignment: .bottom) {
            LivePane()
            ViewportToolbar {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(app.generator.phaseLabel) · \(formatDuration(app.generator.elapsed)) · \(app.generator.codeTokens.formatted()) tokens")
                        .monospacedDigit().foregroundStyle(.secondary).padding(.horizontal, 6)
                }
                ViewportDivider()
                Button(role: .destructive) { app.stopGenerating() } label: { Label("Stop", systemImage: "stop.fill") }
                    .keyboardShortcut(".", modifiers: .command)
            }
            .padding(.bottom, 18)
        }
    }
}

/// An asset's versions as a conversation: what was asked, which version it made, and what is being written now.
struct AssetConversation: View {
    /// An example follow-up that fits the asset: printed objects get a size change, scenes and game assets a detail.
    static func replyHint(_ purpose: String?) -> String {
        switch AssetPurpose(rawValue: purpose ?? "") {
        case .print: "Make it 10 mm wider and round the corners"
        case .scene: "Add a few trees and a path to the door"
        default: "Make it more weathered and add a small detail"
        }
    }

    @Environment(AppModel.self) private var app
    let asset: Asset
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let g = app.generator
        let turns = app.library.lineage(of: asset)
        let writingHere = g.isRunning && g.baseID == asset.id
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { i, v in
                userBubble(i == 0 ? v.prompt : (v.refinement ?? "Edited by hand"))
                versionRow(v, number: i + 1, current: v.id == asset.id)
            }
            if writingHere {
                userBubble(g.title)
                writingBubble(g)
            } else if g.baseID == asset.id, case .failed(let m) = g.phase {
                notice(m, systemImage: "exclamationmark.triangle", color: Theme.destructive) {
                    if g.canContinue && app.canContinueNow { Button("Continue") { app.continueGeneration() }.buttonStyle(.glass).controlSize(.small) }
                }
            } else if !app.preview.errors.isEmpty && !app.preview.isLoading {
                notice("The preview has \(app.preview.errors.count == 1 ? "a script error" : "\(app.preview.errors.count) script errors").",
                       systemImage: "exclamationmark.triangle", color: Theme.warning) {
                    Button("Fix it") { app.fixErrors() }.buttonStyle(.glass).controlSize(.small)
                        .disabled(!app.engineReady || g.isRunning)
                }
            }
            composer
        }
        .onChange(of: app.refineFocusToken) { _, _ in focused = true }
    }

    // MARK: rows

    private func userBubble(_ s: String) -> some View {
        HStack {
            Spacer(minLength: 28)
            Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
                .lineLimit(8).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.12)))
                .help(s)
        }
    }

    private func versionRow(_ v: Asset, number: Int, current: Bool) -> some View {
        Button { app.selectedAssetID = v.id } label: {
            HStack(spacing: 8) {
                Image(systemName: current ? "cube.fill" : "cube").foregroundStyle(current ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Version \(number)\(current ? " · shown" : "")").fontWeight(current ? .semibold : .regular)
                    Text([v.genSeconds.map { formatDuration($0) }, v.engine].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current)
        .help(current ? "This version is in the preview" : "Show this version")
    }

    private func writingBubble(_ g: Generator) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(g.phaseLabel) · \(formatDuration(g.elapsed))").monospacedDigit()
                }
                Spacer()
                Button { app.stopGenerating() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).help("Stop")
            }
            let tail = String(StreamText.tail(g.content.isEmpty ? g.reasoning : g.content, limit: 280))
            if !tail.isEmpty {
                Text(tail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("\(g.codeTokens.formatted()) code tokens · \(g.engineLabel)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cell))
    }

    private func notice<B: View>(_ s: String, systemImage: String, color: Color, @ViewBuilder button: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(s, systemImage: systemImage).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            button()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cell))
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let part = app.pickedPart {
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundStyle(Theme.accent)
                    Text(part.label).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { app.pickedPart = nil; Task { await app.preview.eval("window.__sirpiPick && window.__sirpiPick.clear()") } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Change the whole model instead")
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
            } else if app.pickMode {
                Text("Click a part in the preview.").font(.callout).foregroundStyle(.secondary)
            }
            ResizablePanel(key: "refineEditor", defaultHeight: 72, range: 48...360) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 6).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cell))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.hairline))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(app.pickedPart != nil ? "What should change about this part?" : Self.replyHint(app.selectedAsset?.purpose))
                                .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        send(); return .handled
                    }
            }
            HStack {
                Button { app.setPickMode(!app.pickMode) } label: {
                    Label("Select part", systemImage: "scope")
                }
                .buttonStyle(.glass)
                .tint(app.pickMode ? Theme.accent : nil)
                .help(app.pickMode ? "Stop selecting parts" : "Click a part in the preview to change only that part")
                Spacer(minLength: 8)
                Button("Send") { send() }.buttonStyle(.glass)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !app.engineReady || app.generator.isRunning)
            }
        }
    }

    private func send() {
        let r = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, app.engineReady, !app.generator.isRunning else { return }
        text = ""
        app.refine(r, part: app.pickedPart)
    }
}
