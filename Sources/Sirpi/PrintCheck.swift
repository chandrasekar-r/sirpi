import Foundation

// MARK: - Print check: predicts print problems from the mesh and the sliced G-code

/// One thing that may go wrong, why, and what fixes it.
struct PrintFinding: Codable, Identifiable, Hashable {
    enum Defect: String, Codable, CaseIterable {
        case mesh, supports, overhang, bridging, warping, detaching, collapsing, underExtrusion, stringing, gloss, cracking, belt

        var name: String {
            switch self {
            case .mesh: "STL file"
            case .supports: "Supports"
            case .overhang: "Overhang quality"
            case .bridging: "Bridging"
            case .warping: "Warping"
            case .detaching: "Coming off the plate"
            case .collapsing: "Collapsing or wobbling"
            case .underExtrusion: "Under-extrusion"
            case .stringing: "Stringing and oozing"
            case .gloss: "Uneven gloss"
            case .cracking: "Layer cracking"
            case .belt: "Belt pattern"
            }
        }
    }
    enum Severity: Int, Codable, Comparable {
        case info, warn, risk
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var defect: Defect
    var severity: Severity
    var title: String
    var detail: String
    var fixes: [PrintFix] = []
    /// Set for findings written by an AI reviewer.
    var source: String? = nil
}

/// A fix is either slicer settings (applied, then re-sliced) or a request to the model that wrote the asset.
struct PrintFix: Codable, Hashable, Identifiable {
    var id: String { label }
    var label: String
    /// Keys: "supports" (auto, tree(auto), normal(auto), off), "brim" (1/0), "wallLoops", "infill",
    /// "p.<key>" (process preset value) and "f.<key>" (filament preset value).
    var settings: [String: String]? = nil
    var refine: String? = nil
}

struct PrintReport: Codable {
    var findings: [PrintFinding]
    var mesh: MeshStats?
    var gcode: GcodeStats?
    var material: String
    var checkedAt: Date
    var aiSummary: String? = nil
    var health: MeshHealth? = nil

    var worst: PrintFinding.Severity? { findings.map(\.severity).max() }
}

// MARK: - Mesh

struct MeshStats: Codable {
    struct Island: Codable, Hashable { var x, y, z, gap: Double }
    struct Band: Codable, Hashable { var from, to, area: Double }

    var height = 0.0, sizeX = 0.0, sizeY = 0.0
    var surfaceArea = 0.0
    var contactArea = 0.0
    /// Downward surfaces steeper than 60° from vertical, which Bambu's default supports would hold up.
    var steepArea = 0.0
    /// Downward surfaces between 45° and 60° from vertical: print without supports, but rough.
    var roughArea = 0.0
    /// Steep downward area per height band, largest first.
    var steepBands: [Band] = []
    var roughBands: [Band] = []
    /// Points where the model starts in mid-air (nothing below), lowest point of each.
    var islands: [Island] = []
    var verticalArea = 0.0
    var triangles = 0

    /// True when the slice would print badly or fail without supports.
    var needsSupports: Bool { !islands.isEmpty || steepArea >= 30 }
}

enum MeshCheck {
    private struct Tri { var a, b, c: SIMD3<Double>; var part: Int }

    private static func readSTL(_ url: URL, part: Int, into tris: inout [Tri]) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 84 else { return }
        data.withUnsafeBytes { raw in
            let n = Int(raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
            guard data.count >= 84 + n * 50 else { return }
            tris.reserveCapacity(tris.count + n)
            for i in 0..<n {
                let base = 84 + i * 50 + 12
                func v(_ k: Int) -> SIMD3<Double> {
                    SIMD3(Double(raw.loadUnaligned(fromByteOffset: base + k * 12, as: Float32.self)),
                          Double(raw.loadUnaligned(fromByteOffset: base + k * 12 + 4, as: Float32.self)),
                          Double(raw.loadUnaligned(fromByteOffset: base + k * 12 + 8, as: Float32.self)))
                }
                tris.append(Tri(a: v(0), b: v(1), c: v(2), part: part))
            }
        }
    }

    /// Analyses binary STLs in printing orientation (Z up, millimetres). Each file is one closed part.
    static func analyse(_ urls: [URL]) -> MeshStats? {
        var tris: [Tri] = []
        for (i, u) in urls.enumerated() { readSTL(u, part: i, into: &tris) }
        guard !tris.isEmpty else { return nil }

        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for t in tris { for p in [t.a, t.b, t.c] { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) } }
        var s = MeshStats()
        s.triangles = tris.count
        s.height = hi.z - lo.z; s.sizeX = hi.x - lo.x; s.sizeY = hi.y - lo.y
        let bed = lo.z

        let band = max(2.0, (s.height / 12).rounded())
        var steepBins: [Int: Double] = [:], roughBins: [Int: Double] = [:]
        var normals = [SIMD3<Double>](repeating: .zero, count: tris.count)
        for (i, t) in tris.enumerated() {
            let c = cross(t.b - t.a, t.c - t.a)
            let len = (c * c).sum().squareRoot()
            guard len > 1e-12 else { continue }
            let area = len / 2, n = c / len
            normals[i] = n
            s.surfaceArea += area
            if abs(n.z) < 0.05 { s.verticalArea += area }
            let top = max(t.a.z, t.b.z, t.c.z)
            if n.z < -0.98 && top <= bed + 0.3 { s.contactArea += area; continue }
            let cz = (t.a.z + t.b.z + t.c.z) / 3
            guard n.z < 0, cz > bed + 0.4 else { continue }
            let angle = asin(min(1, -n.z)) * 180 / .pi       // 0 = vertical wall, 90 = flat ceiling
            let bin = Int((cz - bed) / band)
            if angle > 60 { s.steepArea += area; steepBins[bin, default: 0] += area }
            else if angle > 45 { s.roughArea += area; roughBins[bin, default: 0] += area }
        }
        func bands(_ bins: [Int: Double]) -> [MeshStats.Band] {
            bins.filter { $0.value >= 5 }.sorted { $0.value > $1.value }.prefix(3)
                .map { MeshStats.Band(from: Double($0.key) * band, to: Double($0.key + 1) * band, area: $0.value) }
        }
        s.steepBands = bands(steepBins); s.roughBands = bands(roughBins)
        s.islands = islands(tris, normals: normals, bed: bed)
        return s
    }

    /// Lowest points of regions that face down with nothing under them: each needs support or it prints in mid-air.
    private static func islands(_ tris: [Tri], normals: [SIMD3<Double>], bed: Double) -> [MeshStats.Island] {
        // Weld vertices so neighbours can be found.
        var index: [SIMD3<Int>: Int] = [:]
        var pos: [SIMD3<Double>] = []
        var down: [Double] = []           // area-weighted normal z of incident faces
        var neighbours: [[Int]] = []
        func key(_ p: SIMD3<Double>) -> SIMD3<Int> { SIMD3(Int((p.x * 100).rounded()), Int((p.y * 100).rounded()), Int((p.z * 100).rounded())) }
        func vid(_ p: SIMD3<Double>) -> Int {
            let k = key(p)
            if let i = index[k] { return i }
            index[k] = pos.count; pos.append(p); down.append(0); neighbours.append([])
            return pos.count - 1
        }
        for (i, t) in tris.enumerated() {
            let ids = [vid(t.a), vid(t.b), vid(t.c)]
            for j in 0..<3 {
                down[ids[j]] += normals[i].z
                neighbours[ids[j]].append(ids[(j + 1) % 3]); neighbours[ids[j]].append(ids[(j + 2) % 3])
            }
        }
        // A local minimum is a flat patch (often one vertex) with no lower neighbour anywhere around it. The flat
        // underside of an arm is not one: its edge joins a wall that goes down to the plate.
        var minima: [Int] = []
        var visited = [Bool](repeating: false, count: pos.count)
        for v in 0..<pos.count where !visited[v] && pos[v].z > bed + 0.5 && down[v] < 0 {
            let z = pos[v].z
            var plateau = [v], stack = [v], lower = false
            visited[v] = true
            while let u = stack.popLast(), !lower {
                for w in neighbours[u] {
                    let wz = pos[w].z
                    if wz < z - 1e-3 { lower = true; break }
                    if wz <= z + 1e-3 && !visited[w] { visited[w] = true; plateau.append(w); stack.append(w) }
                }
                if plateau.count > 20000 { lower = true }
            }
            if !lower { minima.append(plateau.min { pos[$0].x + pos[$0].y < pos[$1].x + pos[$1].y } ?? v) }
        }
        guard !minima.isEmpty else { return [] }

        // A flat underside is many minima at one height: keep one per 3 mm cell.
        var seen = Set<SIMD3<Int>>()
        var candidates: [SIMD3<Double>] = []
        for v in minima.sorted(by: { pos[$0].z < pos[$1].z }) {
            let p = pos[v]
            let cell = SIMD3(Int(floor(p.x / 3)), Int(floor(p.y / 3)), Int(floor(p.z / 3)))
            if seen.insert(cell).inserted { candidates.append(p) }
            if candidates.count >= 400 { break }
        }

        // XY grid of triangles for downward rays.
        let cell = 4.0
        var grid: [SIMD2<Int>: [Int]] = [:]
        for (i, t) in tris.enumerated() {
            let x0 = Int(floor(min(t.a.x, t.b.x, t.c.x) / cell)), x1 = Int(floor(max(t.a.x, t.b.x, t.c.x) / cell))
            let y0 = Int(floor(min(t.a.y, t.b.y, t.c.y) / cell)), y1 = Int(floor(max(t.a.y, t.b.y, t.c.y) / cell))
            guard (x1 - x0 + 1) * (y1 - y0 + 1) <= 400 else { continue }
            for x in x0...x1 { for y in y0...y1 { grid[SIMD2(x, y), default: []].append(i) } }
        }
        let parts = (tris.map(\.part).max() ?? 0) + 1

        var found: [MeshStats.Island] = []
        for p in candidates {
            // Nudge sideways so the ray doesn't run exactly along an edge.
            let o = SIMD3(p.x + 0.0137, p.y + 0.0091, p.z - 0.05)
            var crossings = [Int](repeating: 0, count: parts)
            var nearest = bed
            for i in grid[SIMD2(Int(floor(o.x / cell)), Int(floor(o.y / cell)))] ?? [] {
                let t = tris[i]
                guard let z = rayDownHit(o, t.a, t.b, t.c), z < o.z else { continue }
                crossings[t.part] += 1
                nearest = max(nearest, z)
            }
            // Inside another part (an eye set into a head): held up by that part.
            if crossings.contains(where: { $0 % 2 == 1 }) { continue }
            let gap = p.z - nearest
            if gap > 0.6 { found.append(.init(x: p.x, y: p.y, z: p.z - bed, gap: gap)) }
        }
        // Merge islands closer than 5 mm into one.
        var merged: [MeshStats.Island] = []
        for i in found where !merged.contains(where: { abs($0.x - i.x) < 5 && abs($0.y - i.y) < 5 && abs($0.z - i.z) < 5 }) {
            merged.append(i)
        }
        return merged
    }

    /// Z where a vertical line through (o.x, o.y) meets the triangle, if it does.
    private static func rayDownHit(_ o: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double? {
        let d1 = (b.x - a.x) * (o.y - a.y) - (b.y - a.y) * (o.x - a.x)
        let d2 = (c.x - b.x) * (o.y - b.y) - (c.y - b.y) * (o.x - b.x)
        let d3 = (a.x - c.x) * (o.y - c.y) - (a.y - c.y) * (o.x - c.x)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        guard !(neg && pos) else { return nil }
        let n = cross(b - a, c - a)
        guard abs(n.z) > 1e-12 else { return nil }
        return a.z - (n.x * (o.x - a.x) + n.y * (o.y - a.y)) / n.z
    }

    private static func cross(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
    }
}

// MARK: - G-code

struct GcodeStats: Codable {
    var layers = 0
    var longestBridge = 0.0
    var longestBridgeZ = 0.0
    var bridgeLength = 0.0
    var overhangWallLength = 0.0
    var overhangWallFrom = 0.0, overhangWallTo = 0.0
    var supportLength = 0.0
    /// Share of wall printing time spent within 10% of the filament's melt limit.
    var nearFlowLimit = 0.0
    var flowLimit = 0.0
    var peakFlow = 0.0
    /// Outer-wall length printed well below the set outer wall speed (layer cooling slow-downs).
    var slowOuterWallShare = 0.0
    var slowFrom = 0.0, slowTo = 0.0
    var outerWallSpeed = 0.0
    var travelsPerLayer = 0.0
    var firstLayerArea = 0.0
    var settings: [String: String] = [:]
}

enum GcodeCheck {
    static let filamentArea = Double.pi * 0.875 * 0.875   // 1.75 mm filament

    static func analyse(_ url: URL) -> GcodeStats? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }
        var s = GcodeStats()
        var x = 0.0, y = 0.0, z = 0.0, f = 0.0
        var feature = ""
        var layer = 0
        var travels = 0
        var extrudeTime = 0.0, nearLimitTime = 0.0
        var outerLen = 0.0, slowOuterLen = 0.0
        var slowZs: [Double] = []
        var firstLayerExtruded = 0.0
        var lineWidth = 0.42
        var inConfig = false

        func num(_ s: Substring) -> Double? { Double(s) }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var start = 0
            let n = raw.count
            while start < n {
                var end = start
                while end < n && raw[end] != 0x0A { end += 1 }
                let line = String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<end]), as: UTF8.self)
                start = end + 1
                guard let c = line.first else { continue }

                if c == ";" {
                    if line.hasPrefix("; FEATURE: ") { feature = String(line.dropFirst(11)) }
                    else if line.hasPrefix("; CHANGE_LAYER") { layer += 1 }
                    else if line.hasPrefix("; Z_HEIGHT: ") { z = Double(line.dropFirst(12)) ?? z }
                    else if line.hasPrefix("; LINE_WIDTH: ") { lineWidth = Double(line.dropFirst(14)) ?? lineWidth }
                    else if line.hasPrefix("; CONFIG_BLOCK_START") { inConfig = true }
                    else if line.hasPrefix("; CONFIG_BLOCK_END") { inConfig = false }
                    else if inConfig, let eq = line.range(of: " = ") {
                        s.settings[String(line[line.index(line.startIndex, offsetBy: 2)..<eq.lowerBound])] = String(line[eq.upperBound...])
                    }
                    continue
                }
                guard c == "G", line.hasPrefix("G1 ") || line.hasPrefix("G0 ") || line.hasPrefix("G2 ") || line.hasPrefix("G3 ") else { continue }
                let arc = line.hasPrefix("G2 ") || line.hasPrefix("G3 ")
                var nx = x, ny = y, e = 0.0, ci = 0.0, cj = 0.0
                // Bambu appends comments without a space ("G1 F3000;_EXTRUDE_SET_SPEED").
                let code = line.dropFirst(3).prefix { $0 != ";" }
                for word in code.split(separator: " ") {
                    guard let k = word.first else { continue }
                    let v = num(word.dropFirst())
                    switch k {
                    case "X": nx = v ?? nx
                    case "Y": ny = v ?? ny
                    case "F": f = v ?? f
                    case "E": e = v ?? 0
                    case "I": ci = v ?? 0
                    case "J": cj = v ?? 0
                    default: break
                    }
                }
                var len = ((nx - x) * (nx - x) + (ny - y) * (ny - y)).squareRoot()
                if arc && (ci != 0 || cj != 0) {
                    // Arc length around the centre (x + I, y + J); G2 turns clockwise, G3 anticlockwise.
                    let cx = x + ci, cy = y + cj, r = (ci * ci + cj * cj).squareRoot()
                    var sweep = atan2(ny - cy, nx - cx) - atan2(y - cy, x - cx)
                    if line.hasPrefix("G2 ") { if sweep >= 0 { sweep -= 2 * .pi } } else if sweep <= 0 { sweep += 2 * .pi }
                    len = abs(sweep) * r
                }
                x = nx; y = ny
                guard len > 0, layer > 0 else { continue }
                if e <= 0 {
                    if len > 2 { travels += 1 }
                    continue
                }
                let speed = f / 60                     // mm/s
                let t = speed > 0 ? len / speed : 0
                let flow = e * filamentArea / len * speed   // mm³/s
                // Walls are where thin extrusion shows; infill runs at the limit by design.
                let wall = feature == "Outer wall" || feature == "Inner wall"
                if wall { extrudeTime += t }
                if len > 1 { s.peakFlow = max(s.peakFlow, flow) }
                if layer == 1 { firstLayerExtruded += len * lineWidth }
                switch feature {
                case "Bridge":
                    s.bridgeLength += len
                    if len > s.longestBridge { s.longestBridge = len; s.longestBridgeZ = z }
                case "Overhang wall":
                    if s.overhangWallLength == 0 { s.overhangWallFrom = z }
                    s.overhangWallLength += len; s.overhangWallTo = z
                case "Support", "Support interface", "Support transition":
                    s.supportLength += len
                case "Outer wall":
                    outerLen += len
                    if s.outerWallSpeed > 0 && speed < s.outerWallSpeed * 0.6 && len > 1 { slowOuterLen += len; slowZs.append(z) }
                default: break
                }
                if wall && len > 1 && s.flowLimit > 0 && flow >= s.flowLimit * 0.9 { nearLimitTime += t }
                // Config comes first in the file, so these are known once printing starts.
                if s.outerWallSpeed == 0, let v = s.settings["outer_wall_speed"].flatMap(GcodeCheck.first) { s.outerWallSpeed = v }
                if s.flowLimit == 0, let v = s.settings["filament_max_volumetric_speed"].flatMap(GcodeCheck.first) { s.flowLimit = v }
            }
        }
        s.layers = layer
        s.travelsPerLayer = layer > 0 ? Double(travels) / Double(layer) : 0
        s.nearFlowLimit = extrudeTime > 0 ? nearLimitTime / extrudeTime : 0
        s.slowOuterWallShare = outerLen > 0 ? slowOuterLen / outerLen : 0
        if let lo = slowZs.min(), let hi = slowZs.max() { s.slowFrom = lo; s.slowTo = hi }
        s.firstLayerArea = firstLayerExtruded
        return s
    }

    /// First number of a preset value like "200" or "12,12" or "50%".
    static func first(_ v: String) -> Double? {
        Double(v.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " %")) } ?? "")
    }
}

// MARK: - Rules

enum PrintRules {
    struct Context {
        var mesh: MeshStats?
        var gcode: GcodeStats?
        var material: String           // PLA, PETG, ABS…
        var filamentPreset: String
        var supportMode: String        // what the user picked
        var supportsOn: Bool           // what was sliced
        var brim: Bool
        var noSupportsWanted: Bool     // the brief asked to design for printing without supports
    }

    static func material(fromPreset preset: String) -> String {
        let words = preset.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for w in words {
            if ["PLA", "PETG", "ABS", "ASA", "TPU", "PC", "PVA", "HIPS"].contains(w) { return w }
            if w == "PA" || w == "PAHT" || w == "PPA" || (w.hasPrefix("PA") && w.dropFirst(2).allSatisfy(\.isNumber)) { return "PA" }
        }
        return "PLA"
    }

    static func findings(_ c: Context) -> [PrintFinding] {
        var out: [PrintFinding] = []
        let m = c.mesh, g = c.gcode
        let hot = ["ABS", "ASA", "PA", "PC"].contains(c.material)
        func mm(_ v: Double) -> String { String(format: "%.0f mm", v) }
        func at(_ z: Double) -> String {
            guard let h = m?.height, h > 0 else { return "at \(mm(z))" }
            let share = z / h
            let where_ = share < 0.25 ? "near the bottom" : share < 0.6 ? "around the middle" : share < 0.85 ? "in the upper part" : "near the top"
            return "\(where_) (\(mm(z)) up)"
        }

        // Supports and overhangs
        if let m {
            let steepWhere = m.steepBands.first.map { at(($0.from + $0.to) / 2) } ?? ""
            if !m.islands.isEmpty || m.steepArea >= 30 {
                var why: [String] = []
                if !m.islands.isEmpty {
                    let list = m.islands.prefix(3).map { at($0.z) }.joined(separator: ", ")
                    why.append("\(m.islands.count) part\(m.islands.count == 1 ? " starts" : "s start") in mid-air: \(list)")
                }
                if m.steepArea >= 30 { why.append(String(format: "%.0f mm² of underside is steeper than 60°, mostly %@", m.steepArea, steepWhere)) }
                let reshape = PrintFix(label: "Reshape the model", refine: refineText(m, c))
                if c.supportsOn {
                    let sev: PrintFinding.Severity = c.noSupportsWanted ? .warn : .info
                    out.append(PrintFinding(id: "supports", defect: .supports, severity: sev, title: "Supports are on because this model needs them",
                                            detail: why.joined(separator: ". ") + "." + (c.noSupportsWanted ? " The brief asked for a model that prints without supports, so reshaping it is the better fix." : " Reshaping the model would save support material and clean-up."),
                                            fixes: [reshape]))
                } else {
                    out.append(PrintFinding(id: "supports", defect: .supports, severity: .risk, title: "This will print in mid-air without supports",
                                            detail: why.joined(separator: ". ") + ".",
                                            fixes: [PrintFix(label: "Turn on supports", settings: ["supports": "tree(auto)"]), reshape]))
                }
            } else if c.supportsOn && c.supportMode != "auto" {
                out.append(PrintFinding(id: "supports", defect: .supports, severity: .info, title: "Supports aren't needed",
                                        detail: "Nothing starts in mid-air and no underside is steeper than 60°. Turning supports off saves material and clean-up.",
                                        fixes: [PrintFix(label: "Supports: automatic", settings: ["supports": "auto"])]))
            } else if c.supportMode == "auto" {
                out.append(PrintFinding(id: "supports", defect: .supports, severity: .info, title: "No supports needed",
                                        detail: "Nothing starts in mid-air and no underside is steeper than 60°, so supports are off."))
            }

            if m.roughArea >= 150 || (!c.supportsOn && m.steepArea >= 10 && m.islands.isEmpty) || (g?.overhangWallLength ?? 0) > 400 {
                let bandText = m.roughBands.first.map { at(($0.from + $0.to) / 2) } ?? steepWhere
                out.append(PrintFinding(id: "overhang", defect: .overhang, severity: m.roughArea >= 600 ? .warn : .info,
                                        title: "Some undersides will print rough",
                                        detail: String(format: "%.0f mm² of underside leans out between 45° and 60°, mostly %@. Each layer hangs over the one below, so the underside droops and curls.", m.roughArea, bandText),
                                        fixes: [PrintFix(label: "Slow down overhangs", settings: ["p.overhang_3_4_speed": "15", "p.overhang_4_4_speed": "8"]),
                                                PrintFix(label: "Reshape the model", refine: refineText(m, c, overhangOnly: true))]))
            }
        }

        // Bridges
        if let g, g.longestBridge > 15 {
            let long = g.longestBridge
            out.append(PrintFinding(id: "bridging", defect: .bridging, severity: long > 40 ? .warn : .info,
                                    title: String(format: "%.0f mm bridge %@", long, at(g.longestBridgeZ)),
                                    detail: "Filament is stretched across open air there. Bridges longer than about 30 mm sag and the strands can droop or snap.",
                                    fixes: long > 30 ? [PrintFix(label: "Slower, thicker bridges", settings: ["p.bridge_speed": "25", "p.thick_bridges": "1"]),
                                                        PrintFix(label: "Add supports", settings: ["supports": "tree(auto)"])]
                                                     : [PrintFix(label: "Slower bridges", settings: ["p.bridge_speed": "30"])]))
        }

        // Plate adhesion, warping, toppling
        if let m {
            let footprint = max(m.sizeX, m.sizeY)
            let contact = max(m.contactArea, g?.firstLayerArea ?? 0)
            let slender = m.height / max(1, contact.squareRoot())
            if contact < 25 || slender > 8 {
                out.append(PrintFinding(id: "detaching", defect: .detaching, severity: contact < 25 || slender > 12 ? .risk : .warn,
                                        title: String(format: "Only %.0f mm² touches the plate", contact),
                                        detail: "The model is \(mm(m.height)) tall on a small base. The nozzle can knock it loose as it gets taller.",
                                        fixes: c.brim ? [PrintFix(label: "Widen the base", refine: "Print fix: the model only touches the build plate with about \(Int(contact)) mm² and may come loose while printing. Give it a wider flat base or foot (at least 20 mm across) resting on the ground, without changing the rest of the design.")]
                                                      : [PrintFix(label: "Add a brim", settings: ["brim": "1", "p.brim_width": "8"]),
                                                         PrintFix(label: "Widen the base", refine: "Print fix: the model only touches the build plate with about \(Int(contact)) mm² and may come loose while printing. Give it a wider flat base or foot (at least 20 mm across) resting on the ground, without changing the rest of the design.")]))
            }
            let warpSize: Double = hot ? 80 : c.material == "PETG" ? 150 : 200
            if footprint > warpSize && m.contactArea > 400 {
                var fixes = c.brim ? [] : [PrintFix(label: "Add a brim", settings: ["brim": "1", "p.brim_width": "6"])]
                if hot { fixes.append(PrintFix(label: "Less part cooling", settings: ["f.fan_max_speed": "25", "f.fan_min_speed": "10"])) }
                out.append(PrintFinding(id: "warping", defect: .warping, severity: hot ? .risk : .warn,
                                        title: "\(mm(footprint)) long base in \(c.material) may lift at the corners",
                                        detail: hot ? "\(c.material) shrinks as it cools, and long flat bases pull up at the corners. Keep the door and lid closed and let the chamber warm up before printing."
                                                    : "Long flat bases can pull up at the corners as they cool. Clean the plate with soap and water and use glue on smooth plates.",
                                        fixes: fixes))
            }
            let thinnest = min(m.sizeX, m.sizeY)
            if m.height > 50 && m.height > thinnest * 5 {
                out.append(PrintFinding(id: "collapsing", defect: .collapsing, severity: m.height > thinnest * 8 ? .warn : .info,
                                        title: "Tall and thin: \(mm(m.height)) high, \(mm(thinnest)) wide",
                                        detail: "The top sways as the head moves, which leaves wobbly layers or snaps it off.",
                                        fixes: [PrintFix(label: "Slower and more walls", settings: ["wallLoops": "3", "p.outer_wall_speed": "120", "p.inner_wall_speed": "150", "p.sparse_infill_speed": "150"])]
                                            + (c.brim ? [] : [PrintFix(label: "Add a brim", settings: ["brim": "1", "p.brim_width": "8"])])))
            }
        }

        if let g {
            // Melt limit
            // Bambu's own presets are tuned to run walls at the limit; other filaments may not melt that fast.
            if g.nearFlowLimit > 0.5 && g.flowLimit > 0 && !c.filamentPreset.hasPrefix("Bambu ") {
                let lower = max(6, (g.flowLimit * 0.75).rounded())
                out.append(PrintFinding(id: "underExtrusion", defect: .underExtrusion, severity: .warn,
                                        title: String(format: "%.0f%% of the walls print at the melt limit", g.nearFlowLimit * 100),
                                        detail: String(format: "The hotend melts at most %.0f mm³/s of this filament, and the walls are printed close to that. That limit comes from a generic preset, so if this filament melts slower the walls come out thin and gappy.", g.flowLimit),
                                        fixes: [PrintFix(label: String(format: "Cap flow at %.0f mm³/s", lower), settings: ["f.filament_max_volumetric_speed": String(format: "%.0f", lower)])]))
            }
            // Stringing
            let stringy = ["PETG", "TPU"].contains(c.material)
            let travelLimit: Double = stringy ? 15 : 80
            if g.travelsPerLayer > travelLimit {
                var fixes: [PrintFix] = []
                if g.settings["reduce_crossing_wall"] != "1" { fixes.append(PrintFix(label: "Avoid crossing walls", settings: ["p.reduce_crossing_wall": "1"])) }
                out.append(PrintFinding(id: "stringing", defect: .stringing, severity: stringy ? .warn : .info,
                                        title: String(format: "%.0f jumps between parts per layer", g.travelsPerLayer),
                                        detail: "Every jump across open air can leave a thin string, worse with \(c.material == "PLA" ? "damp filament" : c.material). Dry the filament if it has been out for a while.",
                                        fixes: fixes))
            }
            // Gloss
            if g.slowOuterWallShare > 0.08 && g.slowOuterWallShare < 0.92 && g.outerWallSpeed > 0 {
                out.append(PrintFinding(id: "gloss", defect: .gloss, severity: .info,
                                        title: "Outer walls change speed \(g.slowFrom == g.slowTo ? at(g.slowFrom) : "between \(mm(g.slowFrom)) and \(mm(g.slowTo)) up")",
                                        detail: String(format: "%.0f%% of the outer wall prints slower than the rest, mostly on small layers that have to wait for cooling. Speed changes show as shiny and matte bands.", g.slowOuterWallShare * 100),
                                        fixes: [PrintFix(label: "Even out wall speed", settings: ["p.outer_wall_speed": String(format: "%.0f", max(60, min(g.outerWallSpeed, 120))), "f.slow_down_layer_time": "4"])]))
            }
        }

        // Layer bonding
        if hot, let m, m.height > 30 {
            out.append(PrintFinding(id: "cracking", defect: .cracking, severity: m.height > 80 ? .warn : .info,
                                    title: "\(c.material) layers may split on a \(mm(m.height)) tall print",
                                    detail: "Tall \(c.material) parts crack between layers when the upper layers cool too fast. Keep the door and lid closed for the whole print.",
                                    fixes: [PrintFix(label: "Less part cooling", settings: ["f.fan_max_speed": "20", "f.fan_min_speed": "0"])]))
        }

        // Belt pattern: printer hardware, shown only where it is most visible.
        if let m, let g, m.verticalArea > 3000 && g.outerWallSpeed > 150 {
            out.append(PrintFinding(id: "belt", defect: .belt, severity: .info, title: "Large flat walls show belt patterns most",
                                    detail: "Evenly spaced vertical lines on flat walls come from the printer's belts, not the slice. If you see them, check belt tension and run the printer's calibration. Slower outer walls make them fainter.",
                                    fixes: [PrintFix(label: "Slower outer walls", settings: ["p.outer_wall_speed": "120"])]))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    /// What the STL check fixed, or what is still broken.
    static func stlFinding(_ h: MeshHealth, passthrough: Int, repairOn: Bool) -> PrintFinding? {
        if !h.watertight {
            var detail = "After repair, \(h.openEdges) edge\(h.openEdges == 1 ? " is" : "s are") still open and \(h.nonManifoldEdges) \(h.nonManifoldEdges == 1 ? "is" : "are") shared by more than two faces."
            detail += " Bambu Studio fills small gaps itself, but missing walls or layers can still show up in the slice."
            if passthrough > 0 { detail += " \(passthrough) part\(passthrough == 1 ? "" : "s") could not be merged into a solid and \(passthrough == 1 ? "was" : "were") passed through as they are." }
            let fixes = repairOn ? [PrintFix(label: "Rebuild as one solid", refine: "Print fix: the exported mesh is not watertight (open or shared edges). Build every part as a closed solid and let parts overlap so they fuse; do not leave open shapes such as planes or single-sided surfaces.")]
                                 : [PrintFix(label: "Turn on Repair for printing", settings: ["repair": "1"])]
            return PrintFinding(id: "mesh", defect: .mesh, severity: .warn, title: "The STL still has holes", detail: detail, fixes: fixes)
        }
        if h.repaired {
            return PrintFinding(id: "mesh", defect: .mesh, severity: .info, title: "STL repaired",
                                detail: "Sirpi " + h.fixesText + ". The model is now watertight; the repaired files are the ones sliced and exported.")
        }
        return nil
    }

    /// The refinement request for the model that wrote the asset, in its own terms (Y up, millimetres).
    static func refineText(_ m: MeshStats, _ c: Context, overhangOnly: Bool = false) -> String {
        func pct(_ z: Double) -> Int { m.height > 0 ? Int((z / m.height * 100).rounded()) : 0 }
        var lines: [String] = []
        if !overhangOnly {
            for i in m.islands.prefix(4) {
                lines.append(String(format: "- Something starts in mid-air about %d%% of the way up (%.0f mm, %.0f mm above whatever is below it). Connect it to the part below or give it a support built into the design.", pct(i.z), i.z, i.gap))
            }
            for b in m.steepBands.prefix(2) {
                lines.append(String(format: "- About %.0f mm² of underside between %d%% and %d%% of the height is close to flat. Angle it to 45° or less from vertical (a chamfer, cone or curved brace).", b.area, pct(b.from), pct(b.to)))
            }
        }
        for b in m.roughBands.prefix(2) {
            lines.append(String(format: "- The underside between %d%% and %d%% of the height leans out more than 45°. Make it steeper (45° or less from vertical).", pct(b.from), pct(b.to)))
        }
        if lines.isEmpty { lines.append("- Keep every underside within 45° of vertical and make sure nothing starts in mid-air.") }
        return "Print fix: make this print cleanly without supports. Heights are measured from the ground (y = 0) up to the top.\n"
            + lines.joined(separator: "\n")
            + "\nKeep the look, size and everything else the same."
    }
}
