import SwiftUI

// MARK: - Saved reports

enum PrintCheckStore {
    static func url(_ a: Asset) -> URL { a.dir.appendingPathComponent("print-check.json") }

    static func save(_ r: PrintReport, for a: Asset) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(r).write(to: url(a))
    }

    static func load(_ a: Asset) -> PrintReport? {
        guard let d = try? Data(contentsOf: url(a)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PrintReport.self, from: d)
    }
}

// MARK: - AI review of the measurements

/// A language model reads the measurements and the rule findings and suggests further fixes. Only settings on the
/// list below, within their ranges, are kept, so a suggestion can never send something odd to the printer.
enum PrintReview {
    struct Result { var summary: String?; var findings: [PrintFinding] }

    /// Allowed settings and their ranges. Booleans use 0...1.
    static let allowed: [String: ClosedRange<Double>] = [
        "p.outer_wall_speed": 30...300, "p.inner_wall_speed": 30...350, "p.sparse_infill_speed": 50...400,
        "p.bridge_speed": 10...80, "p.thick_bridges": 0...1, "p.bridge_flow": 0.7...1.2,
        "p.overhang_2_4_speed": 5...100, "p.overhang_3_4_speed": 5...80, "p.overhang_4_4_speed": 5...50,
        "p.reduce_crossing_wall": 0...1, "p.brim_width": 2...15, "p.support_threshold_angle": 10...60,
        "f.filament_max_volumetric_speed": 2...40, "f.fan_max_speed": 0...100, "f.fan_min_speed": 0...100,
        "f.slow_down_layer_time": 2...20, "f.overhang_fan_speed": 0...100,
        "wallLoops": 1...6, "infill": 5...100, "brim": 0...1,
    ]
    static let supportValues = ["auto", "tree(auto)", "normal(auto)", "off"]

    /// The first signed-in model that is good at this: Claude Code (Sonnet), then any cloud API with a key.
    static var provider: Provider? {
        let order = ["claude-code", "anthropic", "openai", "gemini", "xai", "openrouter"]
        return order.map(Providers.find).first { p in
            p.kind == .cli ? CLIRunner.resolvedPath(ProviderSettings.executable(p)) != nil : ProviderSettings.problem(p) == nil
        }
    }

    static let system = """
    You are an expert in FDM 3D printing on Bambu Lab printers. You read measurements of a model and its sliced \
    G-code and suggest changes that prevent print defects. You reply with JSON only.
    """

    static func prompt(report: PrintReport, options: SliceOptions, request: String) -> String {
        var facts: [String: Any] = ["material": report.material, "preset": options.process, "filament": options.filament,
                                    "supports": options.supportMode, "brim": options.brim, "wallLoops": options.wallLoops,
                                    "infill": options.infill]
        if let m = report.mesh {
            facts["model"] = [
                "heightMM": m.height.rounded(), "footprintMM": [m.sizeX.rounded(), m.sizeY.rounded()],
                "plateContactMM2": m.contactArea.rounded(), "undersideSteeperThan60degMM2": m.steepArea.rounded(),
                "underside45to60degMM2": m.roughArea.rounded(), "partsStartingInMidAir": m.islands.count,
                "verticalWallMM2": m.verticalArea.rounded(),
            ]
        }
        if let g = report.gcode {
            var current: [String: String] = [:]
            for k in allowed.keys where k.hasPrefix("p.") || k.hasPrefix("f.") {
                if let v = g.settings[String(k.dropFirst(2))] { current[k] = v }
            }
            facts["slice"] = [
                "layers": g.layers, "longestBridgeMM": g.longestBridge.rounded(), "bridgeHeightMM": g.longestBridgeZ,
                "overhangWallMM": g.overhangWallLength.rounded(), "supportExtrusionMM": g.supportLength.rounded(),
                "wallTimeAtMeltLimit": (g.nearFlowLimit * 100).rounded() / 100, "meltLimitMM3s": g.flowLimit,
                "outerWallSlowedShare": (g.slowOuterWallShare * 100).rounded() / 100, "travelsPerLayer": g.travelsPerLayer.rounded(),
                "currentSettings": current,
            ]
        }
        facts["alreadyFound"] = report.findings.filter { $0.source == nil }.map { "\($0.defect.rawValue): \($0.title)" }
        let json = (try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let keys = allowed.sorted { $0.key < $1.key }.map { k, r in
            "\(k) (\(r.lowerBound.formatted())–\(r.upperBound.formatted()))"
        }.joined(separator: ", ")
        return """
        The object being printed: \(request.prefix(600))

        Measurements:
        \(json)

        Check for these defects: bad overhangs, bad bridging, warping, falling off the plate, collapsing, \
        under-extrusion, stringing and oozing, uneven gloss, layer cracking, belt pattern. Suggest up to 4 changes \
        that the findings in "alreadyFound" do not already cover, only where the measurements show a real risk. An \
        empty list is a fine answer.

        Settings you may change, with allowed ranges: \(keys), supports (\(supportValues.joined(separator: ", "))). \
        Prefix p. means the process preset, f. the filament preset. You may instead ask for a change to the model's \
        shape in "refine" (an instruction to the programmer who wrote it; heights from the ground up).

        Reply with only this JSON:
        {"summary": "<one or two plain sentences on how this print will go>",
         "suggestions": [{"defect": "<one of: \(PrintFinding.Defect.allCases.map(\.rawValue).joined(separator: ", "))>",
                          "severity": "info|warn|risk", "title": "<short>", "detail": "<why, in plain words>",
                          "fixLabel": "<2-4 words>", "settings": {"<key>": "<value>"}, "refine": "<or null>"}]}
        """
    }

    static func review(report: PrintReport, options: SliceOptions, request: String) async throws -> Result {
        guard let p = provider else {
            throw ForgeError("No AI model for reviews is set up. Install Claude Code or add an API key in Settings › Model.")
        }
        let messages = [["role": "user", "content": prompt(report: report, options: options, request: request)]]
        let stream = p.kind == .cli
            ? CLIRunner.stream(p, messages: messages, systemOverride: system, modelOverride: "sonnet")
            : RemoteEngine.stream(p, messages: messages, thinking: false, systemOverride: system)
        var text = ""
        for try await piece in stream { if case .content(let t, _) = piece { text += t } }
        return try parse(text, source: ProviderSettings.label(p))
    }

    static func parse(_ text: String, source: String) throws -> Result {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw ForgeError("The AI model's review could not be read.")
        }
        var findings: [PrintFinding] = []
        for (i, s) in ((obj["suggestions"] as? [[String: Any]]) ?? []).prefix(4).enumerated() {
            guard let title = s["title"] as? String, !title.isEmpty else { continue }
            var settings: [String: String] = [:]
            for (k, raw) in (s["settings"] as? [String: Any]) ?? [:] {
                let v = "\(raw)".trimmingCharacters(in: CharacterSet(charactersIn: " %"))
                if k == "supports" { if supportValues.contains(v) { settings[k] = v }; continue }
                guard let range = allowed[k], let n = Double(v) else { continue }
                let clamped = min(range.upperBound, max(range.lowerBound, n))
                settings[k] = clamped == clamped.rounded() ? String(Int(clamped)) : String(format: "%.2f", clamped)
            }
            let refine = (s["refine"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "Print fix: " + $0 }
            var fixes: [PrintFix] = []
            let label = (s["fixLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Apply"
            if !settings.isEmpty { fixes.append(PrintFix(label: label, settings: settings)) }
            if let refine { fixes.append(PrintFix(label: "Reshape the model", refine: refine)) }
            let sev: PrintFinding.Severity = switch s["severity"] as? String { case "risk": .risk; case "warn": .warn; default: .info }
            findings.append(PrintFinding(id: "ai-\(i)", defect: PrintFinding.Defect(rawValue: s["defect"] as? String ?? "") ?? .overhang,
                                         severity: sev, title: title, detail: s["detail"] as? String ?? "", fixes: fixes, source: source))
        }
        return Result(summary: obj["summary"] as? String, findings: findings)
    }
}

// MARK: - Inspector

struct PrintCheckSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let prep = app.prep
        InspectorSection(title: "Print check", trailing: trailing) {
            if let report = prep.check {
                if report.findings.isEmpty {
                    Label("No problems expected", systemImage: "checkmark.circle").foregroundStyle(Theme.accent)
                }
                ForEach(report.findings) { FindingRow(finding: $0) }
                if let s = report.aiSummary {
                    Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Slice again to check this print for overhangs, bridges, warping and other problems.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trailing: AnyView? {
        if app.prep.reviewingPrint { return AnyView(ProgressView().controlSize(.small)) }
        guard app.prep.check != nil, PrintReview.provider != nil else { return nil }
        return AnyView(Button("Ask AI") { Task { await app.reviewPrint() } }
            .buttonStyle(.glass).controlSize(.small)
            .disabled(app.prep.busy != nil)
            .help("Have an AI model read these measurements and suggest more fixes"))
    }
}

private struct FindingRow: View {
    @Environment(AppModel.self) private var app
    let finding: PrintFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(finding.defect.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if let s = finding.source { Text("· \(s)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Text(finding.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Text(finding.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !finding.fixes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(finding.fixes) { fix in
                            Button { Task { await app.applyPrintFix(fix) } } label: {
                                Label(fix.label, systemImage: fix.refine != nil ? "wand.and.stars" : "slider.horizontal.3")
                            }
                            .buttonStyle(.glass).controlSize(.small)
                            .disabled(app.prep.busy != nil || (fix.refine != nil && (!app.engineReady || app.generator.isRunning)))
                            .help(fix.refine != nil ? "Ask the model to change the shape, then slice the new version"
                                                    : "Change these settings and slice again")
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch finding.severity {
        case .risk: "xmark.octagon"
        case .warn: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }
    private var color: Color {
        switch finding.severity {
        case .risk: Theme.destructive
        case .warn: Theme.warning
        case .info: .secondary
        }
    }
}

/// Preset values changed by print-check fixes, with a way to undo them.
struct PresetOverridesView: View {
    @Environment(AppModel.self) private var app

    static let names: [String: String] = [
        "outer_wall_speed": "Outer wall speed", "inner_wall_speed": "Inner wall speed", "sparse_infill_speed": "Infill speed",
        "bridge_speed": "Bridge speed", "thick_bridges": "Thick bridges", "bridge_flow": "Bridge flow",
        "overhang_2_4_speed": "Overhang speed 25–50%", "overhang_3_4_speed": "Overhang speed 50–75%",
        "overhang_4_4_speed": "Overhang speed 75–100%", "reduce_crossing_wall": "Avoid crossing walls",
        "brim_width": "Brim width", "support_threshold_angle": "Support angle",
        "filament_max_volumetric_speed": "Max flow", "fan_max_speed": "Max part fan", "fan_min_speed": "Min part fan",
        "slow_down_layer_time": "Min layer time", "overhang_fan_speed": "Overhang fan",
    ]
    static let units: [String: String] = [
        "outer_wall_speed": " mm/s", "inner_wall_speed": " mm/s", "sparse_infill_speed": " mm/s", "bridge_speed": " mm/s",
        "overhang_2_4_speed": " mm/s", "overhang_3_4_speed": " mm/s", "overhang_4_4_speed": " mm/s", "brim_width": " mm",
        "support_threshold_angle": "°", "filament_max_volumetric_speed": " mm³/s", "fan_max_speed": "%", "fan_min_speed": "%",
        "slow_down_layer_time": " s", "overhang_fan_speed": "%",
    ]

    var body: some View {
        let o = app.prep.options
        let all = o.processOverrides.merging(o.filamentOverrides) { a, _ in a }.sorted { $0.key < $1.key }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Changed by print check").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") {
                        app.prep.options.processOverrides = [:]; app.prep.options.filamentOverrides = [:]
                    }
                    .buttonStyle(.link).font(.caption)
                    .help("Go back to the preset's values. Slice again to apply.")
                }
                ForEach(all, id: \.key) { k, v in
                    HStack {
                        Text(Self.names[k] ?? k).foregroundStyle(.secondary)
                        Spacer()
                        Text(display(k, v)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 4)
        }
    }

    private func display(_ k: String, _ v: String) -> String {
        if ["thick_bridges", "reduce_crossing_wall"].contains(k) { return v == "1" ? "On" : "Off" }
        return v + (Self.units[k] ?? "")
    }
}
