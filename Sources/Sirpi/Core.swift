import Foundation
import CryptoKit

// MARK: - Paths

enum Paths {
    static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Sirpi", isDirectory: true)
        // 1.0 stored everything under the app's original name; move it over once so libraries and keys carry across.
        let old = base.appendingPathComponent("AssetForge", isDirectory: true)
        if !fm.fileExists(atPath: u.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: u) }
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let library: URL = {
        let u = support.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let slicerWork: URL = {
        let u = support.appendingPathComponent("SlicerProfiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// Bundled web resources (prep.html, gcode.html, bridge.js). Falls back to the source tree for `swift run`.
    static let web: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("bridge.js").path) {
            return r
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/web", isDirectory: true)
    }()

    static let defaultModelDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("models/glb-3d-coder", isDirectory: true)
}

// MARK: - Settings (UserDefaults-backed; views use @AppStorage with the same keys)

enum SettingKey {
    static let llamaServerPath = "llamaServerPath"
    static let modelPath = "modelPath"
    static let port = "serverPort"
    static let contextSize = "contextSize"
    static let enableThinking = "enableThinking"
    static let temperature = "temperature"
    static let bambuStudioPath = "bambuStudioPath"
    static let printerIP = "printerIP"
    static let printerSerial = "printerSerial"
    static let printerName = "printerName"
    static let nozzle = "nozzle"
    static let autoStartServer = "autoStartServer"
}

enum Settings {
    static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            SettingKey.llamaServerPath: ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
                .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/llama-server",
            // The fine-tuned weights when present (more working prints and games, half the tokens), else the original.
            SettingKey.modelPath: ["mlx-tuned-4bit", "mlx-4bit"].map { Paths.defaultModelDir.appendingPathComponent($0).path }
                .first { NativeEngine.isMLXModel($0) }
                ?? Paths.defaultModelDir.appendingPathComponent("Qwen3.5-4B-GLB-3D-Coder-Q8_0.gguf").path,
            SettingKey.port: 8089,
            SettingKey.contextSize: 32768,
            SettingKey.enableThinking: true,
            SettingKey.temperature: 0.8,
            SettingKey.bambuStudioPath: "/Applications/BambuStudio.app",
            SettingKey.printerIP: "",
            SettingKey.printerSerial: "",
            SettingKey.printerName: "P2S",
            SettingKey.nozzle: "0.4",
            SettingKey.autoStartServer: true,
        ])
    }

    static var llamaServerPath: String { d.string(forKey: SettingKey.llamaServerPath) ?? "" }
    static var modelPath: String { d.string(forKey: SettingKey.modelPath) ?? "" }
    static var port: Int { d.integer(forKey: SettingKey.port) }
    static var contextSize: Int { d.integer(forKey: SettingKey.contextSize) }
    static var enableThinking: Bool { d.bool(forKey: SettingKey.enableThinking) }
    static var temperature: Double { d.double(forKey: SettingKey.temperature) }
    static var bambuStudioPath: String { d.string(forKey: SettingKey.bambuStudioPath) ?? "" }
    static var printerIP: String { (d.string(forKey: SettingKey.printerIP) ?? "").trimmingCharacters(in: .whitespaces) }
    static var printerSerial: String { (d.string(forKey: SettingKey.printerSerial) ?? "").trimmingCharacters(in: .whitespaces) }
    static var nozzle: String { d.string(forKey: SettingKey.nozzle) ?? "0.4" }
    static var serverBase: URL { URL(string: "http://127.0.0.1:\(port)")! }

    static let mlxDefault = Paths.defaultModelDir.appendingPathComponent("mlx-4bit").path

    /// One-time switch from the llama.cpp Q8 GGUF to the in-app MLX 4-bit model when it is present
    /// (about 2x the tokens per second at half the memory). A later manual choice is left alone.
    static func migrateToMLXIfAvailable() {
        let key = "migratedToMLX"
        guard !d.bool(forKey: key), NativeEngine.isMLXModel(mlxDefault) else { return }
        d.set(true, forKey: key)
        if modelPath.hasSuffix(".gguf") { d.set(mlxDefault, forKey: SettingKey.modelPath) }
    }
}

// MARK: - Secret store (printer access code)
// A user-only (0600) file in Application Support. The legacy keychain re-prompts on every rebuild of an
// ad-hoc-signed app and blocks the caller while it waits, so it is not used here.

enum SecretStore {
    private static var cache: [String: String] = [:]
    private static func url(_ account: String) -> URL { Paths.support.appendingPathComponent(".\(account)") }

    static func get(_ account: String) -> String? {
        if let v = cache[account] { return v }
        let v = (try? String(contentsOf: url(account), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[account] = v ?? ""
        return v
    }

    static func set(_ value: String, for account: String) {
        cache[account] = value
        let u = url(account)
        guard !value.isEmpty else { try? FileManager.default.removeItem(at: u); return }
        FileManager.default.createFile(atPath: u.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }
}

// MARK: - Shell helper

struct ShellResult { var status: Int32; var stdout: Data; var stderr: String }

enum Shell {
    /// Runs an executable off the main thread. `stdin` is written then closed.
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil, timeout: Double? = nil,
                    environment: [String: String]? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = cwd }
                if let environment { p.environment = environment }
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = inp
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do { try p.run() } catch {
                    cont.resume(returning: ShellResult(status: -1, stdout: Data(), stderr: "\(error.localizedDescription)"))
                    return
                }
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                }
                p.waitUntilExit()
                group.wait()
                cont.resume(returning: ShellResult(status: p.terminationStatus, stdout: outData,
                                                   stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

extension Data {
    /// Uppercase hex MD5, the format Bambu's project_file command expects.
    var md5Hex: String { Insecure.MD5.hash(data: self).map { String(format: "%02X", $0) }.joined() }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m \(s % 60)s"
}
