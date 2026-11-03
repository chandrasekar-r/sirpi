import Foundation
import Observation
import AppKit

struct Asset: Codable, Identifiable, Hashable {
    var id: String
    var prompt: String
    var created: Date
    var parentId: String?
    var refinement: String?
    var genSeconds: Double?
    var tokens: Int?
    var imported: Bool? = nil
    /// Provider and model that wrote it, e.g. "Claude Code · sonnet".
    var engine: String? = nil
    /// True when a reference picture guided the generation (saved as reference.jpg).
    var hasReference: Bool? = nil
    /// "game" or "print" (nil for older assets: game).
    var purpose: String? = nil

    var dir: URL { Paths.library.appendingPathComponent(id, isDirectory: true) }
    var htmlURL: URL { dir.appendingPathComponent("asset.html") }
    var referenceURL: URL { dir.appendingPathComponent("reference.jpg") }
    /// Reference picture beside four renders, made by the automatic picture check.
    var comparisonURL: URL { dir.appendingPathComponent("comparison.jpg") }
    var glbURL: URL { dir.appendingPathComponent("asset.glb") }
    var stlURL: URL { dir.appendingPathComponent("asset.stl") }
    var threeMFURL: URL { dir.appendingPathComponent("\(fileStem).gcode.3mf") }
    var gcodeURL: URL { dir.appendingPathComponent("plate_1.gcode") }
    var plateImageURL: URL { dir.appendingPathComponent("plate_1.png") }
    var thumbURL: URL { dir.appendingPathComponent("thumb.png") }
    var sliceInfoURL: URL { dir.appendingPathComponent("slice.json") }

    /// forge:// URLs served by ForgeSchemeHandler.
    var pageURL: URL { URL(string: "forge://lib/\(id)/asset.html")! }

    var title: String {
        let base = refinement.map { "↳ \($0)" } ?? prompt
        return base.count > 60 ? String(base.prefix(57)) + "…" : base
    }

    /// A compact display name: drops "Create a"/"Build a" and trailing punctuation.
    var shortTitle: String {
        var t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["create a ", "create an ", "build a ", "build an ", "make a ", "make an ", "a ", "an "] where t.lowercased().hasPrefix(lead) {
            t = String(t.dropFirst(lead.count)); break
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let r = t.range(of: " wearing ") ?? t.range(of: " with ") ?? t.range(of: " in a ") { t = String(t[..<r.lowerBound]) }
        let s = t.prefix(1).uppercased() + t.dropFirst()
        return s.count > 40 ? String(s.prefix(38)) + "…" : s
    }

    /// Short filesystem-safe name used for printer uploads.
    var fileStem: String {
        let words = prompt.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let short = String(words.prefix(32))
        return (short.isEmpty ? "asset" : short) + "_" + String(id.prefix(4))
    }

    func has(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Observable @MainActor
final class AssetLibrary {
    var assets: [Asset] = []
    /// Bumped whenever an asset's files change so views (thumbnails etc.) refresh.
    var revision = 0

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.library, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        assets = dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")) else { return nil }
            return try? dec.decode(Asset.self, from: data)
        }.sorted { $0.created > $1.created }
        revision += 1
    }

    func asset(_ id: String?) -> Asset? { assets.first { $0.id == id } }

    @discardableResult
    func create(prompt: String, html: String, parent: Asset?, refinement: String?, seconds: Double, tokens: Int, engine: String? = nil,
                reference: Data? = nil, purpose: String? = nil) throws -> Asset {
        var a = Asset(id: UUID().uuidString.lowercased(), prompt: parent?.prompt ?? prompt, created: Date(),
                      parentId: parent?.id, refinement: refinement, genSeconds: seconds, tokens: tokens)
        a.engine = engine
        a.purpose = purpose
        try FileManager.default.createDirectory(at: a.dir, withIntermediateDirectories: true)
        if let reference {
            try? reference.write(to: a.referenceURL)
            a.hasReference = true
        }
        try html.write(to: a.htmlURL, atomically: true, encoding: .utf8)
        try save(a)
        assets.insert(a, at: 0)
        revision += 1
        return a
    }

    /// A new version of `parent` built from processed GLB bytes (e.g. smoothed and subdivided), shown in the GLB viewer.
    func createDerived(from parent: Asset, glb: Data, label: String) throws -> Asset {
        var a = Asset(id: UUID().uuidString.lowercased(), prompt: parent.prompt, created: Date(), parentId: parent.id,
                      refinement: label, genSeconds: nil, tokens: nil)
        a.imported = true
        a.engine = parent.engine
        a.purpose = parent.purpose
        try FileManager.default.createDirectory(at: a.dir, withIntermediateDirectories: true)
        try glb.write(to: a.glbURL)
        let viewer = try String(contentsOf: Paths.web.appendingPathComponent("viewer.html"), encoding: .utf8)
        try viewer.write(to: a.htmlURL, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: parent.referenceURL.path) {
            try? FileManager.default.copyItem(at: parent.referenceURL, to: a.referenceURL)
            a.hasReference = true
        }
        try save(a)
        assets.insert(a, at: 0)
        revision += 1
        return a
    }

    /// Imports an existing GLB as an asset with a bundled viewer page (export works the same as for generated assets).
    func importGLB(from src: URL) throws -> Asset {
        let name = src.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        var a = Asset(id: UUID().uuidString.lowercased(), prompt: name, created: Date(), parentId: nil, refinement: nil,
                      genSeconds: nil, tokens: nil)
        a.imported = true
        try FileManager.default.createDirectory(at: a.dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: a.glbURL)
        let viewer = try String(contentsOf: Paths.web.appendingPathComponent("viewer.html"), encoding: .utf8)
        try viewer.write(to: a.htmlURL, atomically: true, encoding: .utf8)
        try save(a)
        assets.insert(a, at: 0)
        revision += 1
        return a
    }

    func save(_ a: Asset) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try enc.encode(a).write(to: a.dir.appendingPathComponent("meta.json"))
    }

    func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        revision += 1
    }

    func touch() { revision += 1 }

    /// Moves the asset folder to the Trash (recoverable).
    func trash(_ a: Asset) {
        try? FileManager.default.trashItem(at: a.dir, resultingItemURL: nil)
        assets.removeAll { $0.id == a.id }
        revision += 1
    }

    func reveal(_ a: Asset) { NSWorkspace.shared.activateFileViewerSelecting([a.htmlURL]) }
}
