import Foundation

// MARK: - STL verification and repair

/// What the STL check found and fixed. A watertight, consistently oriented mesh has no open or non-manifold edges.
struct MeshHealth: Codable, Hashable {
    var triangles = 0
    var shells = 0
    var degenerateRemoved = 0
    var duplicatesRemoved = 0
    var flippedFaces = 0
    var invertedShells = 0
    var holesFilled = 0
    /// Left after repair.
    var openEdges = 0
    var nonManifoldEdges = 0

    var repaired: Bool { degenerateRemoved + duplicatesRemoved + flippedFaces + invertedShells + holesFilled > 0 }
    var watertight: Bool { openEdges == 0 && nonManifoldEdges == 0 }

    mutating func add(_ o: MeshHealth) {
        triangles += o.triangles; shells += o.shells; degenerateRemoved += o.degenerateRemoved
        duplicatesRemoved += o.duplicatesRemoved; flippedFaces += o.flippedFaces; invertedShells += o.invertedShells
        holesFilled += o.holesFilled; openEdges += o.openEdges; nonManifoldEdges += o.nonManifoldEdges
    }

    /// "closed 3 holes, turned 120 faces the right way out"
    var fixesText: String {
        var parts: [String] = []
        if holesFilled > 0 { parts.append("closed \(holesFilled) hole\(holesFilled == 1 ? "" : "s")") }
        if flippedFaces > 0 { parts.append("turned \(flippedFaces) face\(flippedFaces == 1 ? "" : "s") the right way") }
        if invertedShells > 0 { parts.append("turned \(invertedShells) inside-out part\(invertedShells == 1 ? "" : "s") right side out") }
        let junk = degenerateRemoved + duplicatesRemoved
        if junk > 0 { parts.append("removed \(junk) empty or duplicate face\(junk == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

enum MeshRepair {
    typealias V = SIMD3<Float>

    /// Checks a binary STL and returns a repaired copy (or the original when nothing needed fixing).
    static func repair(_ data: Data) -> (data: Data, health: MeshHealth) {
        guard data.count >= 84 else { return (data, MeshHealth()) }
        var health = MeshHealth()

        // Read and weld vertices (to 1 µm) so shared edges can be found.
        var verts: [V] = []
        var index: [SIMD3<Int32>: Int32] = [:]
        var faces: [SIMD3<Int32>] = []
        data.withUnsafeBytes { raw in
            let n = Int(raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
            guard data.count >= 84 + n * 50 else { return }
            faces.reserveCapacity(n)
            func vid(_ p: V) -> Int32 {
                let k = SIMD3<Int32>(Int32((p.x * 1000).rounded()), Int32((p.y * 1000).rounded()), Int32((p.z * 1000).rounded()))
                if let i = index[k] { return i }
                let i = Int32(verts.count); index[k] = i; verts.append(p); return i
            }
            for i in 0..<n {
                let b = 84 + i * 50 + 12
                func v(_ k: Int) -> V {
                    V(raw.loadUnaligned(fromByteOffset: b + k * 12, as: Float32.self),
                      raw.loadUnaligned(fromByteOffset: b + k * 12 + 4, as: Float32.self),
                      raw.loadUnaligned(fromByteOffset: b + k * 12 + 8, as: Float32.self))
                }
                faces.append(SIMD3(vid(v(0)), vid(v(1)), vid(v(2))))
            }
        }

        // Empty and duplicate faces.
        var seen = Set<SIMD3<Int32>>()
        faces = faces.filter { f in
            if f.x == f.y || f.y == f.z || f.x == f.z { health.degenerateRemoved += 1; return false }
            if area2(verts, f) < 1e-12 { health.degenerateRemoved += 1; return false }
            let sorted = SIMD3(min(f.x, f.y, f.z), f.x + f.y + f.z - min(f.x, f.y, f.z) - max(f.x, f.y, f.z), max(f.x, f.y, f.z))
            if !seen.insert(sorted).inserted { health.duplicatesRemoved += 1; return false }
            return true
        }

        let before = faces

        // Faces around each undirected edge.
        func key(_ a: Int32, _ b: Int32) -> SIMD2<Int32> { a < b ? SIMD2(a, b) : SIMD2(b, a) }
        func buildEdges() -> [SIMD2<Int32>: [Int32]] {
            var e: [SIMD2<Int32>: [Int32]] = [:]
            e.reserveCapacity(faces.count * 3 / 2)
            for (i, f) in faces.enumerated() {
                e[key(f.x, f.y), default: []].append(Int32(i))
                e[key(f.y, f.z), default: []].append(Int32(i))
                e[key(f.z, f.x), default: []].append(Int32(i))
            }
            return e
        }
        var edges = buildEdges()

        // Make neighbouring faces agree on which side is out, one connected shell at a time.
        func has(_ f: SIMD3<Int32>, _ a: Int32, _ b: Int32) -> Bool {
            (f.x == a && f.y == b) || (f.y == a && f.z == b) || (f.z == a && f.x == b)
        }
        var shellOf = [Int32](repeating: -1, count: faces.count)
        var shells: [[Int32]] = []
        for start in 0..<faces.count where shellOf[start] < 0 {
            let s = Int32(shells.count)
            var members: [Int32] = [Int32(start)]
            shellOf[start] = s
            var queue = [Int32(start)], qi = 0
            while qi < queue.count {
                let fi = Int(queue[qi]); qi += 1
                let f = faces[fi]
                for (a, b) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] {
                    guard let around = edges[key(a, b)], around.count == 2 else { continue }
                    for nb in around where Int(nb) != fi && shellOf[Int(nb)] < 0 {
                        // A consistent neighbour runs this edge the other way (b → a).
                        if has(faces[Int(nb)], a, b) {
                            let g = faces[Int(nb)]; faces[Int(nb)] = SIMD3(g.x, g.z, g.y)
                        }
                        shellOf[Int(nb)] = s
                        members.append(nb); queue.append(nb)
                    }
                }
            }
            shells.append(members)
        }
        health.shells = shells.count

        // Close holes: walk each loop of open edges and fan it from its centre.
        var boundaryNext: [Int32: [Int32]] = [:]   // the hole's loop runs opposite to the face edges
        for (e, around) in edges where around.count == 1 {
            let f = faces[Int(around[0])]
            let (a, b) = has(f, e.x, e.y) ? (e.x, e.y) : (e.y, e.x)
            boundaryNext[b, default: []].append(a)
        }
        var used = Set<SIMD2<Int32>>()
        for (startV, _) in boundaryNext {
            for firstNext in boundaryNext[startV] ?? [] where !used.contains(SIMD2(startV, firstNext)) {
                var loop: [Int32] = [startV]
                var cur = startV, next = firstNext
                used.insert(SIMD2(cur, next))
                var closed = false
                while loop.count < 5000 {
                    if next == startV { closed = true; break }
                    loop.append(next)
                    cur = next
                    guard let nexts = boundaryNext[cur], let n = nexts.first(where: { !used.contains(SIMD2(cur, $0)) }) else { break }
                    used.insert(SIMD2(cur, n))
                    next = n
                }
                guard closed, loop.count >= 3 else { continue }
                if loop.count == 3 {
                    faces.append(SIMD3(loop[0], loop[1], loop[2]))
                } else {
                    let c = loop.reduce(V.zero) { $0 + verts[Int($1)] } / Float(loop.count)
                    let ci = Int32(verts.count); verts.append(c)
                    for i in 0..<loop.count { faces.append(SIMD3(loop[i], loop[(i + 1) % loop.count], ci)) }
                }
                health.holesFilled += 1
            }
        }
        if health.holesFilled > 0 { edges = buildEdges() }

        // Turn inside-out shells right side out (negative enclosed volume), now that holes are closed.
        if shells.count > 0 {
            shellOf += [Int32](repeating: -1, count: faces.count - shellOf.count)
            // Faces added by hole filling belong to the shell of an adjacent face.
            for i in before.count..<faces.count where i < shellOf.count && shellOf[i] < 0 {
                let f = faces[i]
                for (a, b) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] {
                    if let nb = edges[key(a, b)]?.first(where: { Int($0) != i && shellOf[Int($0)] >= 0 }) { shellOf[i] = shellOf[Int(nb)]; break }
                }
            }
            var volume = [Double](repeating: 0, count: shells.count)
            for (i, f) in faces.enumerated() where shellOf[i] >= 0 {
                let a = verts[Int(f.x)], b = verts[Int(f.y)], c = verts[Int(f.z)]
                volume[Int(shellOf[i])] += Double(a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) + a.z * (b.x * c.y - b.y * c.x)) / 6
            }
            // Only flip closed shells; an open sliver's sign means nothing. Skip shells nested inside others
            // (a hollow's inner wall is meant to face in): treat a shell as nested if it is much smaller than the largest.
            let largest = volume.map(abs).max() ?? 0
            for s in 0..<shells.count where volume[s] < 0 && abs(volume[s]) > largest * 0.02 {
                if !isNested(shell: s, shellOf: shellOf, faces: faces, verts: verts) {
                    for i in 0..<faces.count where shellOf[i] == Int32(s) { let f = faces[i]; faces[i] = SIMD3(f.x, f.z, f.y) }
                }
            }
            // Compare with what came in: a shell where most faces changed was inside out; otherwise the changed
            // faces were the odd ones out.
            var changed = [Int](repeating: 0, count: shells.count)
            for i in 0..<before.count where faces[i] != before[i] { changed[Int(shellOf[i])] += 1 }
            for s in 0..<shells.count where changed[s] > 0 {
                if changed[s] * 2 > shells[s].count {
                    health.invertedShells += 1
                    health.flippedFaces += shells[s].count - changed[s]
                } else {
                    health.flippedFaces += changed[s]
                }
            }
        }

        for (_, around) in edges {
            if around.count == 1 { health.openEdges += 1 } else if around.count > 2 { health.nonManifoldEdges += 1 }
        }
        health.triangles = faces.count
        guard health.repaired else { return (data, health) }
        return (write(verts, faces), health)
    }

    /// True if a point of this shell lies inside another shell (odd crossings of a ray along +X).
    private static func isNested(shell s: Int, shellOf: [Int32], faces: [SIMD3<Int32>], verts: [V]) -> Bool {
        guard let fi = shellOf.firstIndex(of: Int32(s)) else { return false }
        let f = faces[fi]
        let p = (verts[Int(f.x)] + verts[Int(f.y)] + verts[Int(f.z)]) / 3 + V(0, 0.000137, 0.000091)
        var crossings: [Int32: Int] = [:]
        for (i, g) in faces.enumerated() where shellOf[i] != Int32(s) && shellOf[i] >= 0 {
            let a = verts[Int(g.x)], b = verts[Int(g.y)], c = verts[Int(g.z)]
            // Project onto the YZ plane and test whether (p.y, p.z) is inside, with the hit in front (+X).
            let d1 = (b.y - a.y) * (p.z - a.z) - (b.z - a.z) * (p.y - a.y)
            let d2 = (c.y - b.y) * (p.z - b.z) - (c.z - b.z) * (p.y - b.y)
            let d3 = (a.y - c.y) * (p.z - c.z) - (a.z - c.z) * (p.y - c.y)
            if (d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0) { continue }
            let n = cross(b - a, c - a)
            guard abs(n.x) > 1e-12 else { continue }
            let x = a.x - (n.y * (p.y - a.y) + n.z * (p.z - a.z)) / n.x
            if x > p.x { crossings[shellOf[i], default: 0] += 1 }
        }
        return crossings.values.contains { $0 % 2 == 1 }
    }

    private static func cross(_ u: V, _ v: V) -> V { V(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x) }

    private static func area2(_ verts: [V], _ f: SIMD3<Int32>) -> Float {
        let c = cross(verts[Int(f.y)] - verts[Int(f.x)], verts[Int(f.z)] - verts[Int(f.x)])
        return (c * c).sum()
    }

    private static func write(_ verts: [V], _ faces: [SIMD3<Int32>]) -> Data {
        var out = Data(count: 80)
        var n = UInt32(faces.count).littleEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.reserveCapacity(84 + faces.count * 50)
        var rec = [Float32](repeating: 0, count: 12)
        for f in faces {
            let a = verts[Int(f.x)], b = verts[Int(f.y)], c = verts[Int(f.z)]
            var nrm = cross(b - a, c - a)
            let len = (nrm * nrm).sum().squareRoot()
            if len > 0 { nrm /= len }
            rec[0] = nrm.x; rec[1] = nrm.y; rec[2] = nrm.z
            rec[3] = a.x; rec[4] = a.y; rec[5] = a.z
            rec[6] = b.x; rec[7] = b.y; rec[8] = b.z
            rec[9] = c.x; rec[10] = c.y; rec[11] = c.z
            rec.withUnsafeBytes { out.append(contentsOf: $0) }
            out.append(contentsOf: [0, 0])
        }
        return out
    }
}
