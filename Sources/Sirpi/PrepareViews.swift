import SwiftUI
import AppKit

struct ColorCluster: Identifiable, Hashable { var id: String; var hex: String; var share: Double; var slot: String; var parts: Int }
struct ColorSlot: Identifiable, Hashable { var id: String { key }; var key: String; var hex: String; var label: String }
struct PlannedFilament: Hashable { var slot: String; var hex: String; var label: String; var share: Double }
struct ExportedFilament { var slot: String; var hex: String; var data: Data; var triangles: Int }
struct RepairReport { var parts = 0; var manifoldParts = 0; var passthroughParts = 0 }
struct ColorVariant: Identifiable, Equatable { var id: Int { colors }; var colors: Int; var hexes: [String]; var seconds: Double; var grams: Double; var changes: Int }

// MARK: - Shared print-prep state (one per window, follows the selected asset)

@Observable @MainActor
final class PrepState {
    let prepWeb = WebController(injectBridge: false)
    let gcodeWeb = WebController(injectBridge: false)
    var assetID: String?
    var ready = false
    var size: [Double] = [0, 0, 0]
    var triangles = 0
    var warnings: [String] = []
    var repairStats: [String: Int] = [:]
    var targetHeight: Double = 60
    /// Set while the page reports a height it chose itself (native-size fit), so it isn't echoed back as a manual change.
    var syncingHeight = false
    /// Real-world size the model was authored at (print assets are modelled in mm).
    var nativeSize: [Double] = []
    var fitScale: Double = 1
    var options = SliceOptions()
    var repair = true
    var minThickness = 1.2
    var multicolor = false
    var maxColors = 4
    var clusters: [ColorCluster] = []
    var slots: [ColorSlot] = []
    var planned: [PlannedFilament] = []
    var result: SliceResult?
    var check: PrintReport?
    var reviewingPrint = false
    var lastReport: RepairReport?
    var variants: [ColorVariant] = []
    var comparing = false
    var busy: String?
    var showTravel = false
    var colorByFilament = true
    var oneLayer = false
    private var exports: [String: CheckedContinuation<([ExportedFilament], RepairReport), Error>] = [:]

    init() {
        prepWeb.onMessage = { [weak self] m in self?.handle(m) }
    }

    func reset(for a: Asset, slicer: Slicer) {
        assetID = a.id
        ready = false
        result = Slicer.loadResult(a)
        check = result == nil ? nil : PrintCheckStore.load(a)
        // Fixes from the print check belong to the asset they were made for.
        options.processOverrides = [:]; options.filamentOverrides = [:]
        options.supportMode = SliceOptions.savedSupportMode
        variants = []
        clusters = []; planned = []; size = [0, 0, 0]; triangles = 0; warnings = []
        if options.process.isEmpty || !slicer.processes.contains(options.process) {
            options.process = slicer.processes.first { $0.hasPrefix("0.20mm Standard") } ?? slicer.processes.first ?? ""
        }
        if !slicer.filaments.contains(options.filament) { options.filament = slicer.filaments.first ?? "" }
    }

    func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "ready": ready = true
        case "info":
            size = (m["size"] as? [Double]) ?? size
            nativeSize = (m["nativeSize"] as? [Double]) ?? nativeSize
            fitScale = (m["fitScale"] as? Double) ?? 1
            if m["fit"] as? String == "native", let h = m["height"] as? Double, abs(h - targetHeight) > 0.5 {
                syncingHeight = true
                targetHeight = h.rounded()
            }
            triangles = (m["triangles"] as? Int) ?? triangles
            warnings = (m["warnings"] as? [String]) ?? []
            repairStats = (m["repair"] as? [String: Int]) ?? [:]
            clusters = ((m["clusters"] as? [[String: Any]]) ?? []).map {
                ColorCluster(id: "\($0["id"] ?? "")", hex: $0["hex"] as? String ?? "#888888",
                             share: $0["share"] as? Double ?? 0, slot: $0["slot"] as? String ?? "", parts: $0["parts"] as? Int ?? 0)
            }
            slots = ((m["slots"] as? [[String: Any]]) ?? []).map {
                ColorSlot(key: $0["key"] as? String ?? "", hex: $0["hex"] as? String ?? "#888888", label: $0["label"] as? String ?? "")
            }
            planned = ((m["filaments"] as? [[String: Any]]) ?? []).map {
                PlannedFilament(slot: $0["slot"] as? String ?? "", hex: $0["hex"] as? String ?? "#888888",
                                label: $0["label"] as? String ?? "", share: $0["share"] as? Double ?? 0)
            }
        case "export":
            guard let id = m["requestId"] as? String, let cont = exports.removeValue(forKey: id) else { return }
            if let err = m["error"] as? String { cont.resume(throwing: ForgeError("Mesh export failed: \(err)")); return }
            let fils = ((m["filaments"] as? [[String: Any]]) ?? []).compactMap { f -> ExportedFilament? in
                guard let b64 = f["data"] as? String, let d = Data(base64Encoded: b64) else { return nil }
                return ExportedFilament(slot: f["slot"] as? String ?? "", hex: f["hex"] as? String ?? "#888888",
                                        data: d, triangles: f["triangles"] as? Int ?? 0)
            }
            let r = m["report"] as? [String: Any] ?? [:]
            cont.resume(returning: (fils, RepairReport(parts: r["parts"] as? Int ?? 0, manifoldParts: r["manifoldParts"] as? Int ?? 0,
                                                       passthroughParts: r["passthroughParts"] as? Int ?? 0)))
        default: break
        }
    }

    func export(maxColors: Int? = nil) async throws -> ([ExportedFilament], RepairReport) {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { c in
            exports[id] = c
            let arg = maxColors.map { ", maxColors: \($0)" } ?? ""
            Task { await prepWeb.eval("window.prep.exportPrint({ requestId: '\(id)'\(arg) }); true") }
        }
    }

    func push(_ js: String) { Task { await prepWeb.eval(js) } }
    func pushRepair() { push("window.prep.setRepair(\(repair), \(minThickness))") }
    func pushColors() { push("window.prep.setMulticolor(\(multicolor), \(maxColors))") }
    func pushGcodeView() {
        Task { await gcodeWeb.eval("window.gview && window.gview.set({ byTool: \(colorByFilament), travel: \(showTravel), single: \(oneLayer) })") }
    }

    /// Colours whose nearest AMS slot is far off (e.g. a red scarf with no red loaded).
    var unmatched: [ColorCluster] {
        clusters.filter { c in
            guard let s = slots.first(where: { $0.key == c.slot }), c.slot.hasPrefix("tray:") else { return false }
            return Self.distance(c.hex, s.hex) > 90
        }
    }

    static func distance(_ a: String, _ b: String) -> Double {
        func rgb(_ h: String) -> (Double, Double, Double) {
            let v = UInt64(h.replacingOccurrences(of: "#", with: "").prefix(6), radix: 16) ?? 0
            return (Double(v >> 16 & 255), Double(v >> 8 & 255), Double(v & 255))
        }
        let x = rgb(a), y = rgb(b)
        return ((x.0 - y.0) * (x.0 - y.0) * 2 + (x.1 - y.1) * (x.1 - y.1) * 4 + (x.2 - y.2) * (x.2 - y.2) * 3).squareRoot() / 3
    }
}

// MARK: - Prepare

struct PrepareViewport: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let a = app.selectedAsset {
            let prep = app.prep
            ZStack {
                ForgeWebView(controller: prep.prepWeb)
                VStack {
                    HStack {
                        if prep.size[0] > 0 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "%.1f × %.1f × %.1f mm", prep.size[0], prep.size[1], prep.size[2])).monospacedDigit()
                                Text(prep.size.contains { $0 > 256 } ? "Larger than the 256 mm plate" : "Fits the 256 mm plate")
                                    .foregroundStyle(prep.size.contains { $0 > 256 } ? Theme.warning : .secondary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                        Spacer()
                    }
                    Spacer()
                    ViewportToolbar {
                        Text("Rotate").foregroundStyle(.secondary).padding(.horizontal, 6)
                        ForEach(["x", "y", "z"], id: \.self) { axis in
                            Button(axis.uppercased()) { prep.push("window.prep.rotate('\(axis)', 90)") }
                                .frame(minWidth: 26).help("Rotate 90° around \(axis.uppercased())")
                        }
                        ViewportDivider()
                        Button { prep.push("window.prep.layFlat()") } label: { Label("Lay flat", systemImage: "arrow.down.to.line") }
                        Button { prep.push("window.prep.resetRotation()") } label: { Image(systemName: "arrow.counterclockwise") }.help("Reset orientation")
                        ViewportDivider()
                        Button { prep.push("window.prep.toggleParts()") } label: {
                            HStack(spacing: 4) { Text("Parts"); Text("\(prep.clusters.reduce(0) { $0 + $1.parts })").foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }
                }
                .padding(14)
                if let busy = prep.busy {
                    Label(busy, systemImage: "hourglass").padding(.horizontal, 14).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                }
            }
            .task(id: a.id) { await app.loadPrep(a) }
        }
    }
}

struct PrepareInspector: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var prep = app.prep
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Height").fontWeight(.semibold)
                            Spacer()
                            TextField("", value: $prep.targetHeight, format: .number.precision(.fractionLength(0)))
                                .frame(width: 64).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).monospacedDigit()
                            Text("mm").foregroundStyle(.secondary)
                        }
                        Slider(value: $prep.targetHeight, in: 10...250, step: 1) {
                            Text("Height")
                        } minimumValueLabel: { Text("10").font(.caption) } maximumValueLabel: { Text("250").font(.caption) }
                            .labelsHidden()
                    }
                    .padding(16)
                    .onChange(of: prep.targetHeight) { _, v in
                        if prep.syncingHeight { prep.syncingHeight = false; return }
                        prep.push("window.prep.setHeight(\(v))")
                    }

                    InspectorSection(title: "Repair for printing", trailing: AnyView(Toggle("", isOn: $prep.repair).toggleStyle(.switch).tint(Theme.accent).labelsHidden())) {
                        if prep.repair {
                            HStack {
                                Text("Minimum wall").foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f mm", prep.minThickness)).monospacedDigit()
                            }
                            Slider(value: $prep.minThickness, in: 0.6...3.0, step: 0.1).labelsHidden()
                            VStack(alignment: .leading, spacing: 8) {
                                fix(prep.repairStats["thickened"] ?? 0, "thin parts thickened")
                                fix(prep.repairStats["solidified"] ?? 0, "flat parts solidified")
                                fix(prep.repairStats["capped"] ?? 0, "open parts capped")
                                if let r = prep.lastReport {
                                    fix(r.manifoldParts, "of \(r.parts) parts merged into solids")
                                }
                            }
                            .padding(.top, 4)
                        } else {
                            Text("Parts are exported as they are. Flat parts are skipped and overlaps are left to the slicer.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .onChange(of: prep.repair) { _, _ in prep.pushRepair() }
                    .onChange(of: prep.minThickness) { _, _ in prep.pushRepair() }

                    InspectorSection(title: "Colours", trailing: AnyView(
                        Picker("", selection: Binding(get: { prep.multicolor }, set: { prep.multicolor = $0; prep.variants = []; prep.pushColors() })) {
                            Text("One").tag(false); Text("AMS").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    )) {
                        if prep.multicolor {
                            Stepper("Up to \(prep.maxColors) colours", value: $prep.maxColors, in: 2...max(2, maxSlots))
                                .onChange(of: prep.maxColors) { _, _ in prep.variants = []; prep.pushColors() }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                            ForEach(prep.clusters) { c in
                                GridRow {
                                    Swatch(hex: c.hex)
                                    Text(prep.multicolor ? "\(Int((c.share * 100).rounded()))%" : "All").monospacedDigit().foregroundStyle(.secondary)
                                    Menu {
                                        ForEach(prep.slots) { s in
                                            Button { prep.push("window.prep.assign('\(c.id)', '\(s.key)')") } label: {
                                                Text(s.label)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Swatch(hex: prep.slots.first { $0.key == c.slot }?.hex ?? c.hex)
                                            Text(prep.slots.first { $0.key == c.slot }?.label ?? "Filament").lineLimit(1)
                                        }
                                    }
                                    .menuStyle(.button).buttonStyle(.glass)
                                }
                            }
                        }
                        if let miss = prep.unmatched.first {
                            Text("No loaded filament is close to \(miss.hex). That part prints in the matched slot; load a closer colour to keep it.")
                                .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
                        } else if app.printer.status.trays.isEmpty {
                            Text(prep.multicolor ? "Printer offline: each colour becomes its own filament. You pick AMS slots when you print." : "Colours are matched to your AMS once the printer is connected.")
                                .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(prep.warnings, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            }
            InspectorSection {
                HStack {
                    Text("\(max(1, prep.planned.count)) filament\(prep.planned.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Spacer()
                    PrimaryButton(title: "Slice", systemImage: "square.3.layers.3d") { Task { await app.slice() } }
                        .disabled(!prep.ready || prep.busy != nil || !app.slicer.available)
                        .keyboardShortcut("b", modifiers: .command)
                }
            }
        }
    }

    private var maxSlots: Int {
        let n = app.printer.status.trays.filter { !$0.isExternal }.count
        return n > 0 ? n : 8
    }

    private func fix(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").monospacedDigit().frame(minWidth: 26, alignment: .trailing)
            Text(label)
        }
        .foregroundStyle(n == 0 ? .secondary : .primary)
    }
}

// MARK: - Slice

struct SliceViewport: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let a = app.selectedAsset {
            let prep = app.prep
            ZStack {
                if a.has(a.gcodeURL) {
                    ForgeWebView(controller: prep.gcodeWeb)
                    VStack {
                        Spacer()
                        ViewportToolbar {
                            Picker("", selection: Binding(get: { prep.colorByFilament }, set: { prep.colorByFilament = $0; prep.pushGcodeView() })) {
                                Text("Filament").tag(true); Text("Feature").tag(false)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            ViewportDivider()
                            Toggle("Layer", isOn: Binding(get: { prep.oneLayer }, set: { prep.oneLayer = $0; prep.pushGcodeView() })).toggleStyle(.button)
                            Toggle("Travel", isOn: Binding(get: { prep.showTravel }, set: { prep.showTravel = $0; prep.pushGcodeView() })).toggleStyle(.button)
                        }
                        .padding(.bottom, 18)
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "square.3.layers.3d").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("Not sliced yet").font(.title3.weight(.semibold))
                        Text("Slice the asset with Bambu Studio to see layers, time and filament.").foregroundStyle(.secondary)
                        PrimaryButton(title: "Slice", systemImage: "square.3.layers.3d") { Task { await app.slice() } }
                            .disabled(prep.busy != nil || !app.slicer.available)
                    }
                }
                if let busy = prep.busy {
                    Label(busy, systemImage: "hourglass").padding(.horizontal, 14).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                }
            }
            .task(id: a.id) {
                await app.loadPrep(a)
                if a.has(a.gcodeURL) && app.prep.gcodeWeb.loadedURL == nil { app.loadGcodePreview(a) }
            }
            .onChange(of: prep.gcodeWeb.isLoading) { _, loading in if !loading { prep.pushGcodeView() } }
        }
    }
}

struct SliceInspector: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var prep = app.prep
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let r = prep.result { result(r) } else {
                        Text("Not sliced yet").font(.headline).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if prep.result != nil { PrintCheckSection() }

                    if prep.multicolor || !prep.variants.isEmpty {
                        InspectorSection(title: "Colour options", trailing: prep.comparing ? AnyView(ProgressView().controlSize(.small)) : nil) {
                            ForEach(prep.variants) { v in variantRow(v) }
                            if prep.variants.isEmpty && !prep.comparing {
                                Button("Compare colour counts") { Task { await app.compareVariants() } }.buttonStyle(.glass)
                                    .disabled(prep.busy != nil || !prep.ready)
                            }
                            Text("Most of the extra time and filament goes to purging between colours.")
                                .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    InspectorSection(title: "Settings") {
                        Picker("Layer height", selection: $prep.options.process) {
                            ForEach(qualityOptions, id: \.1) { label, name in Text(label).tag(name) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        LabeledContent("Preset") {
                            Picker("", selection: $prep.options.process) {
                                ForEach(app.slicer.processes, id: \.self) { Text($0.replacingOccurrences(of: " @BBL P2S", with: "")).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        LabeledContent("Material") {
                            Picker("", selection: $prep.options.filament) {
                                ForEach(app.slicer.filaments, id: \.self) { Text($0.replacingOccurrences(of: " @BBL P2S", with: "")).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        LabeledContent("Supports") {
                            Picker("", selection: Binding(get: { prep.options.supportMode },
                                                          set: { prep.options.supportMode = $0; UserDefaults.standard.set($0, forKey: SliceOptions.supportModeKey) })) {
                                Text("Only if needed").tag("auto")
                                Text("Tree, always").tag("tree(auto)")
                                Text("Normal, always").tag("normal(auto)")
                                Text("Off").tag("off")
                            }.labelsHidden().fixedSize()
                        }
                        LabeledContent("Infill") {
                            Picker("", selection: $prep.options.infill) {
                                ForEach([5, 10, 15, 20, 30, 50, 100], id: \.self) { Text("\($0)%").tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        LabeledContent("Walls") {
                            Stepper("\(prep.options.wallLoops)", value: $prep.options.wallLoops, in: 1...6).monospacedDigit()
                        }
                        LabeledContent("Brim") { Toggle("", isOn: $prep.options.brim).toggleStyle(.switch).tint(Theme.accent).labelsHidden() }
                        PresetOverridesView()
                    }
                    .labeledContentStyle(OneLineLabel())
                }
            }
            InspectorSection {
                HStack {
                    if let a = app.selectedAsset, a.has(a.threeMFURL) {
                        Button("Bambu Studio") { app.openInStudio(a.threeMFURL) }.buttonStyle(.glass)
                    }
                    Spacer()
                    if prep.result == nil {
                        PrimaryButton(title: "Slice", systemImage: "square.3.layers.3d") { Task { await app.slice() } }
                            .disabled(prep.busy != nil || !app.slicer.available)
                    } else {
                        PrimaryButton(title: "Send to P2S", systemImage: "printer") { app.showPrintSheet = true }
                            .disabled(app.printer.connection != .connected || app.printer.status.isPrinting || prep.busy != nil)
                            .help(app.printer.connection != .connected ? "Connect the printer in the Print stage first" : "")
                    }
                }
            }
        }
    }

    private var qualityOptions: [(String, String)] {
        let p = app.slicer.processes
        var out: [(String, String)] = []
        if let fine = p.first(where: { $0.hasPrefix("0.12mm") }) { out.append(("Fine 0.12", fine)) }
        if let std = p.first(where: { $0.hasPrefix("0.20mm Standard") }) { out.append(("Standard 0.20", std)) }
        if let draft = p.first(where: { $0.hasPrefix("0.28mm") }) ?? p.first(where: { $0.hasPrefix("0.24mm") }) {
            out.append(("Draft \(draft.prefix(4))", draft))
        }
        if !out.contains(where: { $0.1 == app.prep.options.process }) { out.append(("Custom", app.prep.options.process)) }
        return out
    }

    @ViewBuilder private func result(_ r: SliceResult) -> some View {
        let fils = r.filaments ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text(formatDuration(r.seconds)).font(.system(size: 30, weight: .semibold, design: .monospaced))
            Text("\(String(format: "%.0f g", r.weightGrams)) of \(r.filamentType)" + ((r.changes ?? 0) > 0 ? " and \(r.changes!) colour swaps" : ""))
                .foregroundStyle(.secondary)
            if fils.count > 1 {
                GeometryReader { geo in
                    let total = max(fils.reduce(0) { $0 + $1.grams }, 0.001)
                    HStack(spacing: 3) {
                        ForEach(Array(fils.enumerated()), id: \.offset) { _, f in
                            Capsule().fill(Color(hex: f.hex)).frame(width: max(4, (geo.size.width - CGFloat(fils.count - 1) * 3) * f.grams / total))
                        }
                    }
                }
                .frame(height: 8).padding(.top, 8)
            }
            VStack(spacing: 6) {
                ForEach(Array(fils.enumerated()), id: \.offset) { i, f in
                    HStack {
                        Swatch(hex: f.hex)
                        Text(slotLabel(f, index: i))
                        Spacer()
                        Text(String(format: "%.1f g", f.grams)).monospacedDigit()
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(16)
    }

    private func slotLabel(_ f: FilamentUse, index: Int) -> String {
        if f.slot.hasPrefix("tray:"), let id = Int(f.slot.dropFirst(5)), let t = app.printer.status.trays.first(where: { $0.id == id }) {
            return "\(t.label) · \(t.type)"
        }
        return "Filament \(index + 1) · \(f.type)"
    }

    private func variantRow(_ v: ColorVariant) -> some View {
        let selected = (app.prep.result?.filaments?.count ?? 1) == v.colors
        return Button { Task { await app.useVariant(v) } } label: {
            HStack(spacing: 10) {
                HStack(spacing: 3) { ForEach(Array(v.hexes.enumerated()), id: \.offset) { Swatch(hex: $0.element) } }
                    .frame(width: 62, alignment: .leading)
                Text(formatDuration(v.seconds)).monospacedDigit()
                Spacer()
                Text(String(format: "%.0f g", v.grams)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.accent.opacity(0.08) : Theme.cell))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent : .white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.prep.busy != nil)
    }
}

// MARK: - Print sheet

struct PrintSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var options = PrinterManager.PrintOptions()
    @State private var mapping: [Int: Int] = [:]   // filament index -> tray id (-1 external)

    var body: some View {
        let fils = app.prep.result?.filaments ?? []
        let trays = app.printer.status.trays.filter { !$0.isExternal }
        VStack(alignment: .leading, spacing: 16) {
            Text("Send to Bambu Lab P2S").font(.title2.weight(.semibold))
            if let a = app.selectedAsset, let r = app.prep.result {
                Text("\(a.shortTitle), \(formatDuration(r.seconds)), \(String(format: "%.0f g", r.weightGrams))").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Filaments").fontWeight(.semibold)
                ForEach(Array(fils.enumerated()), id: \.offset) { i, f in
                    HStack {
                        Swatch(hex: f.hex)
                        Text("Filament \(i + 1)").frame(width: 80, alignment: .leading)
                        Picker("", selection: Binding(get: { mapping[i] ?? defaultTray(f, i, fils.count) }, set: { mapping[i] = $0 })) {
                            if fils.count == 1 { Text("External spool").tag(-1) }
                            ForEach(trays) { t in Text("\(t.label) · \(t.type)").tag(t.id) }
                        }
                        .labelsHidden()
                        Swatch(hex: trays.first { $0.id == (mapping[i] ?? defaultTray(f, i, fils.count)) }?.colorHex ?? "333333")
                    }
                }
                if fils.count > 1 && trays.count < fils.count {
                    Label("This print needs \(fils.count) AMS slots; the printer reports \(trays.count).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
            }
            Divider()
            Toggle("Auto bed leveling", isOn: $options.bedLeveling)
            Toggle("Flow calibration", isOn: $options.flowCalibration)
            Toggle("Timelapse", isOn: $options.timelapse)
            Picker("Plate", selection: $options.bedType) {
                Text("Textured PEI").tag("textured_plate"); Text("Cool plate").tag("cool_plate")
                Text("Engineering plate").tag("eng_plate"); Text("High-temp plate").tag("hot_plate")
            }
            Text("Make sure the plate is clear and the right filaments are loaded.").foregroundStyle(.secondary).font(.callout)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Spacer()
                PrimaryButton(title: "Upload & print", systemImage: "printer.fill") {
                    guard let a = app.selectedAsset else { return }
                    var o = options
                    o.mapping = fils.isEmpty ? [nil] : fils.enumerated().map { i, f in
                        let id = mapping[i] ?? defaultTray(f, i, fils.count)
                        return app.printer.status.trays.first { $0.id == id }
                    }
                    dismiss()
                    Task { await app.startPrint(a, options: o) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func defaultTray(_ f: FilamentUse, _ i: Int, _ count: Int) -> Int {
        let trays = app.printer.status.trays.filter { !$0.isExternal }
        if f.slot.hasPrefix("tray:"), let id = Int(f.slot.dropFirst(5)), trays.contains(where: { $0.id == id }) { return id }
        if count == 1 && trays.isEmpty { return -1 }
        return trays.min { PrepState.distance($0.colorHex, f.hex) < PrepState.distance($1.colorHex, f.hex) }?.id ?? -1
    }
}


/// LabeledContent with a single-line label so narrow inspectors don't hyphenate ("Ma-terial").
struct OneLineLabel: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label.lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            configuration.content
        }
    }
}
