import Foundation
import Network
import Observation

// MARK: - Minimal MQTT 3.1.1 client over TLS (Bambu printers use self-signed certs on :8883)

final class MQTTClient: @unchecked Sendable {
    enum Event { case connected, disconnected(String), message(topic: String, payload: Data) }

    private let queue = DispatchQueue(label: "af.mqtt")
    private var conn: NWConnection?
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var packetId: UInt16 = 1
    var onEvent: ((Event) -> Void)?

    func connect(host: String, port: UInt16 = 8883, username: String, password: String, clientId: String) {
        disconnect()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 8; tcp.enableKeepalive = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                             using: NWParameters(tls: tls, tcp: tcp))
        conn = c
        buffer = Data()
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.send(self.connectPacket(clientId: clientId, user: username, pass: password))
                self.receive()
            case .failed(let e): self.emit(.disconnected(e.localizedDescription)); self.cleanup()
            case .waiting(let e): self.emit(.disconnected("Waiting: \(e.localizedDescription)"))
            case .cancelled: break
            default: break
            }
        }
        c.start(queue: queue)
    }

    func disconnect() {
        if let c = conn { c.send(content: Data([0xE0, 0x00]), completion: .idempotent); c.cancel() }
        cleanup()
    }

    private func cleanup() { pingTimer?.cancel(); pingTimer = nil; conn = nil }

    func subscribe(_ topic: String) {
        var vh = Data(); vh.append(u16(nextId())); vh.append(str(topic)); vh.append(0x00)
        send(packet(0x82, vh))
    }

    func publish(_ topic: String, _ payload: Data) {
        var vh = Data(); vh.append(str(topic)); vh.append(payload)
        send(packet(0x30, vh))
    }

    // MARK: encoding
    private func nextId() -> UInt16 { packetId = packetId &+ 1; if packetId == 0 { packetId = 1 }; return packetId }
    private func u16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    private func str(_ s: String) -> Data { let d = Data(s.utf8); return u16(UInt16(d.count)) + d }
    private func packet(_ header: UInt8, _ body: Data) -> Data {
        var d = Data([header]); var len = body.count
        repeat { var b = UInt8(len % 128); len /= 128; if len > 0 { b |= 0x80 }; d.append(b) } while len > 0
        return d + body
    }
    private func connectPacket(clientId: String, user: String, pass: String) -> Data {
        var vh = str("MQTT"); vh.append(0x04); vh.append(0xC2); vh.append(u16(60))
        vh.append(str(clientId)); vh.append(str(user)); vh.append(str(pass))
        return packet(0x10, vh)
    }
    private func send(_ d: Data) { conn?.send(content: d, completion: .contentProcessed { _ in }) }
    private func emit(_ e: Event) { onEvent?(e) }

    private func startPing() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.send(Data([0xC0, 0x00])) }
        t.resume(); pingTimer = t
    }

    // MARK: decoding
    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if let err { self.emit(.disconnected(err.localizedDescription)); self.cleanup(); return }
            if done { self.emit(.disconnected("Connection closed by printer")); self.cleanup(); return }
            self.receive()
        }
    }

    private func drain() {
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(5))
            var mult = 1, len = 0, i = 1
            var complete = false
            while i < bytes.count {
                len += Int(bytes[i] & 0x7F) * mult
                if bytes[i] & 0x80 == 0 { complete = true; break }
                mult *= 128; i += 1
            }
            guard complete else { return }
            let headerLen = i + 1
            guard buffer.count >= headerLen + len else { return }
            let type = bytes[0] >> 4
            let body = Data(buffer[buffer.startIndex + headerLen ..< buffer.startIndex + headerLen + len])
            buffer.removeFirst(headerLen + len)
            handle(type: type, flags: bytes[0] & 0x0F, body: body)
        }
    }

    private func handle(type: UInt8, flags: UInt8, body: Data) {
        let b = [UInt8](body)
        switch type {
        case 2: // CONNACK
            let code = b.count > 1 ? b[1] : 255
            if code == 0 { startPing(); emit(.connected) }
            else {
                let reason = [1: "unacceptable protocol", 2: "client id rejected", 3: "server unavailable",
                              4: "bad username or access code", 5: "not authorized (check access code / LAN + Developer Mode)"][Int(code)] ?? "code \(code)"
                emit(.disconnected("Printer refused connection: \(reason)")); disconnect()
            }
        case 3: // PUBLISH
            guard b.count >= 2 else { return }
            let tlen = Int(b[0]) << 8 | Int(b[1])
            guard b.count >= 2 + tlen else { return }
            let topic = String(decoding: b[2..<2 + tlen], as: UTF8.self)
            var start = 2 + tlen
            if (flags >> 1) & 0x03 > 0 { start += 2 }
            emit(.message(topic: topic, payload: Data(b[min(start, b.count)...])))
        default: break // SUBACK, PINGRESP
        }
    }
}

// MARK: - Printer status model

struct AMSTray: Identifiable, Hashable, Codable {
    var id: Int            // global slot index (ams * 4 + tray), 254 = external spool
    var amsId: Int
    var slotId: Int
    var type: String
    var colorHex: String
    var remain: Int?
    /// Bambu filament ID from the spool's RFID tag or the slot setting, e.g. "GFA00" (Bambu PLA Basic).
    var filamentId: String? = nil
    /// Product name shown on the printer, e.g. "PLA Basic" or "PETG HF".
    var subBrand: String? = nil
    var tempMin: Int? = nil
    var tempMax: Int? = nil
    var name: String { subBrand.flatMap { $0.isEmpty ? nil : $0 } ?? type }
    var isExternal: Bool { id == 254 }
    var label: String { isExternal ? "External spool" : "AMS \(amsId + 1) · Slot \(slotId + 1)" }
}

struct PrinterStatus {
    var gcodeState = "—"
    var percent = 0
    var remainingMinutes = 0
    var layer = 0
    var totalLayers = 0
    var jobName = ""
    var nozzleTemp = 0.0, nozzleTarget = 0.0
    var bedTemp = 0.0, bedTarget = 0.0
    var chamberTemp: Double?
    var partFan = 0, auxFan = 0, chamberFan = 0   // percent
    var speedLevel = 2
    var chamberLight = false
    var wifi = ""
    var hmsCount = 0
    var printError = 0
    var trays: [AMSTray] = []
    var sdcard: Bool?
    var firmware = ""
    var trayNow: Int?             // global AMS slot currently feeding (255 = none)

    var isPrinting: Bool { ["RUNNING", "PREPARE", "SLICING"].contains(gcodeState) }
    var isPaused: Bool { gcodeState == "PAUSE" }
    var stateLabel: String {
        switch gcodeState {
        case "IDLE": "Idle"; case "RUNNING": "Printing"; case "PAUSE": "Paused"; case "FINISH": "Finished"
        case "FAILED": "Failed"; case "PREPARE": "Preparing"; case "SLICING": "Slicing"
        default: gcodeState
        }
    }
}

// MARK: - Printer manager

@Observable @MainActor
final class PrinterManager {
    enum Connection: Equatable { case disconnected, connecting, connected, failed(String) }

    var connection: Connection = .disconnected
    var status = PrinterStatus()
    var raw: [String: Any] = [:]
    var log: [String] = []
    var uploadProgress: Double?
    var lastReport: Date?

    /// Called when a job ends: (job name, success).
    @ObservationIgnored var onJobEnded: ((String, Bool) -> Void)?
    private let mqtt = MQTTClient()
    private var seq = 1000
    private var serial = ""
    private var wantConnected = false

    init() {
        mqtt.onEvent = { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
    }

    var accessCode: String {
        get { SecretStore.get("printer-access-code") ?? "" }
        set { SecretStore.set(newValue, for: "printer-access-code") }
    }

    var isConfigured: Bool { !Settings.printerIP.isEmpty && !Settings.printerSerial.isEmpty && !accessCode.isEmpty }

    func connect() {
        guard isConfigured else { connection = .failed("Enter IP, serial number and access code first."); return }
        serial = Settings.printerSerial
        wantConnected = true
        connection = .connecting
        addLog("Connecting to \(Settings.printerIP):8883…")
        mqtt.connect(host: Settings.printerIP, username: "bblp", password: accessCode,
                     clientId: "assetforge-\(UUID().uuidString.prefix(8))")
    }

    func disconnect() {
        wantConnected = false
        mqtt.disconnect()
        connection = .disconnected
    }

    private func handle(_ e: MQTTClient.Event) {
        switch e {
        case .connected:
            connection = .connected
            addLog("Connected. Subscribing to device/\(serial)/report")
            mqtt.subscribe("device/\(serial)/report")
            pushAll()
        case .disconnected(let why):
            addLog(why)
            if connection == .connecting || connection == .connected { connection = .failed(why) }
            if wantConnected, case .failed = connection {
                Task { try? await Task.sleep(for: .seconds(5)); if self.wantConnected, self.connection != .connected { self.connect() } }
            }
        case .message(_, let payload):
            guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
            if let p = obj["print"] as? [String: Any] {
                if let cmd = p["command"] as? String, cmd != "push_status" {
                    addLog("← \(cmd): \((p["result"] as? String) ?? (p["reason"] as? String) ?? "ok")")
                }
                if p["command"] as? String == "push_status" {
                    raw = Self.merge(raw, p)
                    parse()
                    lastReport = Date()
                }
            }
            if let info = obj["info"] as? [String: Any], let mods = info["module"] as? [[String: Any]],
               let ota = mods.first(where: { ($0["name"] as? String) == "ota" }), let v = ota["sw_ver"] as? String {
                status.firmware = v
            }
        }
    }

    private static func text(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }
    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }

    // MARK: last known AMS

    private static let traysKey = "lastKnownTrays"
    private static func saveTrays(_ t: [AMSTray]) {
        if let d = try? JSONEncoder().encode(t) { UserDefaults.standard.set(d, forKey: traysKey) }
    }
    /// The AMS as last reported, so slicing still uses the loaded filaments while the printer is off.
    static var lastKnownTrays: [AMSTray] {
        guard let d = UserDefaults.standard.data(forKey: traysKey) else { return [] }
        return (try? JSONDecoder().decode([AMSTray].self, from: d)) ?? []
    }
    /// Live trays when connected, otherwise the last ones seen.
    var knownTrays: [AMSTray] { status.trays.isEmpty ? Self.lastKnownTrays : status.trays }

    private static func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b {
            if let vd = v as? [String: Any], let ad = out[k] as? [String: Any] { out[k] = merge(ad, vd) } else { out[k] = v }
        }
        return out
    }

    private func parse() {
        let p = raw
        func num(_ k: String) -> Double? {
            if let d = p[k] as? Double { return d }
            if let i = p[k] as? Int { return Double(i) }
            if let s = p[k] as? String { return Double(s) }
            return nil
        }
        var s = status
        s.gcodeState = (p["gcode_state"] as? String) ?? s.gcodeState
        s.percent = Int(num("mc_percent") ?? Double(s.percent))
        s.remainingMinutes = Int(num("mc_remaining_time") ?? Double(s.remainingMinutes))
        s.layer = Int(num("layer_num") ?? Double(s.layer))
        s.totalLayers = Int(num("total_layer_num") ?? Double(s.totalLayers))
        s.jobName = (p["subtask_name"] as? String) ?? s.jobName
        s.nozzleTemp = num("nozzle_temper") ?? s.nozzleTemp
        s.nozzleTarget = num("nozzle_target_temper") ?? s.nozzleTarget
        s.bedTemp = num("bed_temper") ?? s.bedTemp
        s.bedTarget = num("bed_target_temper") ?? s.bedTarget
        if let c = num("chamber_temper") { s.chamberTemp = c }
        if let dev = p["device"] as? [String: Any] {
            // Newer firmware (H2/P2 family) packs temps as (target << 16 | current)
            func unpack(_ any: Any?) -> (Double, Double)? {
                guard let v = any as? Int else { return nil }
                return (Double(v & 0xFFFF), Double(v >> 16))
            }
            if let ctc = (dev["ctc"] as? [String: Any])?["info"] as? [String: Any], let t = unpack(ctc["temp"]) { s.chamberTemp = t.0 }
            if num("nozzle_temper") == nil, let ex = ((dev["extruder"] as? [String: Any])?["info"] as? [[String: Any]])?.first,
               let t = unpack(ex["temp"]) { s.nozzleTemp = t.0; s.nozzleTarget = t.1 }
            if num("bed_temper") == nil, let bed = (dev["bed"] as? [String: Any])?["info"] as? [String: Any],
               let t = unpack(bed["temp"]) { s.bedTemp = t.0; s.bedTarget = t.1 }
        }
        // Fan speeds are reported 0-15
        func fan(_ k: String) -> Int? { num(k).map { Int(($0 / 15.0 * 100).rounded()) } }
        s.partFan = fan("cooling_fan_speed") ?? s.partFan
        s.auxFan = fan("big_fan1_speed") ?? s.auxFan
        s.chamberFan = fan("big_fan2_speed") ?? s.chamberFan
        s.speedLevel = Int(num("spd_lvl") ?? Double(s.speedLevel))
        if let lights = p["lights_report"] as? [[String: Any]],
           let ch = lights.first(where: { ($0["node"] as? String) == "chamber_light" }) {
            s.chamberLight = (ch["mode"] as? String) == "on"
        }
        s.wifi = (p["wifi_signal"] as? String) ?? s.wifi
        s.hmsCount = (p["hms"] as? [Any])?.count ?? s.hmsCount
        s.printError = Int(num("print_error") ?? 0)
        if let sd = p["sdcard"] as? Bool { s.sdcard = sd }
        if let ams = p["ams"] as? [String: Any], let now = (ams["tray_now"] as? String).flatMap(Int.init) ?? (ams["tray_now"] as? Int) {
            s.trayNow = now
        }

        var trays: [AMSTray] = []
        if let ams = (p["ams"] as? [String: Any])?["ams"] as? [[String: Any]] {
            for unit in ams {
                let aid = Int((unit["id"] as? String) ?? "") ?? (unit["id"] as? Int) ?? 0
                for t in (unit["tray"] as? [[String: Any]]) ?? [] {
                    let tid = Int((t["id"] as? String) ?? "") ?? (t["id"] as? Int) ?? 0
                    guard let type = t["tray_type"] as? String, !type.isEmpty else { continue }
                    trays.append(AMSTray(id: aid * 4 + tid, amsId: aid, slotId: tid, type: type,
                                         colorHex: String(((t["tray_color"] as? String) ?? "888888FF").prefix(6)),
                                         remain: t["remain"] as? Int, filamentId: Self.text(t["tray_info_idx"]),
                                         subBrand: Self.text(t["tray_sub_brands"]),
                                         tempMin: Self.int(t["nozzle_temp_min"]), tempMax: Self.int(t["nozzle_temp_max"])))
                }
            }
        }
        if let vt = p["vt_tray"] as? [String: Any], let type = vt["tray_type"] as? String, !type.isEmpty {
            trays.append(AMSTray(id: 254, amsId: 255, slotId: 0, type: type,
                                 colorHex: String(((vt["tray_color"] as? String) ?? "888888FF").prefix(6)), remain: nil,
                                 filamentId: Self.text(vt["tray_info_idx"]), subBrand: Self.text(vt["tray_sub_brands"]),
                                 tempMin: Self.int(vt["nozzle_temp_min"]), tempMax: Self.int(vt["nozzle_temp_max"])))
        }
        s.trays = trays
        if !trays.isEmpty && trays != status.trays { Self.saveTrays(trays) }
        let was = status.gcodeState
        status = s
        if ["RUNNING", "PAUSE", "PREPARE"].contains(was), ["FINISH", "FAILED"].contains(s.gcodeState) {
            onJobEnded?(s.jobName, s.gcodeState == "FINISH")
        }
    }

    // MARK: commands

    private func send(_ obj: [String: Any]) {
        guard connection == .connected, let data = try? JSONSerialization.data(withJSONObject: obj) else {
            addLog("Not connected."); return
        }
        mqtt.publish("device/\(serial)/request", data)
    }

    private func nextSeq() -> String { seq += 1; return String(seq) }

    func pushAll() { send(["pushing": ["sequence_id": nextSeq(), "command": "pushall", "version": 1, "push_target": 1]]) }
    func pause() { send(["print": ["sequence_id": nextSeq(), "command": "pause", "param": ""]]) }
    func resume() { send(["print": ["sequence_id": nextSeq(), "command": "resume", "param": ""]]) }
    func stop() { send(["print": ["sequence_id": nextSeq(), "command": "stop", "param": ""]]) }
    func setSpeed(_ level: Int) { send(["print": ["sequence_id": nextSeq(), "command": "print_speed", "param": String(level)]]) }
    func gcode(_ line: String) {
        addLog("→ \(line)")
        send(["print": ["sequence_id": nextSeq(), "command": "gcode_line", "param": line + " \n"]])
    }
    func setNozzle(_ t: Int) { gcode("M104 S\(t)") }
    func setBed(_ t: Int) { gcode("M140 S\(t)") }
    /// fan: 1 = part, 2 = aux, 3 = chamber. percent 0-100.
    func setFan(_ fan: Int, percent: Int) { gcode("M106 P\(fan) S\(Int(Double(percent) / 100 * 255))") }
    func home() { gcode("G28") }
    func setLight(_ on: Bool) {
        send(["system": ["sequence_id": nextSeq(), "command": "ledctrl", "led_node": "chamber_light",
                         "led_mode": on ? "on" : "off", "led_on_time": 500, "led_off_time": 500,
                         "loop_times": 0, "interval_time": 0]])
        status.chamberLight = on
    }

    // MARK: upload + print

    func upload(_ file: URL, as name: String) async throws {
        uploadProgress = 0
        defer { uploadProgress = nil }
        addLog("Uploading \(name) via FTPS…")
        // Credentials go through a curl config on stdin so the access code never appears in `ps`.
        let config = "user = \"bblp:\(accessCode)\"\n"
        let r = await Shell.run("/usr/bin/curl", [
            "-sS", "-k", "--ssl-reqd", "--connect-timeout", "10", "--max-time", "600",
            "-K", "-", "-T", file.path, "ftps://\(Settings.printerIP):990/\(name)",
        ], stdin: config)
        guard r.status == 0 else {
            throw ForgeError("Upload failed (curl \(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)). Is an SD card inserted and LAN mode on?")
        }
        uploadProgress = 1
        addLog("Upload complete.")
    }

    struct PrintOptions {
        var bedLeveling = true
        var flowCalibration = false
        var timelapse = false
        /// One entry per filament in the sliced file (filament 1, 2, …). nil = external spool (single-colour only).
        var mapping: [AMSTray?] = [nil]
        var bedType = "textured_plate"
    }

    func startPrint(threeMF: URL, name: String, options o: PrintOptions) async throws {
        guard connection == .connected else { throw ForgeError("Printer is not connected.") }
        let usesAMS = o.mapping.contains { $0.map { !$0.isExternal } ?? false }
        if o.mapping.count > 1 && o.mapping.contains(where: { $0 == nil || $0!.isExternal }) {
            throw ForgeError("Multi-colour prints need every colour mapped to an AMS slot.")
        }
        let remote = name.hasSuffix(".gcode.3mf") ? name : name + ".gcode.3mf"
        let data = try Data(contentsOf: threeMF)
        try await upload(threeMF, as: remote)
        let mapping: [Int] = o.mapping.map { t in usesAMS ? (t?.id ?? -1) : -1 }
        let mapping2: [[String: Int]] = o.mapping.map { t in
            if usesAMS, let t, !t.isExternal { return ["ams_id": t.amsId, "slot_id": t.slotId] }
            return ["ams_id": 255, "slot_id": 0]
        }
        let cmd: [String: Any] = ["print": [
            "sequence_id": nextSeq(), "command": "project_file", "param": "Metadata/plate_1.gcode",
            "project_id": "0", "profile_id": "0", "task_id": "0", "subtask_id": "0",
            "subtask_name": String(remote.dropLast(".gcode.3mf".count)),
            "file": remote, "url": "ftp://\(remote)", "md5": data.md5Hex,
            "timelapse": o.timelapse, "bed_type": o.bedType,
            "bed_leveling": o.bedLeveling, "auto_bed_leveling": o.bedLeveling ? 1 : 0,
            "flow_cali": o.flowCalibration, "extrude_cali_flag": o.flowCalibration ? 1 : 0,
            "vibration_cali": false, "layer_inspect": true, "cfg": "0",
            "use_ams": usesAMS, "ams_mapping": mapping, "ams_mapping2": mapping2,
        ] as [String: Any]]
        addLog("→ project_file \(remote) (\(o.mapping.count) filament\(o.mapping.count == 1 ? "" : "s"))")
        send(cmd)
    }

    func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}

// MARK: - SSDP discovery (Bambu printers announce on UDP 2021)

struct DiscoveredPrinter: Identifiable, Hashable {
    var id: String { serial }
    var ip: String
    var serial: String
    var model: String
    var name: String
}

@Observable @MainActor
final class PrinterDiscovery {
    var found: [DiscoveredPrinter] = []
    var scanning = false
    var didScanOnce = false

    func scan(seconds: Double = 12) {
        guard !scanning else { return }
        scanning = true
        Task {
            let results = await Task.detached { Self.listen(seconds: seconds) }.value
            do {
                for r in results where !self.found.contains(r) { self.found.append(r) }
                self.scanning = false
                self.didScanOnce = true
            }
        }
    }

    /// Asks printers to answer (SSDP M-SEARCH) from a free port, so it works while Bambu Studio holds port 2021, and
    /// also listens for their periodic announcements on 2021 when that port is free.
    nonisolated private static func listen(seconds: Double) -> [DiscoveredPrinter] {
        func udpSocket(port: UInt16) -> Int32? {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return nil }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(port).bigEndian; addr.sin_addr.s_addr = INADDR_ANY
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if ok != 0 { close(fd); return nil }
            return fd
        }
        guard let search = udpSocket(port: 0) else { return [] }
        let passive = udpSocket(port: 2021)   // nil when another app (e.g. Bambu Studio) holds the port
        defer { close(search); if let passive { close(passive) } }

        let query = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
            + "ST: urn:bambulab-com:device:3dprinter:1\r\n\r\n"
        func send(to ip: String, port: UInt16) {
            var dst = sockaddr_in()
            dst.sin_family = sa_family_t(AF_INET); dst.sin_port = in_port_t(port).bigEndian
            inet_pton(AF_INET, ip, &dst.sin_addr)
            let bytes = Array(query.utf8)
            _ = withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(search, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        func searchAll() {
            for (ip, port) in [("239.255.255.250", UInt16(1990)), ("239.255.255.250", 2021), ("255.255.255.255", 2021), ("255.255.255.255", 1990)] {
                send(to: ip, port: port)
            }
        }

        var out: [String: DiscoveredPrinter] = [:]
        let end = Date().addingTimeInterval(seconds)
        var lastSearch = Date.distantPast
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            if Date().timeIntervalSince(lastSearch) > 3 { searchAll(); lastSearch = Date() }
            var fds = [pollfd(fd: search, events: Int16(POLLIN), revents: 0)]
            if let passive { fds.append(pollfd(fd: passive, events: Int16(POLLIN), revents: 0)) }
            guard poll(&fds, nfds_t(fds.count), 500) > 0 else { continue }
            for p in fds where p.revents & Int16(POLLIN) != 0 {
                var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(p.fd, &buf, buf.count, 0, $0, &len) } }
                guard n > 0 else { continue }
                if let printer = parse(String(decoding: buf[0..<n], as: UTF8.self), from: String(cString: inet_ntoa(from.sin_addr))) {
                    out[printer.serial] = printer
                }
            }
        }
        return Array(out.values)
    }

    /// Reads a Bambu SSDP announcement or search reply. Our own M-SEARCH echoes back too; it has no device model, so it is skipped.
    nonisolated static func parse(_ text: String, from sender: String) -> DiscoveredPrinter? {
        func header(_ k: String) -> String? {
            text.split(separator: "\r\n").first { $0.lowercased().hasPrefix(k.lowercased() + ":") }
                .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        }
        guard let usn = header("USN"), let model = header("DevModel.bambu.com") else { return nil }
        let location = header("Location").flatMap { $0.isEmpty ? nil : $0 } ?? sender
        return DiscoveredPrinter(ip: location, serial: usn, model: model, name: header("DevName.bambu.com") ?? model)
    }
}
