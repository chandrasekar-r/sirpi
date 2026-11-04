import Foundation
import Network
import AVFoundation
import CoreMedia
import CryptoKit
import ImageIO
import SwiftUI

// MARK: - Printer camera, built in
//
// Bambu printers serve their chamber camera in one of two ways:
//   • P2S, X1, H2 series: RTSP over TLS on port 322, H.264 video (rtsps://bblp:<code>@ip:322/streaming/live/1).
//   • P1 and A1 series: a TLS socket on port 6000 that sends one JPEG after another after an 80-byte login.
// Both need LAN mode on the printer; the P2S, X1 and H2 also need Developer Mode before port 322 opens.

enum CameraError: Error {
    case unreachable          // nothing listens on the port
    case refused              // the printer answered but would not stream
    case badCode              // the access code was rejected
    case unsupported(String)  // a codec we cannot show
    case closed
    case protocolError(String)
}

/// A TLS byte stream to the printer, which uses a self-signed certificate.
final class PrinterSocket: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "sirpi.camera.socket")
    private var bytes: [UInt8] = []
    private var pos = 0

    init(host: String, port: UInt16) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.noDelay = true
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                            using: NWParameters(tls: tls, tcp: tcp))
    }

    func open(timeout: Double = 6) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false   // only touched on `queue`
            func finish(_ error: Error?) {
                guard !done else { return }
                done = true
                if let error { conn.cancel(); c.resume(throwing: error) } else { c.resume() }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(nil)
                case .failed, .waiting: finish(CameraError.unreachable)
                case .cancelled: finish(CancellationError())
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(CameraError.unreachable) }
        }
    }

    func close() { conn.cancel() }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    private func fill() async throws {
        let chunk: Data = try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                if let data, !data.isEmpty { c.resume(returning: data) }
                else if let error { c.resume(throwing: error) }
                else if complete { c.resume(throwing: CameraError.closed) }
                else { c.resume(returning: Data()) }
            }
        }
        if pos > 1 << 20 { bytes.removeFirst(pos); pos = 0 }
        bytes.append(contentsOf: chunk)
    }

    private var available: Int { bytes.count - pos }

    func peekByte() async throws -> UInt8 {
        while available < 1 { try await fill() }
        return bytes[pos]
    }

    func read(_ n: Int) async throws -> [UInt8] {
        while available < n { try await fill() }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }

    /// Reads up to and including the delimiter.
    func read(until delimiter: [UInt8], limit: Int = 64 * 1024) async throws -> [UInt8] {
        var searchFrom = pos
        while true {
            if available >= delimiter.count {
                var i = searchFrom
                while i + delimiter.count <= bytes.count {
                    if bytes[i] == delimiter[0] && Array(bytes[i..<(i + delimiter.count)]) == delimiter {
                        return try await read(i + delimiter.count - pos)
                    }
                    i += 1
                }
                searchFrom = max(pos, bytes.count - delimiter.count + 1)
            }
            if available > limit { throw CameraError.protocolError("Response too long") }
            try await fill()
        }
    }
}

// MARK: P1 / A1: JPEG frames on port 6000

enum JPEGCamera {
    static func run(ip: String, code: String, onFrame: @escaping @Sendable (CGImage) -> Void) async throws {
        let socket = PrinterSocket(host: ip, port: 6000)
        try await withTaskCancellationHandler {
            try await socket.open()
            var login = Data()
            for v: UInt32 in [0x40, 0x3000, 0, 0] { withUnsafeBytes(of: v.littleEndian) { login.append(contentsOf: $0) } }
            login.append(fixed("bblp", 32)); login.append(fixed(code, 32))
            try await socket.send(login)
            var frames = 0
            while !Task.isCancelled {
                let header: [UInt8]
                do { header = try await socket.read(16) } catch { throw frames == 0 ? CameraError.refused : error }
                let size = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
                guard size > 100, size < 16 << 20 else {
                    // A short reply instead of a picture: login refused or camera closed to other apps.
                    throw frames == 0 ? CameraError.refused : CameraError.protocolError("Unexpected frame size \(size)")
                }
                let jpeg = Data(try await socket.read(size))
                guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                frames += 1
                onFrame(image)
            }
        } onCancel: { socket.close() }
    }

    private static func fixed(_ s: String, _ n: Int) -> Data {
        var d = Data(s.utf8.prefix(n)); d.append(Data(count: n - d.count)); return d
    }
}

// MARK: P2S / X1 / H2: RTSP over TLS on port 322

final class RTSPCamera: @unchecked Sendable {
    private let ip: String, code: String
    private let socket: PrinterSocket
    private let url: String
    private var cseq = 0
    private var auth: (scheme: String, realm: String, nonce: String)?
    private var session: String?
    private let video: VideoAssembler

    init(ip: String, code: String, port: UInt16 = 322, layer: AVSampleBufferDisplayLayer,
         onFirstFrame: @escaping @Sendable (CGSize) -> Void) {
        self.ip = ip; self.code = code
        socket = PrinterSocket(host: ip, port: port)
        url = "rtsps://\(ip):\(port)/streaming/live/1"
        video = VideoAssembler(layer: layer, onFirstFrame: onFirstFrame)
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await socket.open()
            _ = try await request("OPTIONS", url)
            let describe = try await request("DESCRIBE", url, headers: ["Accept": "application/sdp"])
            let sdp = String(decoding: describe.body, as: UTF8.self)
            let base = describe.headers["content-base"] ?? url
            let track = try parseSDP(sdp, base: base)
            let setup = try await request("SETUP", track, headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"])
            session = setup.headers["session"]?.split(separator: ";").first.map(String.init)
            _ = try await request("PLAY", base, headers: ["Range": "npt=0.000-"])

            let keepAlive = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(25))
                    guard let self, !Task.isCancelled else { return }
                    try? await self.socket.send(self.message("GET_PARAMETER", self.url, headers: [:]))
                }
            }
            defer { keepAlive.cancel() }
            try await readStream()
        } onCancel: { socket.close() }
    }

    // RTSP requests

    private func message(_ method: String, _ uri: String, headers: [String: String]) -> Data {
        cseq += 1
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: Sirpi"]
        if let session { lines.append("Session: \(session)") }
        if let auth { lines.append("Authorization: " + authorization(method: method, uri: uri, auth)) }
        for (k, v) in headers { lines.append("\(k): \(v)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func authorization(method: String, uri: String, _ a: (scheme: String, realm: String, nonce: String)) -> String {
        if a.scheme == "basic" { return "Basic " + Data("bblp:\(code)".utf8).base64EncodedString() }
        func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        let response = md5("\(md5("bblp:\(a.realm):\(code)")):\(a.nonce):\(md5("\(method):\(uri)"))")
        return "Digest username=\"bblp\", realm=\"\(a.realm)\", nonce=\"\(a.nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }

    private func request(_ method: String, _ uri: String, headers: [String: String] = [:]) async throws
        -> (status: Int, headers: [String: String], body: Data) {
        for attempt in 0..<2 {
            try await socket.send(message(method, uri, headers: headers))
            let r = try await readResponse()
            if r.status == 401, attempt == 0, auth == nil, let challenge = pickChallenge(r.authenticate) {
                auth = challenge; continue
            }
            if r.status == 401 { throw CameraError.badCode }
            if r.status == 454 || r.status == 404 || r.status == 503 { throw CameraError.refused }
            guard (200..<300).contains(r.status) else { throw CameraError.protocolError("\(method) failed with \(r.status)") }
            return (r.status, r.headers, r.body)
        }
        throw CameraError.badCode
    }

    private func pickChallenge(_ lines: [String]) -> (scheme: String, realm: String, nonce: String)? {
        func value(_ key: String, in s: String) -> String {
            guard let r = s.range(of: key + "=\"") else { return "" }
            return String(s[r.upperBound...].prefix { $0 != "\"" })
        }
        if let d = lines.first(where: { $0.lowercased().hasPrefix("digest") }) {
            return ("digest", value("realm", in: d), value("nonce", in: d))
        }
        if lines.contains(where: { $0.lowercased().hasPrefix("basic") }) { return ("basic", "", "") }
        return nil
    }

    private func readResponse() async throws -> (status: Int, headers: [String: String], authenticate: [String], body: Data) {
        // Skip any interleaved media that arrives before the reply.
        while try await socket.peekByte() == 0x24 {
            let h = try await socket.read(4)
            _ = try await socket.read(Int(h[2]) << 8 | Int(h[3]))
        }
        let head = String(decoding: try await socket.read(until: Array("\r\n\r\n".utf8)), as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw CameraError.protocolError("Empty RTSP reply") }
        let statusLine = lines.removeFirst()
        guard statusLine.hasPrefix("RTSP/") else { throw CameraError.protocolError("Not an RTSP reply") }
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        var headers: [String: String] = [:], authenticate: [String] = []
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
            if k == "www-authenticate" { authenticate.append(v) }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = length > 0 ? Data(try await socket.read(length)) : Data()
        return (status, headers, authenticate, body)
    }

    /// Finds the video track's control URL and any SPS/PPS sent in the description.
    private func parseSDP(_ sdp: String, base: String) throws -> String {
        var inVideo = false, control: String?
        for raw in sdp.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("m=") { inVideo = l.hasPrefix("m=video"); continue }
            guard inVideo else { continue }
            if l.hasPrefix("a=rtpmap:") {
                let codec = l.uppercased()
                if !codec.contains("H264") { throw CameraError.unsupported(String(l.dropFirst(9))) }
            } else if l.hasPrefix("a=control:") {
                control = String(l.dropFirst(10))
            } else if l.hasPrefix("a=fmtp:"), let r = l.range(of: "sprop-parameter-sets=") {
                let sets = l[r.upperBound...].prefix { $0 != ";" }.split(separator: ",")
                for s in sets { if let d = Data(base64Encoded: String(s)) { video.parameterSet([UInt8](d)) } }
            }
        }
        guard let control, control != "*" else { return base }
        if control.lowercased().hasPrefix("rtsp") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    // Media

    private func readStream() async throws {
        while !Task.isCancelled {
            if try await socket.peekByte() == 0x24 {
                let h = try await socket.read(4)
                let payload = try await socket.read(Int(h[2]) << 8 | Int(h[3]))
                if h[1] == 0 { video.rtp(payload) }
            } else {
                _ = try await readResponse()   // a reply to a keep-alive
            }
        }
    }
}

/// Rebuilds H.264 frames from RTP packets and shows them on a display layer, which decodes them.
final class VideoAssembler: @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer
    private let onFirstFrame: @Sendable (CGSize) -> Void
    private var sps: [UInt8]?, pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var nals: [[UInt8]] = []
    private var fragment: [UInt8]?
    private var sawKeyFrame = false
    private var shown = false

    init(layer: AVSampleBufferDisplayLayer, onFirstFrame: @escaping @Sendable (CGSize) -> Void) {
        self.layer = layer; self.onFirstFrame = onFirstFrame
    }

    func parameterSet(_ nal: [UInt8]) {
        guard let t = nal.first.map({ $0 & 0x1f }) else { return }
        if t == 7, nal != sps { sps = nal; format = nil }
        if t == 8, nal != pps { pps = nal; format = nil }
    }

    func rtp(_ p: [UInt8]) {
        guard p.count > 12, p[0] >> 6 == 2 else { return }
        var offset = 12 + Int(p[0] & 0x0f) * 4
        if p[0] & 0x10 != 0, p.count >= offset + 4 {
            offset += 4 + (Int(p[offset + 2]) << 8 | Int(p[offset + 3])) * 4
        }
        var end = p.count
        if p[0] & 0x20 != 0, let pad = p.last { end -= Int(pad) }
        guard offset < end else { return }
        let marker = p[1] & 0x80 != 0
        let payload = Array(p[offset..<end])
        let type = payload[0] & 0x1f
        switch type {
        case 1...23:
            nals.append(payload)
        case 24: // STAP-A
            var i = 1
            while i + 2 <= payload.count {
                let n = Int(payload[i]) << 8 | Int(payload[i + 1]); i += 2
                guard n > 0, i + n <= payload.count else { break }
                nals.append(Array(payload[i..<(i + n)])); i += n
            }
        case 28: // FU-A
            guard payload.count > 2 else { return }
            let start = payload[1] & 0x80 != 0, stop = payload[1] & 0x40 != 0
            if start { fragment = [(payload[0] & 0xe0) | (payload[1] & 0x1f)] }
            fragment?.append(contentsOf: payload[2...])
            if stop, let f = fragment { nals.append(f); fragment = nil }
        default:
            break
        }
        if marker { flush() }
    }

    private func flush() {
        let unit = nals; nals = []
        var frame: [[UInt8]] = [], key = false
        for nal in unit {
            switch nal[0] & 0x1f {
            case 7, 8: parameterSet(nal)
            case 9: break   // access unit delimiter
            case 5: key = true; frame.append(nal)
            default: frame.append(nal)
            }
        }
        guard !frame.isEmpty else { return }
        if format == nil, let sps, let pps { format = Self.makeFormat(sps: sps, pps: pps) }
        guard let format else { return }
        if key { sawKeyFrame = true }
        guard sawKeyFrame, let sample = Self.makeSample(frame, format: format) else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush(); sawKeyFrame = key; if !key { return } }
        renderer.enqueue(sample)
        if !shown {
            shown = true
            let d = CMVideoFormatDescriptionGetDimensions(format)
            onFirstFrame(CGSize(width: Int(d.width), height: Int(d.height)))
        }
    }

    private static func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var out: CMFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [sps.count, pps.count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
        }
        return out
    }

    private static func makeSample(_ nals: [[UInt8]], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc: [UInt8] = []
        for n in nals {
            let len = UInt32(n.count).bigEndian
            withUnsafeBytes(of: len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: n)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                  offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - Model

@Observable @MainActor
final class PrinterCamera {
    enum State: Equatable { case idle, connecting, live, failed(String) }
    var state: State = .idle
    var source = ""
    var videoSize = CGSize(width: 16, height: 9)

    @ObservationIgnored let videoLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored let imageLayer = CALayer()
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        videoLayer.videoGravity = .resizeAspect
        imageLayer.contentsGravity = .resizeAspect
    }

    func start(ip: String, code: String) {
        stop()
        guard !ip.isEmpty, !code.isEmpty else {
            state = .failed("Set up the printer first: Print stage, or Printer Settings, needs its IP address and access code.")
            return
        }
        state = .connecting
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        imageLayer.contents = nil
        let layer = videoLayer
        task = Task.detached { [weak self] in
            do {
                do {
                    let rtsp = RTSPCamera(ip: ip, code: code, layer: layer) { size in
                        Task { @MainActor in self?.went(live: "Live video", size: size) }
                    }
                    try await rtsp.run()
                } catch CameraError.unreachable {
                    // No RTSP service: P1 and A1 printers stream JPEGs on port 6000 instead.
                    try await JPEGCamera.run(ip: ip, code: code) { image in
                        Task { @MainActor in
                            guard let self else { return }
                            if self.state != .live { self.went(live: "Live pictures", size: CGSize(width: image.width, height: image.height)) }
                            CATransaction.begin(); CATransaction.setDisableActions(true)
                            self.imageLayer.contents = image
                            CATransaction.commit()
                        }
                    }
                }
                await MainActor.run { self?.ended(nil) }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.ended(error) }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        if state == .connecting || state == .live { state = .idle }
    }

    private func went(live source: String, size: CGSize) {
        guard task != nil else { return }
        self.source = source; videoSize = size; state = .live
    }

    private func ended(_ error: Error?) {
        guard task != nil else { return }
        task = nil
        state = .failed(Self.message(for: error))
    }

    static let unlockSteps = "On the printer's screen open Settings, then Network, and turn on LAN Only Mode and Developer Mode. Then try again."

    static func message(for error: Error?) -> String {
        switch error as? CameraError {
        case .unreachable?, .refused?:
            return "The printer isn't sharing its camera with other apps yet. " + unlockSteps
        case .badCode?:
            return "The printer rejected the access code. Check it on the printer's screen (Settings, then Network) and update it in Printer Settings."
        case .unsupported(let codec)?:
            return "The camera sends video Sirpi can't show yet (\(codec))."
        case .closed?, nil:
            return "The camera stream stopped. The printer may have gone to sleep or lost Wi-Fi."
        case .protocolError(let why)?:
            return "The camera answered in a way Sirpi didn't expect: \(why)."
        }
    }
}

// MARK: - Views

struct CameraLayerView: NSViewRepresentable {
    let camera: PrinterCamera

    final class Host: NSView {
        var sublayersToFit: [CALayer] = []
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for l in sublayersToFit { l.frame = bounds }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host {
        let v = Host()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        for l in [camera.videoLayer, camera.imageLayer] { v.layer?.addSublayer(l) }
        v.sublayersToFit = [camera.videoLayer, camera.imageLayer]
        return v
    }

    func updateNSView(_ nsView: Host, context: Context) {}
}

struct CameraWindow: View {
    @Environment(AppModel.self) private var app
    @State private var camera = PrinterCamera()

    var body: some View {
        let p = app.printer
        ZStack {
            Color.black
            CameraLayerView(camera: camera)
                .aspectRatio(camera.videoSize, contentMode: .fit)
            switch camera.state {
            case .idle, .connecting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to the camera…").foregroundStyle(.secondary)
                }
            case .failed(let why):
                VStack(spacing: 14) {
                    Image(systemName: "video.slash").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(why).multilineTextAlignment(.center).frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { connect() }.buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                }
                .padding(24)
            case .live:
                EmptyView()
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle("Printer Camera")
        .navigationSubtitle(camera.state == .live ? camera.source : "")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { p.status.chamberLight }, set: { p.setLight($0) })) {
                    Label("Chamber Light", systemImage: p.status.chamberLight ? "lightbulb.fill" : "lightbulb")
                }
                .disabled(p.connection != .connected)
                .help("Chamber light")
                Button { connect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    .help("Reconnect to the camera")
            }
        }
        .onAppear { connect() }
        .onDisappear { camera.stop() }
    }

    private func connect() {
        camera.start(ip: Settings.printerIP, code: app.printer.accessCode)
    }
}

/// Menu item and buttons that open the camera window.
struct WatchCameraButton: View {
    @Environment(\.openWindow) private var openWindow
    var title = "Watch Camera"
    var body: some View {
        Button(title) { openWindow(id: "camera") }
    }
}
