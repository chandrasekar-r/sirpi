import SwiftUI
import Foundation

// NVIDIA SimReady (huggingface.co/datasets/nvidia/simready-assets, CC-BY-4.0): 2,677 OpenUSD assets with PBR
// materials. Sirpi browses the catalogue, converts a chosen asset to GLB with Pixar's USD library (Resources/tools/
// simready_to_glb.py, run in a private Python environment), and adds it to the library with attribution.

struct SimReadyItem: Identifiable, Hashable, Codable {
    let id: String              // folder name, e.g. "IV_pole_a01"
    var title: String {
        var parts = id.split(separator: "_").map(String.init)
        if let last = parts.last, last.range(of: #"^[a-z]\d{2}$"#, options: .regularExpression) != nil { parts.removeLast() }
        let t = parts.joined(separator: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }
    var variant: String { id.split(separator: "_").last.map(String.init) ?? "" }
    var category: String { (id.split(separator: "_").first.map(String.init) ?? id).lowercased() }
    var thumbURL: URL? {
        URL(string: "https://huggingface.co/datasets/nvidia/simready-assets/resolve/main/\(id)/simready_usd/.thumbs/256x256/sm_\(id)_01.usd.png")
    }
}

@Observable @MainActor
final class SimReadyLibrary {
    var items: [SimReadyItem] = []
    var loading = false
    var error: String?
    var importing: String?          // item id being imported
    var status = ""
    private var cacheURL: URL { Paths.support.appendingPathComponent("simready-catalog.json") }
    var pythonDir: URL { Paths.support.appendingPathComponent("python-usd", isDirectory: true) }
    var python: URL { pythonDir.appendingPathComponent("bin/python") }
    var tool: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("tools/simready_to_glb.py")
        if let b = bundled, FileManager.default.fileExists(atPath: b.path) { return b }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/tools/simready_to_glb.py")
        return FileManager.default.fileExists(atPath: src.path) ? src : nil
    }

    /// Loads the cached catalogue, refreshing from Hugging Face when it is missing or older than a week.
    func load(force: Bool = false) async {
        if !force, items.isEmpty, let d = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([SimReadyItem].self, from: d) {
            items = cached
        }
        let age = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        guard force || items.isEmpty || age > 7 * 86400 else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            var all: [SimReadyItem] = []
            var next: URL? = URL(string: "https://huggingface.co/api/datasets/nvidia/simready-assets/tree/main?limit=1000")
            while let url = next {
                let (data, resp) = try await URLSession.shared.data(from: url)
                let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
                all += rows.filter { $0["type"] as? String == "directory" }.compactMap { ($0["path"] as? String).map(SimReadyItem.init) }
                next = Self.nextLink((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link"))
            }
            items = all.filter { !$0.id.hasPrefix(".") }.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            if let d = try? JSONEncoder().encode(items) { try? d.write(to: cacheURL) }
        } catch {
            self.error = "Could not load the SimReady catalogue: \(error.localizedDescription)"
        }
    }

    private static func nextLink(_ header: String?) -> URL? {
        guard let header, let r = header.range(of: #"<([^>]+)>;\s*rel="next""#, options: .regularExpression) else { return nil }
        let part = String(header[r])
        guard let s = part.firstIndex(of: "<"), let e = part.firstIndex(of: ">") else { return nil }
        return URL(string: String(part[part.index(after: s)..<e]))
    }

    /// Creates the private Python environment with Pixar's USD library the first time it is needed.
    func ensurePython() async throws {
        if FileManager.default.isExecutableFile(atPath: python.path) {
            let ok = await Shell.run(python.path, ["-c", "import pxr, pygltflib, PIL, numpy"], timeout: 30)
            if ok.status == 0 { return }
        }
        guard let uv = CLIRunner.resolvedPath("uv") else {
            throw ForgeError("Setting up the USD converter needs uv. In Terminal run: curl -LsSf https://astral.sh/uv/install.sh | sh")
        }
        status = "Setting up the USD converter (one time, about 150 MB)…"
        let env = await Task.detached { CLIRunner.shellEnvironment }.value
        var r = await Shell.run(uv, ["venv", "-q", "-p", "3.12", pythonDir.path], timeout: 600, environment: env)
        guard r.status == 0 else { throw ForgeError("Could not create the Python environment: \(r.stderr.suffix(300))") }
        r = await Shell.run(uv, ["pip", "install", "-q", "--python", python.path, "usd-core", "pygltflib", "pillow", "numpy"],
                            timeout: 900, environment: env)
        guard r.status == 0 else { throw ForgeError("Could not install the USD converter: \(r.stderr.suffix(300))") }
    }

    /// Downloads and converts one asset; returns the GLB file.
    func convert(_ item: SimReadyItem, textureSize: String) async throws -> URL {
        guard let tool else { throw ForgeError("The SimReady converter script is missing from the app.") }
        try await ensurePython()
        status = "Downloading \(item.title) and converting to GLB…"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("simready", isDirectory: true)
            .appendingPathComponent("\(item.title) \(item.variant).glb")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SimReady").path
        let r = await Shell.run(python.path, [tool.path, item.id, out.path, "--cache", cache, "--tex", textureSize], timeout: 1800)
        guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            let msg = (r.stderr.split(separator: "\n").filter { !$0.hasPrefix("Warning") }.suffix(3)).joined(separator: " ")
            throw ForgeError("Conversion failed: \(msg.isEmpty ? "unknown error" : String(msg.prefix(400)))")
        }
        return out
    }
}

extension AppModel {
    /// Imports a SimReady asset into the library (and, when given, into the open scene).
    func importSimReady(_ item: SimReadyItem, textureSize: String, intoScene: Bool) async {
        let lib = simready
        guard lib.importing == nil else { return }
        lib.importing = item.id
        defer { lib.importing = nil; lib.status = "" }
        let task = tasks.start(.download, title: "Importing \(item.title)", detail: "NVIDIA SimReady", stage: .generate)
        do {
            let glb = try await lib.convert(item, textureSize: textureSize)
            var a = try library.importGLB(from: glb)
            a.engine = "NVIDIA SimReady \(item.id) · CC-BY-4.0"
            try? library.save(a)
            if let i = library.assets.firstIndex(where: { $0.id == a.id }) { library.assets[i] = a }
            library.touch()
            tasks.finish(task, success: true, title: "\(item.title) imported", detail: "Credit: NVIDIA SimReady, CC-BY-4.0.")
            if intoScene, let ed = sceneEditor {
                ed.insert(a)
            } else {
                selectedAssetID = a.id
                stage = .generate
            }
            showSimReady = false
        } catch {
            tasks.finish(task, success: false, title: "Could not import \(item.title)", detail: error.localizedDescription)
        }
    }
}

// MARK: - Browser

struct SimReadyBrowser: View {
    @Environment(AppModel.self) private var app
    var intoScene = false
    @State private var query = ""
    @State private var category = "all"
    @State private var selected: SimReadyItem?
    @AppStorage("simreadyTextureSize") private var textureSize = "512"

    var body: some View {
        let lib = app.simready
        let filtered = lib.items.filter {
            (category == "all" || $0.category == category)
                && (query.isEmpty || $0.id.localizedCaseInsensitiveContains(query.replacingOccurrences(of: " ", with: "_"))
                    || $0.title.localizedCaseInsensitiveContains(query))
        }
        let categories = Dictionary(grouping: lib.items, by: \.category).filter { $0.value.count >= 5 }.keys.sorted()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(intoScene ? "Insert from NVIDIA SimReady" : "NVIDIA SimReady library").font(.title3.weight(.semibold))
                    Text("\(lib.items.count.formatted()) real-world assets with PBR materials. CC-BY-4.0, credit NVIDIA.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { app.showSimReady = false }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            HStack(spacing: 10) {
                TextField("Search chairs, boxes, shelves…", text: $query).textFieldStyle(.roundedBorder)
                Picker("Category", selection: $category) {
                    Text("All categories").tag("all")
                    ForEach(categories, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .frame(width: 200)
                Button { Task { await lib.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh the catalogue").disabled(lib.loading)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            ZStack {
                if lib.loading && lib.items.isEmpty {
                    ProgressView("Loading catalogue…")
                } else if let e = lib.error, lib.items.isEmpty {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).padding()
                } else if filtered.isEmpty {
                    Text("Nothing matches \"\(query)\".").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                            ForEach(filtered.prefix(600)) { item in tile(item) }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                if let s = selected {
                    AsyncImage(url: s.thumbURL) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { Theme.cell }
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).fontWeight(.semibold)
                        Text(lib.status.isEmpty ? s.id : lib.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("Pick an asset.").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Textures", selection: $textureSize) {
                    Text("256 px").tag("256"); Text("512 px").tag("512"); Text("Full (large download)").tag("full")
                }
                .frame(width: 210)
                PrimaryButton(title: lib.importing != nil ? "Importing…" : (intoScene ? "Insert" : "Import"),
                              systemImage: lib.importing != nil ? nil : "square.and.arrow.down") {
                    if let s = selected { Task { await app.importSimReady(s, textureSize: textureSize, intoScene: intoScene) } }
                }
                .disabled(selected == nil || lib.importing != nil)
            }
            .padding(16)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 680)
        .task { await lib.load() }
    }

    private func tile(_ item: SimReadyItem) -> some View {
        let on = selected?.id == item.id
        return Button { selected = item } label: {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: item.thumbURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                    case .failure: Image(systemName: "cube").font(.title).foregroundStyle(.tertiary)
                    default: Theme.cell
                    }
                }
                .frame(height: 112).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                Text(item.title).font(.callout).lineLimit(1)
                Text(item.variant).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Theme.accent.opacity(0.16) : Theme.cell))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title + " " + item.variant)
        .accessibilityAddTraits(on ? .isSelected : [])
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selected = item
            Task { await app.importSimReady(item, textureSize: textureSize, intoScene: intoScene) }
        })
    }
}
