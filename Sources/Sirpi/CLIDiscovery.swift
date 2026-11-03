import Foundation
import Observation

/// Finds the coding-agent CLIs installed on this Mac, whether each is signed in (using the CLI's own status command,
/// so Sirpi never reads or stores their credentials) and which models each offers.
@Observable @MainActor
final class CLIDiscovery {
    struct Info: Codable, Equatable {
        var path: String?
        var signedIn: Bool?          // nil = unknown (no status command)
        var account: String = ""     // short description, e.g. "claude.ai", "3 providers"
        var models: [String] = []
        var checked: Date = .distantPast
        var installed: Bool { path != nil }
    }

    private(set) var info: [String: Info] = [:]
    private(set) var scanning = false
    private static let cacheKey = "cliDiscovery.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([String: Info].self, from: d) { info = cached }
    }

    var cliProviders: [Provider] { Providers.all.filter { $0.kind == .cli } }
    var installed: [Provider] { cliProviders.filter { info[$0.id]?.installed == true } }
    var missing: [Provider] { cliProviders.filter { info[$0.id]?.installed != true } }

    func status(_ p: Provider) -> String {
        guard let i = info[p.id], i.installed else { return "Not installed" }
        switch i.signedIn {
        case true?: return i.account.isEmpty ? "Signed in" : "Signed in · \(i.account)"
        case false?: return "Not signed in"
        case nil: return "Installed"
        }
    }

    /// Scans every known CLI in the background. Cheap enough to run at launch; each check has a timeout.
    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        await withTaskGroup(of: (String, Info).self) { group in
            for p in cliProviders {
                let exe = ProviderSettings.executable(p)
                group.addTask { (p.id, await Self.probe(p.id, exe: exe)) }
            }
            for await (id, i) in group { info[id] = i }
        }
        if let d = try? JSONEncoder().encode(info) { UserDefaults.standard.set(d, forKey: Self.cacheKey) }
    }

    // MARK: probes

    nonisolated static func probe(_ id: String, exe: String) async -> Info {
        _ = CLIRunner.shellEnvironment // make sure PATH from the login shell is loaded (off the main thread)
        var i = Info()
        i.checked = Date()
        guard let path = CLIRunner.resolvedPath(exe) else { return i }
        i.path = path
        switch id {
        case "claude-code":
            let out = await run(path, ["auth", "status"])
            if let d = out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                i.signedIn = j["loggedIn"] as? Bool
                i.account = (j["authMethod"] as? String) ?? ""
            }
            i.models = ["opus", "sonnet", "haiku", "fable", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
        case "opencode":
            let auth = await run(path, ["auth", "list"])
            let providers = Set(auth.split(separator: "\n").filter { $0.contains("stored") }
                .compactMap { $0.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) })
            i.signedIn = !providers.isEmpty
            i.account = providers.isEmpty ? "" : "\(providers.count) provider\(providers.count == 1 ? "" : "s")"
            i.models = await run(path, ["models"]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("/") && !$0.contains(" ") }
        case "grok-cli":
            let out = await run(path, ["models"])
            i.signedIn = out.localizedCaseInsensitiveContains("logged in")
            i.account = out.range(of: #"logged in with ([^\s.]+(?:\.[^\s.]+)*)"#, options: .regularExpression)
                .map { String(out[$0]).replacingOccurrences(of: "logged in with ", with: "") } ?? ""
            i.models = out.split(separator: "\n").compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("* ") || t.hasPrefix("- ") else { return nil }
                return t.dropFirst(2).split(separator: " ").first.map(String.init)
            }
        case "kimi":
            let out = await run(path, ["provider", "list"])
            i.signedIn = out.contains("models=") && !out.contains("models=0")
            i.account = out.contains("oauth") ? "Kimi account" : ""
            let cfg = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kimi-code/config.toml"), encoding: .utf8)) ?? ""
            i.models = cfg.split(separator: "\n").compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("[models.\""), let end = t.range(of: "\"]") else { return nil }
                return String(t[t.index(t.startIndex, offsetBy: 9)..<end.lowerBound])
            }
        case "cursor-agent":
            let out = await run(path, ["status"])
            i.signedIn = !out.localizedCaseInsensitiveContains("not logged in") && !out.isEmpty
            if i.signedIn == true {
                i.models = await run(path, ["models"]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.contains(" ") }
            }
        case "codex":
            let out = await run(path, ["login", "status"])
            i.signedIn = out.localizedCaseInsensitiveContains("logged in") && !out.localizedCaseInsensitiveContains("not logged in")
        case "gemini-cli":
            let home = FileManager.default.homeDirectoryForCurrentUser
            let oauth = FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/oauth_creds.json").path)
            let key = CLIRunner.shellEnvironment["GEMINI_API_KEY"] != nil
            i.signedIn = oauth || key
            i.account = oauth ? "Google account" : (key ? "API key" : "")
            i.models = ["gemini-2.5-pro", "gemini-2.5-flash"]
        default:
            i.signedIn = nil
        }
        return i
    }

    /// Runs a status/list command with the login-shell environment, a 20 s timeout and no stdin.
    nonisolated private static func run(_ path: String, _ args: [String]) async -> String {
        var env = CLIRunner.shellEnvironment
        env["NO_COLOR"] = "1"; env["TERM"] = "dumb"
        let r = await Shell.run(path, args, cwd: FileManager.default.temporaryDirectory, timeout: 20, environment: env)
        return String(decoding: r.stdout, as: UTF8.self) + r.stderr
    }
}
