import Foundation
import Observation

struct SliceOptions: Equatable {
    var process: String = "0.20mm Standard @BBL P2S"
    var filament: String = "Bambu PLA Basic @BBL P2S"
    /// What the user picked: "auto" (only when the model needs them), "tree(auto)", "normal(auto)" or "off".
    var supportMode: String = SliceOptions.savedSupportMode
    /// Resolved from `supportMode` just before slicing.
    var supports: Bool = false
    var supportType: String = "tree(auto)"
    var infill: Int = 15
    var wallLoops: Int = 2
    var brim: Bool = false
    /// Preset values changed by print-check fixes, by Bambu Studio key.
    var processOverrides: [String: String] = [:]
    var filamentOverrides: [String: String] = [:]

    static let supportModeKey = "supportMode"
    static var savedSupportMode: String { UserDefaults.standard.string(forKey: supportModeKey) ?? "auto" }

    /// Supports for this slice: in automatic mode, on only when the model has parts in mid-air or steep undersides.
    func resolved(needsSupports: Bool) -> SliceOptions {
        var o = self
        switch supportMode {
        case "off": o.supports = false
        case "auto": o.supports = needsSupports; o.supportType = "tree(auto)"
        default: o.supports = true; o.supportType = supportMode
        }
        return o
    }
}

/// One filament of a (possibly multi-colour) print: its STL and the slot it is meant for.
struct SliceFilament {
    var stl: URL
    var hex: String
    var slot: String        // "tray:<id>" for an AMS/external tray, "v:<n>" for an unassigned colour
    var type: String?       // filament type from the AMS tray (PLA, PETG…) when known
}

struct FilamentUse: Codable, Hashable {
    var hex: String
    var type: String
    var grams: Double
    var meters: Double
    var slot: String
}

struct SliceResult: Codable {
    var seconds: Double
    var weightGrams: Double
    var filamentMeters: Double
    var filamentType: String
    var filamentColor: String
    var process: String
    var filament: String
    var slicedAt: Date
    var filaments: [FilamentUse]? = nil
    var changes: Int? = nil
    /// Z rotation (degrees) Bambu's auto-arrange applied; used to face the preview camera at the model's front.
    var arrangeRotation: Double? = nil
}

/// Wraps Bambu Studio's CLI with fully-resolved (flattened) P2S system presets.
@Observable @MainActor
final class Slicer {
    var processes: [String] = []
    var filaments: [String] = []
    var isSlicing = false
    var status = ""

    var studioApp: URL { URL(fileURLWithPath: Settings.bambuStudioPath) }
    var profilesDir: URL { studioApp.appendingPathComponent("Contents/Resources/profiles/BBL") }
    var cli: URL { studioApp.appendingPathComponent("Contents/MacOS/BambuStudio") }
    var available: Bool { FileManager.default.isExecutableFile(atPath: cli.path) }

    var machineName: String {
        Settings.nozzle == "0.4" ? "Bambu Lab P2S 0.4 nozzle" : "Bambu Lab P2S \(Settings.nozzle) nozzle"
    }

    func refreshPresets() {
        let n = Settings.nozzle
        func list(_ kind: String) -> [String] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: profilesDir.appendingPathComponent(kind).path)) ?? []
            return files.compactMap { f -> String? in
                guard f.hasSuffix(".json"), f.contains("@BBL P2S"), !f.contains("template") else { return nil }
                let name = String(f.dropLast(5))
                let isNozzleSpecific = name.hasSuffix(" nozzle")
                if n == "0.4" {
                    if isNozzleSpecific && !name.hasSuffix("P2S 0.4 nozzle") { return nil }
                } else if !name.hasSuffix("P2S \(n) nozzle") {
                    return nil
                }
                return name
            }.sorted()
        }
        processes = list("process")
        filaments = list("filament").sorted { a, b in
            let pa = a.hasPrefix("Bambu PLA"), pb = b.hasPrefix("Bambu PLA")
            return pa != pb ? pa : a < b
        }
    }

    /// Picks a preset matching an AMS tray's material, falling back to the user's chosen preset.
    func preset(forType type: String?, fallback: String) -> String {
        guard let t = type?.uppercased(), !t.isEmpty else { return fallback }
        if fallback.uppercased().contains(" \(t) ") || fallback.uppercased().hasPrefix("BAMBU \(t) ") { return fallback }
        let candidates = [
            "Bambu \(t) Basic", "Bambu \(t) HF", "Bambu \(t)", "Generic \(t)",
        ]
        for c in candidates {
            if let hit = filaments.first(where: { $0.uppercased().hasPrefix(c.uppercased() + " @BBL") }) { return hit }
        }
        return filaments.first { $0.uppercased().contains(" \(t) ") } ?? fallback
    }

    /// Resolve `inherits` chains into one flat preset dictionary.
    func flatten(kind: String, name: String) throws -> [String: Any] {
        let url = profilesDir.appendingPathComponent(kind).appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url),
              var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForgeError("Preset not found: \(kind)/\(name)")
        }
        if let parent = obj["inherits"] as? String, !parent.isEmpty {
            var base = try flatten(kind: kind, name: parent)
            base.merge(obj) { _, new in new }
            obj = base
        }
        obj.removeValue(forKey: "inherits")
        obj["from"] = "system"
        return obj
    }

    /// Bambu Studio is an AppKit app even in CLI mode. If a previous run was killed, macOS shows an invisible
    /// "reopen windows?" alert on the next launch and the CLI blocks forever. Opting it out of window
    /// restoration prevents that.
    private func guardAgainstRestoreAlert() {
        UserDefaults(suiteName: "com.bambulab.bambu-studio")?.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    /// Slices one or more filament STLs as a single assembled object (one part per filament).
    func slice(filaments parts: [SliceFilament], options o: SliceOptions, outDir: URL, outName: String) async throws -> SliceResult {
        guard available else { throw ForgeError("Bambu Studio not found at \(Settings.bambuStudioPath).") }
        guard !parts.isEmpty else { throw ForgeError("Nothing to slice.") }
        isSlicing = true; status = "Preparing presets…"
        defer { isSlicing = false; status = "" }
        guardAgainstRestoreAlert()

        let work = outDir.appendingPathComponent("slicer-input", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        var machine = try flatten(kind: "machine", name: machineName)
        machine["name"] = machineName
        var process = try flatten(kind: "process", name: o.process)
        process["enable_support"] = o.supports ? "1" : "0"
        if o.supports { process["support_type"] = o.supportType }
        process["sparse_infill_density"] = "\(o.infill)%"
        process["wall_loops"] = String(o.wallLoops)
        process["brim_type"] = o.brim ? "outer_only" : "no_brim"
        if o.brim { process["brim_width"] = "5" }
        for (k, v) in o.processOverrides { process[k] = Self.typed(v, like: process[k]) }
        if parts.count > 1 {
            // purge into sparse infill / supports instead of only the prime tower
            process["flush_into_infill"] = "1"
            process["flush_into_support"] = "1"
        }
        // Multi-colour prints need a wipe tower. The CLI's auto-arrange doesn't keep it clear of large models
        // ("gcode path conflicts found between WipeTower and assemble_1"), so place both ourselves.
        var layout: WipeTowerLayout.Plan?
        var towerNote: String?
        if parts.count > 1, let bounds = WipeTowerLayout.bounds(of: parts.map(\.stl)) {
            let plate = PrinterProfile.current
            let brim = Double(process["prime_tower_brim_width"] as? String ?? "") ?? 3
            let width = Double(process["prime_tower_width"] as? String ?? "") ?? 35
            if let plan = WipeTowerLayout.plan(model: bounds, plateX: plate.x, plateY: plate.y,
                                              towerWidth: width, brim: brim, colours: parts.count) {
                layout = plan
                process["wipe_tower_x"] = [String(format: "%.1f", plan.towerX)]
                process["wipe_tower_y"] = [String(format: "%.1f", plan.towerY)]
            } else {
                // No room beside the model: purge into infill only. Colour changes still work, with more blending.
                process["enable_prime_tower"] = "0"
                towerNote = "No room for a wipe tower beside this model, so colour changes purge into infill instead."
            }
        }

        func write(_ obj: Any, _ name: String) throws -> URL {
            let u = work.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]).write(to: u)
            return u
        }
        let mURL = try write(machine, "machine.json")
        let pURL = try write(process, "process.json")
        var filamentFiles: [String] = []
        var objects: [[String: Any]] = []
        for (i, part) in parts.enumerated() {
            var f = try flatten(kind: "filament", name: preset(forType: part.type, fallback: o.filament))
            f["filament_colour"] = [part.hex]
            for (k, v) in o.filamentOverrides { f[k] = Self.typed(v, like: f[k]) }
            filamentFiles.append(try write(f, "filament_\(i + 1).json").path)
            objects.append(["path": part.stl.path, "count": 1, "filaments": [i + 1], "assemble_index": [1],
                            "pos_x": [layout?.shiftX ?? 0], "pos_y": [layout?.shiftY ?? 0], "pos_z": [0]])
        }
        let arrange = parts.count == 1
        let assemble = try write(["plates": [["plate_name": "", "need_arrange": arrange, "objects": objects]]], "assemble.json")
        if let towerNote { status = towerNote }

        let out = outDir.appendingPathComponent(outName)
        for u in [out, outDir.appendingPathComponent("plate_1.gcode"), outDir.appendingPathComponent("plate_1.png"),
                  outDir.appendingPathComponent("result.json")] {
            try? FileManager.default.removeItem(at: u)
        }

        status = parts.count > 1 ? "Slicing \(parts.count) colours with Bambu Studio…" : "Slicing with Bambu Studio…"
        let r = await Shell.run(cli.path, [
            "--load-assemble-list", assemble.path,
            "--load-settings", "\(mURL.path);\(pURL.path)",
            "--load-filaments", filamentFiles.joined(separator: ";"),
            "--slice", "0",
            "--outputdir", outDir.path,
            "--export-3mf", outName,
        ], cwd: outDir, timeout: 300)

        let resultJSON = (try? Data(contentsOf: outDir.appendingPathComponent("result.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            if r.status == 15 || r.status == -1 {
                throw ForgeError("Bambu Studio did not finish within 5 minutes. If a Bambu Studio dialog is open, dismiss it and slice again.")
            }
            let msg = (resultJSON?["error_string"] as? String)
                ?? r.stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw ForgeError("Slicing failed (code \(r.status)): \(msg)")
        }

        status = "Finalising…"
        try await patchPrinterModel(out)
        _ = await Shell.run("/usr/bin/unzip", ["-o", "-j", out.path, "Metadata/plate_1.png", "-d", outDir.path])
        if !FileManager.default.fileExists(atPath: outDir.appendingPathComponent("plate_1.gcode").path) {
            _ = await Shell.run("/usr/bin/unzip", ["-o", "-j", out.path, "Metadata/plate_1.gcode", "-d", outDir.path])
        }

        let info = await Shell.run("/usr/bin/unzip", ["-p", out.path, "Metadata/slice_info.config"])
        let xml = String(decoding: info.stdout, as: UTF8.self)
        func meta(_ key: String) -> String? {
            guard let r = xml.range(of: "key=\"\(key)\" value=\"([^\"]*)\"", options: .regularExpression) else { return nil }
            return String(xml[r]).components(separatedBy: "value=\"").last?.replacingOccurrences(of: "\"", with: "")
        }
        func attr(_ name: String, in s: Substring) -> String? {
            guard let a = s.range(of: " \(name)=\"") else { return nil }
            return String(s[a.upperBound...].prefix { $0 != "\"" })
        }
        let filamentTags = xml.split(separator: "\n").filter { $0.contains("<filament ") }
        var uses: [FilamentUse] = []
        for tag in filamentTags {
            let id = Int(attr("id", in: tag) ?? "") ?? (uses.count + 1)
            let slot = id - 1 < parts.count ? parts[id - 1].slot : "v:\(id - 1)"
            uses.append(FilamentUse(hex: attr("color", in: tag) ?? "#888888", type: attr("type", in: tag) ?? "PLA",
                                    grams: Double(attr("used_g", in: tag) ?? "") ?? 0,
                                    meters: Double(attr("used_m", in: tag) ?? "") ?? 0, slot: slot))
        }
        // 3MF item transform is row-major "m00 m01 m02 m10 m11 m12 …": rotation angle = atan2(m01, m00)
        let model = String(decoding: (await Shell.run("/usr/bin/unzip", ["-p", out.path, "3D/3dmodel.model"])).stdout, as: UTF8.self)
        var rotation: Double? = nil
        if let r = model.range(of: "<item [^>]*transform=\"([^\"]+)\"", options: .regularExpression),
           let t = model[r].range(of: "transform=\"") {
            let nums = model[r][t.upperBound...].prefix { $0 != "\"" }.split(separator: " ").compactMap { Double($0) }
            if nums.count >= 2 { rotation = atan2(nums[1], nums[0]) * 180 / .pi }
        }
        let plates = resultJSON?["sliced_plates"] as? [[String: Any]]
        let changes = plates?.first?["filament_change_times"] as? Int
        let result = SliceResult(
            seconds: Double(meta("prediction") ?? "") ?? 0,
            weightGrams: Double(meta("weight") ?? "") ?? uses.reduce(0) { $0 + $1.grams },
            filamentMeters: uses.reduce(0) { $0 + $1.meters },
            filamentType: uses.first?.type ?? "PLA",
            filamentColor: uses.first?.hex ?? "#00AE42",
            process: o.process, filament: o.filament, slicedAt: Date(),
            filaments: uses, changes: changes ?? 0, arrangeRotation: rotation)
        try? FileManager.default.removeItem(at: work)
        return result
    }

    /// Preset values are a string or a list (one per extruder); keep the shape Bambu Studio expects.
    private static func typed(_ v: String, like old: Any?) -> Any {
        if let list = old as? [Any] { return Array(repeating: v, count: max(1, list.count)) }
        return v
    }

    /// CLI exports leave printer_model_id empty; set it to the P2S id (N7) like the GUI does.
    private func patchPrinterModel(_ threeMF: URL) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("af-\(UUID().uuidString)")
        let meta = tmp.appendingPathComponent("Metadata")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = await Shell.run("/usr/bin/unzip", ["-p", threeMF.path, "Metadata/slice_info.config"])
        var xml = String(decoding: r.stdout, as: UTF8.self)
        guard xml.contains("key=\"printer_model_id\" value=\"\"") else { return }
        xml = xml.replacingOccurrences(of: "key=\"printer_model_id\" value=\"\"", with: "key=\"printer_model_id\" value=\"N7\"")
        try xml.write(to: meta.appendingPathComponent("slice_info.config"), atomically: true, encoding: .utf8)
        _ = await Shell.run("/usr/bin/zip", ["-q", threeMF.path, "Metadata/slice_info.config"], cwd: tmp)
    }

    static func save(_ r: SliceResult, for asset: Asset) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(r).write(to: asset.sliceInfoURL)
    }

    static func loadResult(_ asset: Asset) -> SliceResult? {
        guard let d = try? Data(contentsOf: asset.sliceInfoURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SliceResult.self, from: d)
    }
}


// MARK: - Wipe tower placement

/// Finds a free spot on the plate for the wipe tower next to a multi-colour model, moving the model if needed.
enum WipeTowerLayout {
    struct Bounds { var minX, minY, maxX, maxY: Double }
    /// `shiftX/Y` move the model (mm, added to its STL coordinates); `towerX/Y` is the tower's front-left corner.
    struct Plan: Equatable { var shiftX, shiftY, towerX, towerY: Double }

    static let edge = 5.0, gap = 10.0

    /// Footprint of the tower (Bambu sizes its depth from the purge volume per colour change), including brim.
    static func footprint(width: Double, brim: Double, colours: Int) -> (w: Double, d: Double) {
        (width + 2 * brim, min(70, 18 + 9 * Double(max(1, colours - 1))) + 2 * brim)
    }

    static func plan(model b: Bounds, plateX: Double, plateY: Double, towerWidth: Double, brim: Double, colours: Int) -> Plan? {
        let (tw, td) = footprint(width: towerWidth, brim: brim, colours: colours)
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }
        // Try each side as it is, then with the model pushed to the far edge to open up that side.
        for shift in [false, true] {
            // Front (low y)
            var dy = shift ? (plateY - edge) - b.maxY : 0
            if b.minY + dy - gap - edge >= td {
                let x = clamp((b.minX + b.maxX) / 2 - tw / 2, edge, plateX - edge - tw)
                return Plan(shiftX: 0, shiftY: dy, towerX: x + brim, towerY: edge + brim)
            }
            // Back (high y)
            dy = shift ? edge - b.minY : 0
            if plateY - edge - (b.maxY + dy) - gap >= td {
                let x = clamp((b.minX + b.maxX) / 2 - tw / 2, edge, plateX - edge - tw)
                return Plan(shiftX: 0, shiftY: dy, towerX: x + brim, towerY: b.maxY + dy + gap + brim)
            }
            // Left (low x)
            var dx = shift ? (plateX - edge) - b.maxX : 0
            if b.minX + dx - gap - edge >= tw {
                let y = clamp((b.minY + b.maxY) / 2 - td / 2, edge, plateY - edge - td)
                return Plan(shiftX: dx, shiftY: 0, towerX: edge + brim, towerY: y + brim)
            }
            // Right (high x)
            dx = shift ? edge - b.minX : 0
            if plateX - edge - (b.maxX + dx) - gap >= tw {
                let y = clamp((b.minY + b.maxY) / 2 - td / 2, edge, plateY - edge - td)
                return Plan(shiftX: dx, shiftY: 0, towerX: b.maxX + dx + gap + brim, towerY: y + brim)
            }
        }
        return nil
    }

    /// Combined XY bounds of binary STL files.
    static func bounds(of urls: [URL]) -> Bounds? {
        var b = Bounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for url in urls {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 84 else { continue }
            data.withUnsafeBytes { raw in
                let n = Int(raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
                guard data.count >= 84 + n * 50 else { return }
                for i in 0..<n {
                    let base = 84 + i * 50 + 12
                    for v in 0..<3 {
                        let x = Double(raw.loadUnaligned(fromByteOffset: base + v * 12, as: Float32.self))
                        let y = Double(raw.loadUnaligned(fromByteOffset: base + v * 12 + 4, as: Float32.self))
                        b.minX = min(b.minX, x); b.maxX = max(b.maxX, x)
                        b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
                    }
                }
            }
        }
        return b.minX.isFinite ? b : nil
    }
}
