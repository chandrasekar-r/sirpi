import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Options

struct TurntableOptions: Equatable {
    enum Resolution: String, CaseIterable, Identifiable {
        case hd = "1280 × 720", fullHD = "1920 × 1080", square = "1080 × 1080", vertical = "1080 × 1920", uhd = "3840 × 2160"
        var id: String { rawValue }
        var size: (Int, Int) {
            switch self {
            case .hd: (1280, 720); case .fullHD: (1920, 1080); case .square: (1080, 1080)
            case .vertical: (1080, 1920); case .uhd: (3840, 2160)
            }
        }
        var title: String {
            switch self {
            case .hd: "720p"; case .fullHD: "1080p"; case .square: "Square"; case .vertical: "Vertical"; case .uhd: "4K"
            }
        }
    }
    enum Backdrop: String, CaseIterable, Identifiable {
        case dark, light, transparent, custom
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    enum Lighting: String, CaseIterable, Identifiable {
        case studio, soft, dramatic
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var seconds: Double = 6
    var fps = 30
    var resolution: Resolution = .fullHD
    var elevation: Double = 18
    var zoom: Double = 1
    var backdrop: Backdrop = .dark
    var customColor: Color = Color(red: 0.12, green: 0.30, blue: 0.45)
    var lighting: Lighting = .studio
    var clockwise = true
    var floorShadow = true
    var loops = 1

    var frames: Int { max(2, Int((seconds * Double(fps)).rounded())) }
    var transparent: Bool { backdrop == .transparent }
    var fileType: UTType { transparent ? .quickTimeMovie : .mpeg4Movie }
    var fileExtension: String { transparent ? "mov" : "mp4" }

    var backgroundHex: String? {
        switch backdrop {
        case .dark: "#1d1f22"
        case .light: "#e9eaec"
        case .transparent: nil
        case .custom:
            NSColor(customColor).usingColorSpace(.sRGB).map {
                String(format: "#%02x%02x%02x", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255))
            } ?? "#1d1f22"
        }
    }

    /// Options object passed to turntable.html. Frames cover one full turn; extra loops reuse them.
    var js: String { js(maxSide: nil) }

    /// `maxSide` shrinks the frame (same aspect) for quick previews.
    func js(maxSide: Int?) -> String {
        var (w, h) = resolution.size
        if let m = maxSide, max(w, h) > m {
            let s = Double(m) / Double(max(w, h)); w = Int(Double(w) * s); h = Int(Double(h) * s)
        }
        let bg = backgroundHex.map { "'\($0)'" } ?? "null"
        return "{ width: \(w), height: \(h), frames: \(max(2, frames / max(1, loops))), elevation: \(elevation), "
            + "background: \(bg), lighting: '\(lighting.rawValue)', direction: \(clockwise ? 1 : -1), "
            + "floor: \(floorShadow), zoom: \(zoom) }"
    }
}

// MARK: - Encoder

/// Writes frames to H.264 MP4, or HEVC with alpha in a QuickTime movie for transparent backgrounds.
final class TurntableEncoder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int32
    private let width: Int, height: Int

    init(url: URL, width: Int, height: Int, fps: Int, alpha: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: alpha ? .mov : .mp4)
        let pixels = Double(width * height)
        var settings: [String: Any] = [
            AVVideoCodecKey: alpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ]
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(pixels * Double(fps) * (alpha ? 0.2 : 0.15)),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ]
        if alpha { compression[kVTCompressionPropertyKey_TargetQualityForAlpha as String] = 0.9 }
        else { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        settings[AVVideoCompressionPropertiesKey] = compression
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ForgeError("This Mac can't encode \(alpha ? "HEVC with alpha" : "H.264") video.") }
        writer.add(input)
        guard writer.startWriting() else { throw ForgeError(writer.error?.localizedDescription ?? "Could not start the video file.") }
        writer.startSession(atSourceTime: .zero)
        self.fps = Int32(fps); self.width = width; self.height = height
    }

    func append(_ image: CGImage, index: Int) async throws {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        guard let pool = adaptor.pixelBufferPool else { throw ForgeError("The video encoder is not ready.") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw ForgeError("Out of video memory.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ForgeError("Could not draw a video frame.") }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
            throw ForgeError(writer.error?.localizedDescription ?? "Could not write a video frame.")
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ForgeError(writer.error?.localizedDescription ?? "Could not finish the video.") }
    }

    func cancel() { writer.cancelWriting() }
}

// MARK: - Sheet

struct TurntableSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let asset: Asset
    @State private var o = TurntableOptions()
    @State private var preview: NSImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Checkerboard().opacity(o.transparent ? 1 : 0)
                    if let preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    } else if let previewError {
                        Label(previewError, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                            .font(.callout).padding()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 320, height: 320)
                .background(Theme.cell, in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
                Text("Preview of the first frame. The video turns the asset one full circle per loop and ends where it starts, so it loops seamlessly.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Section("Video") {
                    Picker("Size", selection: $o.resolution) {
                        ForEach(TurntableOptions.Resolution.allCases) { Text("\($0.title) · \($0.rawValue)").tag($0) }
                    }
                    Picker("Length", selection: $o.seconds) {
                        ForEach([3.0, 5, 6, 8, 10, 15], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                    Picker("Frame rate", selection: $o.fps) {
                        Text("24 fps").tag(24); Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }
                    Stepper("Turns: \(o.loops)", value: $o.loops, in: 1...4)
                }
                Section("Camera") {
                    LabeledContent("Height") {
                        Slider(value: $o.elevation, in: -10...60, step: 1) { Text("Height") } .labelsHidden()
                        Text("\(Int(o.elevation))°").monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                    LabeledContent("Zoom") {
                        Slider(value: $o.zoom, in: 0.7...1.6) { Text("Zoom") } .labelsHidden()
                        Text(String(format: "%.1f×", o.zoom)).monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                    Picker("Direction", selection: $o.clockwise) {
                        Text("Clockwise").tag(true); Text("Counter-clockwise").tag(false)
                    }
                }
                Section("Look") {
                    Picker("Background", selection: $o.backdrop) {
                        ForEach(TurntableOptions.Backdrop.allCases) { Text($0.title).tag($0) }
                    }
                    if o.backdrop == .custom { ColorPicker("Colour", selection: $o.customColor, supportsOpacity: false) }
                    Picker("Lighting", selection: $o.lighting) {
                        ForEach(TurntableOptions.Lighting.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Floor shadow", isOn: $o.floorShadow)
                }
                if o.transparent {
                    Text("Transparent videos are saved as HEVC with alpha (.mov), which Final Cut Pro, DaVinci Resolve, Motion and Safari play with transparency.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .scrollContentBackground(.hidden)
        }
        .padding(20)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(o.frames) frames · \(o.fileExtension.uppercased())").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export Video…") {
                    let opts = o
                    dismiss()
                    Task { await app.exportTurntable(asset, options: opts) }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .onChange(of: o, initial: true) { _, _ in schedulePreview() }
        .onDisappear { previewTask?.cancel() }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let opts = o
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            do {
                if let img = try await app.turntablePreview(asset, options: opts), !Task.isCancelled { preview = img; previewError = nil }
            } catch {
                if !Task.isCancelled { previewError = error.localizedDescription }
            }
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
    }
}
