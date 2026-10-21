import AppKit
import WebKit

/// What Browser Control keeps about one Browser plane page: its console and
/// network since the last few navigations, a dialog waiting for an answer,
/// what's emulated, and the calls into the page's scripts. The tools
/// themselves are BrowserAgentCenter's.
@MainActor
final class BrowserAgent: NSObject, WKUIDelegate {
    static let world = WKContentWorld.world(name: "OctetAgent")
    static let handlerName = "octetAgent"

    struct ConsoleMessage {
        let id: Int
        let type: String
        let text: String
        let args: [String]
        let stack: String?
        let source: String?
        let navigation: Int
    }

    struct NetworkRequest {
        let id: Int
        var pageKey: String?
        let resourceType: String
        let url: String
        let method: String
        var status: Int?
        var statusText: String?
        var requestHeaders: [String: String] = [:]
        var responseHeaders: [String: String] = [:]
        var requestBody: String?
        var responseBody: String?
        var failed: String?
        var start: Double?
        var end: Double?
        var size: Int?
        let navigation: Int
    }

    struct Dialog {
        enum Kind: String { case alert, confirm, prompt }
        let kind: Kind
        let message: String
        let defaultText: String?
        let answer: (Bool, String?) -> Void
    }

    private weak var view: WKWebView?
    private(set) var console: [ConsoleMessage] = []
    private(set) var network: [NetworkRequest] = []
    private var nextConsole = 1
    private var nextRequest = 1
    /// Commits so far, so lists can be "since the last navigation".
    private(set) var navigation = 0
    private(set) var dialog: Dialog?
    private var dialogTimer: Timer?
    /// Calls in flight, told when a dialog opens and blocks the page.
    private var dialogWatchers: [UUID: (Dialog) -> Void] = [:]
    /// While evaluate_script runs: how to answer a dialog it opens.
    var autoDialog: String?
    /// The last time an agent used this page. Dialogs wait for an answer
    /// only while one is driving it; otherwise they go as they did before.
    var lastDriven: Date?
    /// Headers to send with top-level navigations, from emulate.
    var extraHeaders: [String: String] = [:]
    /// One-off scripts for the next document, from navigate_page.
    private var baseScripts: [WKUserScript] = []
    private var emulationScripts: [WKUserScript] = []
    private var onceScripts: [WKUserScript] = []
    var recording: [String: Any]?
    var lastRecording: [String: Any]?

    /// Pages are left as they were until Browser Control is on: the hooks
    /// go in then, or when an agent first uses this page.
    func attach(_ view: WKWebView, enabled: Bool) {
        self.view = view
        view.uiDelegate = self
        if enabled { install() }
    }

    private var installed = false

    /// Puts the scripts in for later documents, and the agent's into this one.
    func install() {
        guard !installed, let view else { return }
        installed = true
        let controller = view.configuration.userContentController
        controller.add(HookMessageHandler(owner: self), contentWorld: .page, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: BrowserAgentScripts.hooks, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: BrowserAgentScripts.agent, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.world))
        // The page already open gets the agent's side now; its console and
        // network are seen from its next load.
        if view.url != nil { view.evaluateJavaScript(BrowserAgentScripts.agent, in: nil, in: Self.world) { _ in } }
    }

    private var driving: Bool { lastDriven.map { Date().timeIntervalSince($0) < 300 } ?? false }

    // MARK: Scripts for later documents

    /// Re-installs the page's scripts with the emulation and one-off ones.
    private func installScripts() {
        guard let controller = view?.configuration.userContentController else { return }
        if baseScripts.isEmpty { baseScripts = controller.userScripts }
        controller.removeAllUserScripts()
        for script in baseScripts + emulationScripts + onceScripts { controller.addUserScript(script) }
    }

    func runOnNextDocument(_ source: String) {
        onceScripts = [WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)]
        installScripts()
    }

    func setGeolocation(latitude: Double, longitude: Double) {
        let source = """
        (() => { const position = { coords: { latitude: \(latitude), longitude: \(longitude), accuracy: 10, altitude: null, altitudeAccuracy: null, heading: null, speed: null }, timestamp: Date.now() };
        const g = navigator.geolocation; if (!g) return;
        g.getCurrentPosition = (ok) => setTimeout(() => ok({ ...position, timestamp: Date.now() }), 0);
        g.watchPosition = (ok) => { setTimeout(() => ok({ ...position, timestamp: Date.now() }), 0); return 1; };
        g.clearWatch = () => {}; })();
        """
        emulationScripts = [WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)]
        installScripts()
        view?.evaluateJavaScript(source, in: nil, in: .page) { _ in }
    }

    func clearGeolocation() {
        emulationScripts = []
        installScripts()
    }

    // MARK: Navigation

    func committed() {
        navigation += 1
        if !onceScripts.isEmpty {
            onceScripts = []
            installScripts()
        }
        // Kept for three navigations, for includePreserved….
        console.removeAll { $0.navigation < navigation - 2 }
        network.removeAll { $0.navigation < navigation - 2 }
        // The document's own request was recorded before it committed.
        if let index = network.lastIndex(where: { $0.resourceType == "document" && $0.navigation == navigation - 1 && $0.pageKey == "pending" }) {
            let document = network.remove(at: index)
            network.append(NetworkRequest(id: document.id, pageKey: nil, resourceType: "document", url: document.url, method: document.method,
                                          status: document.status, statusText: document.statusText, requestHeaders: document.requestHeaders,
                                          responseHeaders: document.responseHeaders, navigation: navigation))
        }
    }

    private var pendingDocumentHeaders: [String: [String: String]] = [:]

    func documentRequest(_ request: URLRequest) {
        guard let url = request.url?.absoluteString else { return }
        pendingDocumentHeaders = [url: request.allHTTPHeaderFields ?? [:]]
    }

    func documentResponse(_ response: URLResponse) {
        guard let url = response.url?.absoluteString else { return }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] { headers[String(describing: key).lowercased()] = String(describing: value) }
        network.append(NetworkRequest(id: nextRequest, pageKey: "pending", resourceType: "document", url: url, method: "GET",
                                      status: http?.statusCode, statusText: http.map { HTTPURLResponse.localizedString(forStatusCode: $0.statusCode) },
                                      requestHeaders: pendingDocumentHeaders[url] ?? [:], responseHeaders: headers, navigation: navigation))
        nextRequest += 1
    }

    func documentFailed(url: URL, message: String) {
        network.append(NetworkRequest(id: nextRequest, resourceType: "document", url: url.absoluteString, method: "GET",
                                      failed: message, navigation: navigation))
        nextRequest += 1
    }

    // MARK: From the page's hooks

    private static let loadFailure = "Failed to load resource: "

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let kind = message["kind"] as? String else { return }
        func string(_ key: String) -> String? { message[key] as? String }
        func headers(_ key: String) -> [String: String] {
            (message[key] as? [String: Any] ?? [:]).reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
        }
        switch kind {
        case "console":
            if console.count >= 2000 { console.removeFirst(500) }
            // A resource that failed to load says so here; its timing entry has no status.
            if let text = string("text"), text.hasPrefix(Self.loadFailure) {
                let url = String(text.dropFirst(Self.loadFailure.count))
                if let index = network.lastIndex(where: { $0.url == url && $0.navigation == navigation }) { network[index].failed = "failed to load" }
            }
            console.append(ConsoleMessage(id: nextConsole, type: string("type") ?? "log", text: string("text") ?? "",
                                          args: message["args"] as? [String] ?? [], stack: string("stack"),
                                          source: string("source"), navigation: navigation))
            nextConsole += 1
        case "request", "resource":
            if network.count >= 1500 { network.removeFirst(300) }
            var request = NetworkRequest(id: nextRequest, pageKey: string("id"), resourceType: string("resourceType") ?? "other",
                                         url: string("url") ?? "", method: string("method") ?? "GET", navigation: navigation)
            request.requestHeaders = headers("requestHeaders")
            request.requestBody = string("requestBody")
            request.start = message["start"] as? Double
            request.end = message["end"] as? Double
            request.status = message["status"] as? Int
            request.size = message["transferSize"] as? Int
            if kind == "resource", console.contains(where: { $0.navigation == navigation && $0.text == Self.loadFailure + request.url }) {
                request.failed = "failed to load"
            }
            network.append(request)
            nextRequest += 1
        case "response", "body":
            guard let key = string("id"), let index = network.lastIndex(where: { $0.pageKey == key }) else { return }
            if kind == "body" {
                network[index].responseBody = string("responseBody")
                network[index].size = network[index].size ?? message["size"] as? Int
            } else {
                network[index].status = message["status"] as? Int
                network[index].statusText = string("statusText")
                network[index].responseHeaders = headers("responseHeaders")
                network[index].failed = string("failed")
                network[index].end = message["end"] as? Double
            }
        default:
            break
        }
    }

    // MARK: Dialogs

    private func open(_ kind: Dialog.Kind, message: String, defaultText: String?, answer: @escaping (Bool, String?) -> Void) {
        if let action = autoDialog {
            let accept = action != "dismiss"
            answer(accept, kind == .prompt && accept ? (["accept", "dismiss"].contains(action) ? defaultText ?? "" : action) : nil)
            return
        }
        // Nobody driving: as before Browser Control, which had no dialogs.
        guard driving else { return answer(false, nil) }
        dialog?.answer(false, nil)
        let dialog = Dialog(kind: kind, message: message, defaultText: defaultText, answer: answer)
        self.dialog = dialog
        dialogTimer?.invalidate()
        dialogTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.answerDialog(accept: false, text: nil) }
        }
        for watcher in dialogWatchers.values { watcher(dialog) }
    }

    /// Answers the open dialog; false when there was none.
    func answerDialog(accept: Bool, text: String?) -> Bool {
        guard let dialog else { return false }
        self.dialog = nil
        dialogTimer?.invalidate()
        dialog.answer(accept, accept ? (text ?? dialog.defaultText ?? "") : nil)
        return true
    }

    static func describe(_ dialog: Dialog) -> String {
        var line = "The page opened a \(dialog.kind.rawValue) dialog: \"\(dialog.message)\""
        if let text = dialog.defaultText, !text.isEmpty { line += " (default text \"\(text)\")" }
        return line + ". It blocks the page until you call handle_dialog."
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        open(.alert, message: message, defaultText: nil) { _, _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        open(.confirm, message: message, defaultText: nil) { accept, _ in completionHandler(accept) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        open(.prompt, message: prompt, defaultText: defaultText) { accept, text in completionHandler(accept ? text : nil) }
    }

    /// Links that open a new window load here: the plane has one page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if driving, navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    // MARK: Calling the page

    enum Outcome {
        case value(Any?)
        /// A dialog opened while it ran, and the page is blocked on it.
        case dialog(Dialog)
    }

    struct ScriptError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Runs `body` as an async function in `world` (Octet's own by default)
    /// and hands back its JSON result, or the dialog that stopped it.
    func run(_ body: String, arguments: [String: Any] = [:], world: WKContentWorld? = nil,
             timeout: TimeInterval = 30) async throws -> Outcome {
        guard let view else { throw ScriptError(message: "The page is gone.") }
        if let dialog { return .dialog(dialog) }
        let token = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let call = PendingCall(continuation)
            let finish: (Result<Outcome, Error>) -> Void = { [weak self] result in
                guard call.finish(result) else { return }
                self?.dialogWatchers[token] = nil
            }
            dialogWatchers[token] = { finish(.success(.dialog($0))) }
            call.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                MainActor.assumeIsolated { finish(.failure(ScriptError(message: "The page didn't answer within \(Int(timeout)) seconds."))) }
            }
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world ?? Self.world) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value):
                        if let json = value as? String, let data = json.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                            finish(.success(.value(parsed is NSNull ? nil : parsed)))
                        } else {
                            finish(.success(.value(value is NSNull ? nil : value)))
                        }
                    case .failure(let error):
                        finish(.failure(ScriptError(message: Self.message(of: error))))
                    }
                }
            }
        }
    }

    /// Calls `octetAgent.<function>(…arguments)` and returns what it gave.
    /// `arguments` are the function's parameters, in order.
    func agentCall(_ function: String, _ arguments: KeyValuePairs<String, Any> = [:], timeout: TimeInterval = 30) async throws -> Outcome {
        let list = arguments.map(\.key).joined(separator: ", ")
        let body = """
        if (!globalThis.octetAgent) throw new Error('The page is still loading. Try again in a moment.');
        const __octetResult = await globalThis.octetAgent.\(function)(\(list));
        return JSON.stringify(__octetResult === undefined ? null : __octetResult);
        """
        return try await run(body, arguments: Dictionary(arguments.map { ($0.key, $0.value) }) { first, _ in first }, timeout: timeout)
    }

    static func message(of error: Error) -> String {
        let error = error as NSError
        if let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return message.replacingOccurrences(of: "Error: ", with: "")
        }
        return error.localizedDescription
    }
}

/// One call into the page, finished by whichever comes first: its answer, a
/// dialog, or the timeout.
private final class PendingCall {
    private var continuation: CheckedContinuation<BrowserAgent.Outcome, Error>?
    var timer: Timer?

    init(_ continuation: CheckedContinuation<BrowserAgent.Outcome, Error>) { self.continuation = continuation }

    func finish(_ result: Result<BrowserAgent.Outcome, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        timer?.invalidate()
        continuation.resume(with: result)
        return true
    }
}

private final class HookMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserAgent?
    init(owner: BrowserAgent) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        MainActor.assumeIsolated { owner?.receive(message.body) }
    }
}
