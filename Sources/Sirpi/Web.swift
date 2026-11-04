import Foundation
import WebKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - forge:// scheme (WebKit's SwiftUI URLSchemeHandler)
// forge://lib/<assetId>/<file>  -> Application Support/Sirpi/Library/<assetId>/<file>
// forge://app/<file>            -> bundled Resources/web/<file>

struct ForgeSchemeHandler: URLSchemeHandler {
    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url, let host = url.host else {
                continuation.finish(throwing: URLError(.badURL)); return
            }
            let parts = url.path.split(separator: "/").map(String.init).filter { $0 != ".." }
            let file: URL
            switch host {
            case "lib": file = parts.reduce(Paths.library) { $0.appendingPathComponent($1) }
            case "app": file = parts.reduce(Paths.web) { $0.appendingPathComponent($1) }
            default: continuation.finish(throwing: URLError(.unsupportedURL)); return
            }
            guard var data = try? Data(contentsOf: file) else {
                // A three.js add-on Sirpi does not bundle (picking and the live preview point every add-on here):
                // fetch the one matching the bundled three.js from the CDN once and keep it.
                if host == "app", let rel = ThreeAddons.relativePath(parts) {
                    Task {
                        do {
                            let d = try await ThreeAddons.fetch(rel)
                            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                                "Content-Type": "text/javascript", "Content-Length": String(d.count),
                                "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store",
                            ])!
                            continuation.yield(.response(resp))
                            continuation.yield(.data(d))
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    return
                }
                continuation.finish(throwing: URLError(.fileDoesNotExist)); return
            }
            // ?pick=1: the asset page with three.js swapped for the hooked copy and part picking added.
            if host == "lib", file.pathExtension == "html", url.query?.contains("pick=1") == true {
                data = Data(PageInstrument.forPicking(String(decoding: data, as: UTF8.self)).utf8)
            }
            let ext = file.pathExtension.lowercased()
            let mime: String = switch ext {
            case "html": "text/html; charset=utf-8"
            case "js", "mjs": "text/javascript"
            case "wasm": "application/wasm"
            case "gcode": "text/plain; charset=utf-8"
            default: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime, "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store",
            ])!
            continuation.yield(.response(resp))
            continuation.yield(.data(data))
            continuation.finish()
        }
    }
}

/// three.js add-ons beyond the handful Sirpi bundles, fetched on first use at the bundled revision and cached.
enum ThreeAddons {
    static let version = "0.187.0"   // matches Resources/web/vendor/three (REVISION 187)
    static let cache = Paths.support.appendingPathComponent("three-\(version)/examples/jsm", isDirectory: true)

    /// "vendor/three/examples/jsm/geometries/RoundedBoxGeometry.js" → "geometries/RoundedBoxGeometry.js"
    static func relativePath(_ parts: [String]) -> String? {
        let prefix = ["vendor", "three", "examples", "jsm"]
        guard parts.count > prefix.count, Array(parts.prefix(4)) == prefix,
              parts.last?.hasSuffix(".js") == true else { return nil }
        return parts.dropFirst(4).joined(separator: "/")
    }

    static func fetch(_ rel: String) async throws -> Data {
        let local = cache.appendingPathComponent(rel)
        if let d = try? Data(contentsOf: local) { return d }
        guard let remote = URL(string: "https://cdn.jsdelivr.net/npm/three@\(version)/examples/jsm/\(rel)") else {
            throw URLError(.badURL)
        }
        let (d, resp) = try await URLSession.shared.data(from: remote)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty else { throw URLError(.fileDoesNotExist) }
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: local, options: .atomic)
        return d
    }
}

// MARK: - Instrumented asset pages

enum PageInstrument {
    /// Points every three.js import at Sirpi's hooked copy (recording scenes and cameras) and adds the picking script.
    static func forPicking(_ html: String) -> String {
        var out = rewriteThree(html)
        let tag = "<script src=\"forge://app/pick.js\"></script>"
        if let r = out.range(of: "<head>", options: .caseInsensitive) { out.insert(contentsOf: "\n" + tag, at: r.upperBound) }
        else { out = tag + "\n" + out }
        return out
    }

    static func rewriteThree(_ html: String) -> String {
        var s = html
        let core = #"https?://[^'"\s]*?three[^'"\s]*?/build/three(?:\.module)?(?:\.min)?\.js"#
        let cdnCore = #"https?://(?:esm\.sh|cdn\.skypack\.dev)/three(?:@[\w.]+)?(?=['"])"#
        let addons = #"https?://[^'"\s]*?three[^'"\s]*?/(?:examples/jsm|addons)/"#
        s = s.replacingOccurrences(of: core, with: "forge://app/three-hook.js", options: .regularExpression)
        s = s.replacingOccurrences(of: "forge://app/vendor/three/build/three.module.js", with: "forge://app/three-hook.js")
        s = s.replacingOccurrences(of: cdnCore, with: "forge://app/three-hook.js", options: .regularExpression)
        s = s.replacingOccurrences(of: addons, with: "forge://app/vendor/three/examples/jsm/", options: .regularExpression)
        return s
    }
}

// MARK: - Navigation policy: generated pages may not navigate away; external links open in the browser

private struct ForgeNavigationDecider: WebPage.NavigationDeciding {
    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? ""), action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }
}

private final class MessageProxy: NSObject, WKScriptMessageHandler {
    var handler: (([String: Any]) -> Void)?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any] else { return }
        MainActor.assumeIsolated { handler?(body) }
    }
}

// MARK: - Web controller (wraps a WebPage + the forge bridge)

@Observable @MainActor
final class WebController {
    @ObservationIgnored let page: WebPage
    var errors: [String] = []
    var loadedURL: URL?
    var isLoading: Bool { page.isLoading }

    @ObservationIgnored var onDownload: ((String, Data) -> Void)?
    @ObservationIgnored var onMessage: (([String: Any]) -> Void)?
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private let proxy = MessageProxy()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(injectBridge: Bool) {
        var config = WebPage.Configuration()
        if let scheme = URLScheme("forge") { config.urlSchemeHandlers[scheme] = ForgeSchemeHandler() }
        let ucc = WKUserContentController()
        if injectBridge, let js = try? String(contentsOf: Paths.web.appendingPathComponent("bridge.js"), encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        ucc.add(proxy, name: "forge")
        config.userContentController = ucc
        page = WebPage(configuration: config, navigationDecider: ForgeNavigationDecider())
        page.isInspectable = true
        proxy.handler = { [weak self] body in self?.receive(body) }
    }

    func load(_ url: URL) {
        errors = []
        loadedURL = url
        loadTask?.cancel()
        let events = page.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        loadTask = Task { [weak self] in
            do {
                for try await event in events {
                    if case .finished = event { self?.onFinish?() }
                }
            } catch {
                if !Task.isCancelled { self?.errors.append("Load failed: \(error.localizedDescription)") }
            }
        }
    }

    func reload() { if let u = loadedURL { load(u) } }

    /// Evaluates a JavaScript expression or statement list and returns the last value.
    @discardableResult
    func eval(_ js: String) async -> Any? {
        try? await page.callJavaScript("return eval(code)", arguments: ["code": js])
    }

    /// Like `eval`, but surfaces JavaScript exceptions and rejected promises as errors.
    func evalThrowing(_ js: String) async throws -> Any? {
        try await page.callJavaScript("return await eval(code)", arguments: ["code": js])
    }

    func snapshot() async -> NSImage? {
        guard let data = try? await page.exported(as: .image()) else { return nil }
        return NSImage(data: data)
    }

    private func receive(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "error":
            let msg = (body["message"] as? String) ?? "Unknown error"
            if !errors.contains(msg) && errors.count < 20 { errors.append(msg) }
        case "download":
            if let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) {
                onDownload?((body["name"] as? String) ?? "asset.glb", data)
            }
        default: break
        }
        onMessage?(body)
    }
}

struct ForgeWebView: View {
    let controller: WebController
    var body: some View {
        WebView(controller.page)
            .webViewContentBackground(.hidden)
    }
}

// MARK: - GLB extraction

/// Loads an asset page and clicks its Export GLB button, capturing the downloaded bytes.
@MainActor
enum GLBExtractor {
    static func extract(using web: WebController, asset: Asset, timeout: Double = 20) async throws -> Data {
        if web.loadedURL != asset.pageURL || web.isLoading {
            web.load(asset.pageURL)
            try await Task.sleep(for: .milliseconds(300))
            for _ in 0..<150 where web.isLoading { try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .milliseconds(1200)) // let module scripts build the scene
        }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            // Don't forward to the previous handler: it belongs to whichever asset the preview showed before
            // and would save these bytes into that asset too (that is how one export overwrote another's GLB).
            let previous = web.onDownload
            web.onDownload = { name, data in
                guard !resumed else { return }
                resumed = true
                web.onDownload = previous
                cont.resume(returning: data)
            }
            Task { @MainActor in
                let clicked = (await web.eval("window.__forgeExport ? window.__forgeExport() : false") as? Bool) ?? false
                if !clicked && !resumed {
                    resumed = true; web.onDownload = previous
                    cont.resume(throwing: ForgeError("No Export GLB button found on the page."))
                    return
                }
                try? await Task.sleep(for: .seconds(timeout))
                if !resumed {
                    resumed = true; web.onDownload = previous
                    cont.resume(throwing: ForgeError("Export GLB did not produce a file. Check the page for errors."))
                }
            }
        }
    }
}

struct ForgeError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
