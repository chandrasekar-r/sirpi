import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Reference picture

/// A picture the user attached to guide a generation, downscaled to a JPEG that every vision API accepts.
struct ReferenceImage: Equatable {
    let jpeg: Data
    let thumbnail: NSImage
    var base64: String { jpeg.base64EncodedString() }

    static func == (a: ReferenceImage, b: ReferenceImage) -> Bool { a.jpeg == b.jpeg }

    init?(url: URL) {
        guard let img = NSImage(contentsOf: url) else { return nil }
        self.init(image: img)
    }

    init?(image: NSImage, maxSide: CGFloat = 1024) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Transparent PNGs get a neutral grey backdrop instead of black.
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        jpeg = data
        thumbnail = NSImage(cgImage: out, size: size)
    }

    static let types: [UTType] = [.png, .jpeg, .heic, .tiff, .webP, .gif, .bmp, .image]

    /// Shows an open panel for a picture.
    @MainActor static func choose() -> ReferenceImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.message = "Choose a reference picture of the object to model"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return ReferenceImage(url: url)
    }

    /// Reads a picture from the pasteboard (copied image or image file).
    @MainActor static func fromPasteboard(_ pb: NSPasteboard = .general) -> ReferenceImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first { return ReferenceImage(url: url) }
        if let img = NSImage(pasteboard: pb) { return ReferenceImage(image: img) }
        return nil
    }
}

// MARK: - Which engines can see pictures

extension Provider {
    /// True when the provider receives the picture itself; otherwise a vision model describes it first.
    var seesImages: Bool {
        switch kind {
        case .anthropic, .openAI: true
        case .cli: ["claude-code", "opencode", "gemini-cli", "codex"].contains(id)
        case .local: false
        }
    }
}

// MARK: - Describe a picture as a modelling brief (for text-only engines)

enum ImageDescriber {
    static let instruction = """
    Describe the main object in this picture as a brief for a 3D artist who will model it as one game asset. \
    Cover: what it is; overall proportions (height : width : depth); every distinct part, its shape and how parts \
    connect; colours as hex codes; materials and surface finish; small details worth modelling. Ignore the background \
    and any people unless they are the object. Plain prose, under 220 words.
    """

    /// The first provider on this Mac that can look at a picture: Claude Code if installed, then any cloud API with a key.
    static var describer: Provider? {
        let order = ["claude-code", "anthropic", "openai", "gemini", "xai", "openrouter"]
        return order.map(Providers.find).first { p in
            p.id == "claude-code" ? CLIRunner.resolvedPath(ProviderSettings.executable(p)) != nil : ProviderSettings.problem(p) == nil
        }
    }

    static func describe(_ image: ReferenceImage) async throws -> String {
        guard let p = describer else {
            throw ForgeError("The local 3D Coder can't see pictures. Install Claude Code or add a Claude, OpenAI or Gemini API key in Settings › Model, and Sirpi will describe the picture for it.")
        }
        let messages = [["role": "user", "content": instruction]]
        let stream: AsyncThrowingStream<NativeEngine.Piece, Error>
        if p.kind == .cli {
            stream = CLIRunner.stream(p, messages: messages, image: image, systemOverride: "You describe objects precisely for 3D artists.", modelOverride: "haiku")
        } else {
            stream = RemoteEngine.stream(p, messages: messages, thinking: false, image: image, systemOverride: "You describe objects precisely for 3D artists.")
        }
        var text = ""
        for try await piece in stream { if case .content(let t, _) = piece { text += t } }
        let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw ForgeError("\(p.name) returned no description of the picture.") }
        return out
    }
}

// MARK: - Detail level

enum DetailLevel: Int, CaseIterable, Identifiable {
    case lowPoly = 0, detailed, high
    var id: Int { rawValue }
    static let key = "detailLevel"
    static var current: DetailLevel { DetailLevel(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .lowPoly }

    var title: String {
        switch self { case .lowPoly: "Low-poly"; case .detailed: "Detailed"; case .high: "High detail" }
    }
    var symbol: String {
        switch self { case .lowPoly: "cube"; case .detailed: "cube.transparent"; case .high: "sparkles" }
    }

    /// Appended to the user's request.
    var promptSuffix: String {
        switch self {
        case .lowPoly: return ""
        case .detailed: return """


            Make it a detailed, high-quality model rather than a blocky low-poly one: build it from at least 25 separate parts; \
            use 32 or more radial segments on round shapes; bevel hard edges (RoundedBoxGeometry from three/addons/geometries/RoundedBoxGeometry.js, \
            or ExtrudeGeometry with bevelEnabled); shape profiles with LatheGeometry, ExtrudeGeometry and TubeGeometry; use smooth shading \
            (flatShading false) with MeshStandardMaterial roughness and metalness per material; add small details such as trims, rims, rivets, \
            seams, straps and grooves.
            """
        case .high: return """


            Make it a finely detailed, production-quality model: build it from 60 or more separate parts; use 48 to 64 radial segments \
            on round shapes and enough height segments for smooth curves; bevel every hard edge (RoundedBoxGeometry from \
            three/addons/geometries/RoundedBoxGeometry.js, or ExtrudeGeometry with bevelEnabled and bevelSegments 3+); model organic and \
            curved forms with LatheGeometry, TubeGeometry along CatmullRomCurve3 paths and ExtrudeGeometry from Shape outlines; \
            use smooth shading with distinct MeshStandardMaterial / MeshPhysicalMaterial settings for metal, wood, cloth, glass and \
            leather; add fine details such as rivets, stitching, engraved bands, panel lines, trims, buckles and wear plates. Keep the \
            asset as one group so the GLB export contains all of it.
            """
        }
    }
}
