import SwiftUI

// In-app help (Help › Sirpi Help). Plain topics with short sections and the full shortcut list.

enum HelpTopic: String, CaseIterable, Identifiable {
    case start, generate, customise, detail, print, export, simready, providers, shortcuts, troubleshooting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: "Getting started"
        case .generate: "Generating"
        case .customise: "Customising scenes"
        case .detail: "Smoothing and detail"
        case .print: "Prepare, slice and print"
        case .export: "Exporting"
        case .simready: "NVIDIA SimReady"
        case .providers: "Models and providers"
        case .shortcuts: "Keyboard shortcuts"
        case .troubleshooting: "Troubleshooting"
        }
    }
    var symbol: String {
        switch self {
        case .start: "star"
        case .generate: "sparkles"
        case .customise: "slider.horizontal.below.square.and.square.filled"
        case .detail: "circle.hexagongrid"
        case .print: "printer"
        case .export: "square.and.arrow.up"
        case .simready: "shippingbox"
        case .providers: "cpu"
        case .shortcuts: "keyboard"
        case .troubleshooting: "wrench.and.screwdriver"
        }
    }
}

/// Help topics, shown in the main window's sidebar while Help is open.
struct HelpSidebar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        List(HelpTopic.allCases, selection: Binding(get: { app.helpTopic }, set: { app.helpTopic = $0 ?? .start })) { t in
            Label(t.title, systemImage: t.symbol).tag(t)
        }
        .safeAreaInset(edge: .bottom) { PageSwitcher() }
    }
}

/// The open help topic, shown in the main window.
struct HelpView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let topic = app.helpTopic
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(topic.title).font(.title.weight(.semibold))
                content(topic)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(topic)
        .textSelection(.enabled)
    }

    @ViewBuilder private func content(_ t: HelpTopic) -> some View {
        switch t {
        case .start:
            para("Sirpi (சிற்பி, \"sculptor\") turns a sentence or a picture into a 3D model you can use in a game, print on your Bambu Lab printer, or build into a whole scene.")
            steps(["Pick what you are making in the composer: Game asset, 3D print or 3D scene.",
                   "Describe it, or attach a reference picture.",
                   "Answer the short follow-up questions (or skip them) and press Generate.",
                   "When the preview appears, refine it, customise it, export it, or press Prepare for print."])
            para("Everything you make is saved in the library on the left. Tasks in progress are under Tasks in the toolbar.")
        case .generate:
            section("Purpose", "Game asset makes one object for Godot. 3D print makes one solid, watertight object at real size in millimetres that fits your printer. 3D scene makes a whole place in metres with every object separately named, so you can customise it afterwards.")
            section("Detail", "Low-poly is quickest. Detailed and High detail ask the model for more parts, rounder shapes, bevels and small details. Large cloud models follow this best.")
            section("Follow-up questions", "Before generating, a quick model asks a few questions about style, size, colours or purpose. Answer, type your own, or skip. Turn this off in Settings › Generation.")
            section("Reference picture", "Use Picture in the composer, drop an image on the box, or choose File › Generate from Picture. Cloud models and Claude Code see the picture; for the local model, a vision model describes it first.")
            section("Conversation", "Select an asset and describe a change in its Conversation. Turn on Select part and click a part of the model to change only that part. Every request, error fix and version stays in one conversation; click a version to show it. The original stays.")
        case .customise:
            para("Select an asset and press Customise scene (or Customise parts).")
            steps(["Click an object in the view, or pick it in the Objects list.",
                   "Move, rotate or scale with the gizmo (W, E, R), or type exact values.",
                   "Recolour each material, duplicate, hide or delete objects.",
                   "Insert adds an asset from your library or from NVIDIA SimReady.",
                   "Save as new version keeps the original unchanged."])
            para("Undo with ⌘Z. Snap moves in 0.25 m steps and turns in 15° steps.")
        case .detail:
            para("Smooth & add detail subdivides every part so curved shapes become smooth, while edges sharper than the angle you set stay crisp. Choose ×4, ×16 or ×64 more triangles. The result is saved as a new version.")
        case .print:
            steps(["Prepare: set the height, lay the model flat, turn on repair (merges parts into watertight solids) and choose single or AMS colours.",
                   "Slice: runs Bambu Studio in the background and shows the layers, time and filament.",
                   "Print: sends the file to your printer over the local network and shows progress."])
            para("3D-print assets keep their real size and are shrunk only if they do not fit your printer's build volume. Set your printer model and nozzle in Settings › Printer.")
            section("Print check", "After every slice, Sirpi measures the model and the G-code and lists what may go wrong: parts that start in mid-air, rough overhangs, long bridges, a small base that can come loose, warping, tall thin parts, walls at the filament's melt limit, stringing, uneven gloss, layer cracking and belt patterns. Each problem comes with fixes. A settings fix changes the slicer settings and slices again (the changes are listed under Settings, with Undo). Reshape the model asks the model that wrote the asset to change its shape. Ask AI has a cloud model or Claude Code read the measurements and suggest more fixes, limited to safe settings.")
            section("Supports", "Supports are set to Only if needed: Sirpi turns them on when part of the model starts in mid-air or an underside is steeper than 60°, and leaves them off otherwise. Pick Tree or Normal to always use supports, or Off to never use them. Your choice is remembered.")
            section("Chamber camera", "The Print stage shows the printer's camera live (⌥⌘C). The P2S, X1 and H2 series share it only with LAN Only Mode and Developer Mode turned on in the printer's Settings › Network. On weak Wi-Fi the picture may pause; Sirpi reconnects on its own.")
        case .export:
            section("GLB", "Export GLB saves the model. Turn on Add lightmap UVs to include a second UV set for baked lighting in Godot (LightmapGI).")
            section("Godot", "Copy to Godot project puts the GLB in res://assets/assetforge/ of the project you choose once.")
            section("OBJ", "Save OBJ file keeps colours by baking them into the vertices, for tools that do not read GLB.")
            section("Blender", "Open in Blender launches Blender with the asset imported. Save Blender file writes a .blend in the background. Both need Blender installed.")
            section("STL and 3MF", "After slicing, File › Export STL and Save Sliced File give you the print files.")
        case .simready:
            para("File › Browse NVIDIA SimReady Library (⇧⌘L) lists 2,677 real-world assets with physically based materials: food, kitchenware, boxes, tools, furniture, warehouse and more.")
            steps(["Search or pick a category, select an asset and press Import (or double-click).",
                   "Sirpi downloads only what that asset needs and converts it to GLB in metres.",
                   "It appears in your library and works like any other asset."])
            para("Textures default to 512 px. Choose Full only when you need the original quality; those downloads are large. The first import sets up the USD converter once.")
            para("Licence: CC-BY-4.0. You may use these assets, including commercially, if you credit NVIDIA.")
        case .providers:
            section("On this Mac", "Sirpi's fine-tuned 3D Coder downloads on first launch (2.4 GB) and runs inside the app on the GPU. Pick other weights, or ccore's original model, in Settings › Model.")
            section("Coding agents", "Claude Code, opencode, Grok, Kimi, Cursor Agent, Codex, Gemini CLI and pi are detected automatically and use the login they already have. Pick a model for each in Settings › Coding Agents.")
            section("Cloud APIs", "Claude, OpenAI, Gemini, xAI, Cloudflare Workers AI, OpenRouter, Groq, DeepSeek and Mistral need an API key in Settings › Cloud APIs. Ollama and LM Studio run locally.")
        case .shortcuts:
            shortcuts([
                ("New asset", "⌘N"), ("Generate", "⌘↩"), ("Refine", "⌘R"), ("Fix script errors", "⇧⌘F"), ("Stop generating", "⌘."),
                ("Generate, Prepare, Slice, Print", "⌘1 to ⌘4"), ("Import GLB", "⌘O"), ("Generate from picture", "⇧⌘O"),
                ("NVIDIA SimReady library", "⇧⌘L"), ("Export GLB", "⇧⌘E"), ("Export STL", "⌥⇧⌘E"), ("Save sliced file", "⇧⌘S"),
                ("Copy to Godot", "⌥⌘G"), ("Open in Blender", "⌥⌘B"), ("Reveal in Finder", "⇧⌘R"), ("Move to Trash", "⌘⌫"),
                ("Lay flat", "⌥⌘F"), ("Multi-colour", "⇧⌘C"), ("Slice", "⌘B"), ("Send to printer", "⇧⌘P"), ("Pause or resume print", "⌥⌘P"),
                ("Chamber light", "⌥⌘L"), ("Printer camera", "⌥⌘C"), ("Show tasks", "⌥⌘T"), ("Show or hide inspector", "⌥⌘I"), ("Reset 3D view", "⌘0"),
                ("Scene: move, rotate, scale", "W, E, R"), ("Scene: frame object", "F"), ("Scene: duplicate", "⌘D"), ("Scene: undo", "⌘Z"),
                ("Scene: delete", "Delete"), ("Scene: deselect", "Esc"), ("Settings", "⌘,"), ("Help", "⌘?"), ("Back from Settings or Help", "Esc"),
            ])
        case .troubleshooting:
            section("Generate is greyed out", "The engine shown under Writes the asset is not ready. Open Settings: the local model may still be loading, a coding agent may need signing in, or a cloud API may need a key.")
            section("\"Not available in your country\"", "Some opencode models are region-locked. Choose another model for opencode in Settings › Coding Agents, for example a Cloudflare Workers AI model.")
            section("The page shows script errors", "Press Fix Script Errors (⇧⌘F) to have the model repair them, or generate again.")
            section("A print does not fit", "Prepare shrinks print assets to fit and warns you. Check the printer model in Settings › Printer.")
            section("Generation is slow", "Other GPU work (such as model training) shares the GPU. The speed is shown under Live while generating.")
        }
    }

    private func para(_ s: String) -> some View {
        Text(s).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            para(body)
        }
    }
    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.accent).frame(width: 16)
                    Text(s).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func shortcuts(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { r in
                GridRow {
                    Text(r.0)
                    Text(r.1).font(.body.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Help menu items.
struct HelpMenuItems: View {
    let app: AppModel
    var body: some View {
        Button("Sirpi Help") { app.openHelp() }.keyboardShortcut("?", modifiers: .command)
        Button("Keyboard Shortcuts") { app.openHelp(.shortcuts) }
        Divider()
        Link("NVIDIA SimReady licence (CC-BY-4.0)", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
        Link("three.js documentation", destination: URL(string: "https://threejs.org/docs/")!)
        Link("Bambu Lab LAN mode guide", destination: URL(string: "https://wiki.bambulab.com/en/knowledge-sharing/enable-lan-mode")!)
    }
}
