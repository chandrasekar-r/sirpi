import Foundation
import AppKit
import UniformTypeIdentifiers

/// Sends assets to Blender: open them in a running Blender with the GLB imported, or save a .blend file by running
/// Blender in the background. Uses Blender's own glTF importer, so materials, UVs and animations come through.
enum Blender {
    static let bundleID = "org.blenderfoundation.blender"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var executable: URL? { appURL?.appendingPathComponent("Contents/MacOS/Blender") }
    static var installed: Bool { executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }

    static let installHelp = "Blender is not installed. Get it from blender.org, or in Terminal run: brew install --cask blender"

    /// Python run inside Blender: clear the default scene, import the GLB, name the root, optionally save a .blend.
    static func script(glb: URL, name: String, saveTo: URL?) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
        var s = """
        import bpy
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=\(q(glb.path)))
        roots = [o for o in bpy.context.scene.objects if o.parent is None]
        if len(roots) == 1:
            roots[0].name = \(q(name))
        for area in (bpy.context.screen.areas if bpy.context.screen else []):
            if area.type == 'VIEW_3D':
                with bpy.context.temp_override(area=area, region=area.regions[-1]):
                    bpy.ops.view3d.view_all()
        """
        if let saveTo { s += "\nbpy.ops.wm.save_as_mainfile(filepath=\(q(saveTo.path)))\n" }
        return s
    }
}

extension AppModel {
    /// Writes the asset's GLB (with lightmap UVs if that option is on) to a temporary file Blender can import.
    private func glbForBlender(_ a: Asset) async throws -> URL {
        let data = try await exportableGLB(a)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sirpi-blender", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(a.fileStem + ".glb")
        try data.write(to: url)
        return url
    }

    func openInBlender() async {
        guard let a = selectedAsset else { return }
        guard let exe = Blender.executable, Blender.installed else { alert = Blender.installHelp; return }
        do {
            let glb = try await glbForBlender(a)
            let py = glb.deletingPathExtension().appendingPathExtension("py")
            try Blender.script(glb: glb, name: a.shortTitle, saveTo: nil).write(to: py, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = exe
            p.arguments = ["--python", py.path]
            try p.run()
            tasks.announce(title: "Opening in Blender", detail: a.shortTitle, assetID: a.id)
        } catch { alert = error.localizedDescription }
    }

    func saveBlendFile() async {
        guard let a = selectedAsset else { return }
        guard let exe = Blender.executable, Blender.installed else { alert = Blender.installHelp; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "blend") ?? .data]
        panel.nameFieldStringValue = a.fileStem + ".blend"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let task = tasks.start(.upload, title: "Saving \(a.shortTitle) for Blender", detail: "Importing in Blender", assetID: a.id, stage: .generate)
        do {
            let glb = try await glbForBlender(a)
            let py = glb.deletingPathExtension().appendingPathExtension("py")
            try Blender.script(glb: glb, name: a.shortTitle, saveTo: dest).write(to: py, atomically: true, encoding: .utf8)
            let r = await Shell.run(exe.path, ["-b", "--factory-startup", "--python", py.path], timeout: 300)
            guard FileManager.default.fileExists(atPath: dest.path) else {
                let tail = (r.stderr + String(decoding: r.stdout, as: UTF8.self)).split(separator: "\n").suffix(3).joined(separator: " ")
                throw ForgeError("Blender did not write the file. \(tail)")
            }
            tasks.finish(task, success: true, title: "Saved \(dest.lastPathComponent)", detail: "Open it in Blender.")
        } catch {
            tasks.finish(task, success: false, title: "Could not save for Blender", detail: error.localizedDescription)
        }
    }
}
