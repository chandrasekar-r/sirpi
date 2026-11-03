import SwiftUI
import AppKit

/// Drives Resources/web/scene.html: select objects of a generated scene, transform, recolour, duplicate, delete,
/// insert library assets, undo, and save the result as a new version of the asset.
@Observable @MainActor
final class SceneEditor {
    struct Object: Identifiable, Hashable { let id: String; var name: String; var visible: Bool }
    struct MaterialSwatch: Identifiable, Hashable { var id: Int { index }; let index: Int; var hex: String; var name: String }
    struct Selection: Equatable {
        var id: String
        var name: String
        var position: [Double]
        var rotation: [Double]
        var scale: [Double]
        var materials: [MaterialSwatch]
    }

    let assetID: String
    let web = WebController(injectBridge: false)
    var objects: [Object] = []
    var selected: Selection?
    var canUndo = false
    var mode = "translate"
    var snap = false
    var loading = true
    var saving = false
    var error: String?
    /// True once anything changed, so leaving asks to save.
    var dirty = false

    init(assetID: String) { self.assetID = assetID }

    func start() async {
        var ready = false
        web.onMessage = { [weak self] m in
            guard let self else { return }
            switch m["type"] as? String {
            case "sceneReady": ready = true
            case "sceneLoaded": self.loading = false
            case "scene": self.apply(m)
            default: break
            }
        }
        web.load(URL(string: "forge://app/scene.html")!)
        for _ in 0..<100 where !ready { try? await Task.sleep(for: .milliseconds(100)) }
        guard ready else { error = "The scene editor did not start."; loading = false; return }
        await web.eval("window.sceneEditor.load('forge://lib/\(assetID)/asset.glb?t=\(Date().timeIntervalSince1970)'); true")
    }

    private func apply(_ m: [String: Any]) {
        objects = ((m["objects"] as? [[String: Any]]) ?? []).map {
            Object(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "Object", visible: $0["visible"] as? Bool ?? true)
        }
        if let s = m["selected"] as? [String: Any] {
            let nums: (String) -> [Double] = { k in ((s[k] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue } }
            selected = Selection(
                id: s["id"] as? String ?? "", name: s["name"] as? String ?? "",
                position: nums("position"), rotation: nums("rotation"), scale: nums("scale"),
                materials: ((s["materials"] as? [[String: Any]]) ?? []).map {
                    MaterialSwatch(index: ($0["index"] as? NSNumber)?.intValue ?? 0, hex: $0["hex"] as? String ?? "#888888",
                                   name: $0["name"] as? String ?? "")
                })
        } else {
            selected = nil
        }
        let undoable = m["canUndo"] as? Bool ?? false
        if undoable && !canUndo { dirty = true }
        canUndo = undoable
        mode = m["mode"] as? String ?? mode
        snap = m["snap"] as? Bool ?? snap
    }

    /// Calls window.sceneEditor.<js>; strings are passed as JSON so names with quotes are safe.
    func call(_ js: String) { Task { await web.eval("window.sceneEditor.\(js); true") } }
    static func json(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    func select(_ id: String) { call("select(\(Self.json(id)))") }
    func setMode(_ m: String) { call("setMode('\(m)')") }
    func setSnap(_ on: Bool) { call("setSnap(\(on))") }
    func undo() { call("undo()") }
    func frameAll() { call("frameAll()") }
    func focus(_ id: String) { call("focus(\(Self.json(id)))") }
    func toggleVisible(_ id: String) { dirty = true; call("toggleVisible(\(Self.json(id)))") }
    func duplicate(_ id: String) { dirty = true; call("duplicate(\(Self.json(id)))") }
    func remove(_ id: String) { dirty = true; call("remove(\(Self.json(id)))") }
    func rename(_ id: String, _ name: String) { dirty = true; call("rename(\(Self.json(id)), \(Self.json(name)))") }
    func setColor(_ id: String, _ index: Int, _ hex: String) { dirty = true; call("setColor(\(Self.json(id)), \(index), \(Self.json(hex)))") }
    func setTransform(_ id: String, position: [Double]? = nil, rotation: [Double]? = nil, scale: [Double]? = nil) {
        dirty = true
        var t: [String: Any] = [:]
        if let position { t["position"] = position }
        if let rotation { t["rotation"] = rotation }
        if let scale { t["scale"] = scale }
        call("setTransform(\(Self.json(id)), \(Self.json(t)))")
    }
    func insert(_ asset: Asset) {
        dirty = true
        call("insert('forge://lib/\(asset.id)/asset.glb?t=\(Date().timeIntervalSince1970)', \(Self.json(asset.shortTitle)))")
    }

    /// Exports the edited scene as GLB bytes.
    func export() async throws -> Data {
        let id = UUID().uuidString
        let result: [String: Any] = try await withCheckedThrowingContinuation { cont in
            var done = false
            let previous = web.onMessage
            web.onMessage = { m in
                previous?(m)
                guard !done, m["type"] as? String == "sceneExport", m["requestId"] as? String == id else { return }
                done = true
                if let e = m["error"] as? String { cont.resume(throwing: ForgeError("Export failed: \(e.prefix(300))")) }
                else { cont.resume(returning: m) }
            }
            Task {
                await web.eval("window.sceneEditor.export('\(id)'); true")
                try? await Task.sleep(for: .seconds(60))
                if !done { done = true; cont.resume(throwing: ForgeError("Export timed out.")) }
            }
        }
        guard let b64 = result["data"] as? String, let data = Data(base64Encoded: b64) else { throw ForgeError("No GLB came back.") }
        return data
    }
}

// MARK: - App model hooks

extension AppModel {
    /// Opens the selected asset in the scene customiser.
    func customise(_ a: Asset) async {
        do { try await ensureGLB(a) } catch { alert = error.localizedDescription; return }
        let ed = SceneEditor(assetID: a.id)
        sceneEditor = ed
        stage = .generate
        await ed.start()
    }

    func saveScene() async {
        guard let ed = sceneEditor, let a = library.asset(ed.assetID) else { return }
        ed.saving = true
        defer { ed.saving = false }
        do {
            let glb = try await ed.export()
            let label = a.purpose == "scene" ? "Customised scene" : "Customised"
            let new = try library.createDerived(from: a, glb: glb, label: label)
            sceneEditor = nil
            selectedAssetID = new.id
            tasks.announce(title: "Saved \(a.shortTitle)", detail: "Your changes are a new version; the original is unchanged.", assetID: new.id)
        } catch {
            alert = error.localizedDescription
        }
    }

    func closeScene() { sceneEditor = nil }
}

// MARK: - Viewport

struct SceneEditorViewport: View {
    @Environment(AppModel.self) private var app
    let editor: SceneEditor
    var body: some View {
        ZStack(alignment: .bottom) {
            ForgeWebView(controller: editor.web)
            if editor.loading {
                ProgressView("Opening scene…").padding(14).glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let e = editor.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ViewportToolbar {
                Picker("Tool", selection: Binding(get: { editor.mode }, set: { editor.setMode($0) })) {
                    Label("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right").tag("translate")
                    Label("Rotate", systemImage: "arrow.trianglehead.2.clockwise.rotate.90").tag("rotate")
                    Label("Scale", systemImage: "arrow.up.left.and.arrow.down.right").tag("scale")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Move (W), rotate (E), scale (R)")
                ViewportDivider()
                Toggle(isOn: Binding(get: { editor.snap }, set: { editor.setSnap($0) })) {
                    Label("Snap", systemImage: "squareshape.split.3x3")
                }
                .toggleStyle(.button).help("Snap to 0.25 m, 15° and 0.1× steps")
                Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!editor.canUndo).help("Undo (⌘Z)")
                Button { editor.frameAll() } label: { Image(systemName: "viewfinder") }.help("Frame the whole scene")
            }
            .padding(.bottom, 18)
        }
    }
}

// MARK: - Inspector

struct SceneInspector: View {
    @Environment(AppModel.self) private var app
    let editor: SceneEditor
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customise").font(.headline)
                Text("Click an object in the view, or pick it below.").foregroundStyle(.secondary)
            }
            .padding(16)

            InspectorSection(title: "Objects", trailing: AnyView(insertMenu)) {
                ResizablePanel(key: "sceneObjects", defaultHeight: 220, range: 100...600) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(editor.objects) { o in row(o).id(o.id) }
                            }
                        }
                        .onChange(of: editor.selected?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cell))
                }
                if editor.objects.isEmpty && !editor.loading {
                    Text("This asset has no separate objects to edit.").foregroundStyle(.secondary)
                }
            }

            ScrollView {
                if let s = editor.selected {
                    SelectionEditor(editor: editor, selection: s)
                } else {
                    Text("Nothing selected.").foregroundStyle(.secondary).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            InspectorSection {
                HStack(spacing: 8) {
                    Button("Discard") { if editor.dirty { confirmDiscard = true } else { app.closeScene() } }
                        .buttonStyle(.glass)
                    PrimaryButton(title: editor.saving ? "Saving…" : "Save as new version", systemImage: "checkmark", fullWidth: true) {
                        Task { await app.saveScene() }
                    }
                    .disabled(editor.saving || editor.loading)
                }
            }
        }
        .confirmationDialog("Discard your changes to this scene?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { app.closeScene() }
        } message: { Text("The original asset stays as it was.") }
    }

    private var insertMenu: some View {
        Menu {
            Button("From NVIDIA SimReady…") { app.simReadyIntoScene = true; app.showSimReady = true }
            Divider()
            ForEach(app.library.assets.filter { $0.id != editor.assetID }.prefix(40)) { a in
                Button(a.shortTitle) { Task { try? await app.ensureGLB(a); editor.insert(a) } }
            }
        } label: { Label("Insert", systemImage: "plus") }
        .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
        .help("Add an asset from your library to this scene")
    }

    private func row(_ o: SceneEditor.Object) -> some View {
        let on = editor.selected?.id == o.id
        return HStack(spacing: 8) {
            // A real button, so clicks, keyboard and VoiceOver all select; double-click frames the object.
            Button { editor.select(o.id) } label: {
                Text(o.name).lineLimit(1).foregroundStyle(o.visible ? .primary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { editor.focus(o.id) })
            .accessibilityAddTraits(on ? .isSelected : [])
            Button { editor.toggleVisible(o.id) } label: {
                Image(systemName: o.visible ? "eye" : "eye.slash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).help(o.visible ? "Hide" : "Show")
            .accessibilityLabel(o.visible ? "Hide \(o.name)" : "Show \(o.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.accent.opacity(0.18) : .clear))
    }
}

private struct SelectionEditor: View {
    let editor: SceneEditor
    let selection: SceneEditor.Selection
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "Selected") {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    .onSubmit { editor.rename(selection.id, name) }
                Vec3Field(label: "Position (m)", values: selection.position, step: 0.1) { editor.setTransform(selection.id, position: $0) }
                Vec3Field(label: "Rotation (°)", values: selection.rotation, step: 15) { editor.setTransform(selection.id, rotation: $0) }
                Vec3Field(label: "Scale", values: selection.scale, step: 0.1) { editor.setTransform(selection.id, scale: $0) }
            }
            if !selection.materials.isEmpty {
                InspectorSection(title: "Colours") {
                    ForEach(selection.materials) { m in
                        ColorPicker(m.name, selection: Binding(
                            get: { Color(hex: m.hex) },
                            set: { editor.setColor(selection.id, m.index, $0.hexString) }), supportsOpacity: false)
                    }
                }
            }
            InspectorSection {
                HStack {
                    Button { editor.duplicate(selection.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        .keyboardShortcut("d", modifiers: .command)
                    Button(role: .destructive) { editor.remove(selection.id) } label: { Label("Delete", systemImage: "trash") }
                    Spacer()
                    Button { editor.focus(selection.id) } label: { Image(systemName: "scope") }.help("Frame this object (F)")
                }
                .buttonStyle(.glass)
            }
        }
        .onAppear { name = selection.name }
        .onChange(of: selection.id) { _, _ in name = selection.name }
    }
}

/// Three number fields (X, Y, Z). Text is parsed on Return or when a field loses focus, so what you typed is what
/// gets applied (a formatted value field can still hold the previous number when Return fires).
private struct Vec3Field: View {
    let label: String
    let values: [Double]
    var step: Double = 0.1
    let commit: ([Double]) -> Void
    @State private var text: [String] = ["0", "0", "0"]
    @FocusState private var focus: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 3) {
                        Text(["X", "Y", "Z"][i]).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        TextField(["X", "Y", "Z"][i], text: Binding(get: { text[i] }, set: { text[i] = $0 }))
                            .textFieldStyle(.roundedBorder).monospacedDigit().labelsHidden()
                            .focused($focus, equals: i)
                            .onSubmit(apply)
                            .accessibilityLabel("\(label) \(["X", "Y", "Z"][i])")
                    }
                }
            }
        }
        .onAppear(perform: sync)
        .onChange(of: values) { _, _ in if focus == nil { sync() } }
        .onChange(of: focus) { old, new in if old != nil && new != old { apply() } }
    }

    private func apply() {
        let parsed = text.enumerated().map { i, t in
            Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? (values.count == 3 ? values[i] : 0)
        }
        if parsed != values { commit(parsed) }
    }

    private func sync() {
        guard values.count == 3 else { return }
        text = values.map { v in v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
    }
}

extension Color {
    /// sRGB hex like "#a1b2c3".
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
