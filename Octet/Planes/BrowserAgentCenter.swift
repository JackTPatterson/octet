import AppKit
import UniformTypeIdentifiers
import WebKit

/// Browser Control: lets agents drive the Browser plane with chrome-devtools
/// MCP's tools. Listens on a socket while the plugin is on; each request is
/// one tool call for one page, which is a workspace's Browser plane page.
@MainActor
final class BrowserAgentCenter {
    static let shared = BrowserAgentCenter()

    private weak var store: SessionStore?
    private var server: PermissionSocketServer?
    private var enabled: Bool { SettingsStore.shared.values.browserControlEnabled }

    func apply(store: SessionStore? = nil) {
        if let store { self.store = store }
        if enabled, server == nil { start() } else if !enabled, server != nil { stop() }
    }

    private var socketPath: String {
        EngineSession.supportDirectory.appendingPathComponent(BrowserControl.socketName).path
    }

    private func start() {
        try? FileManager.default.createDirectory(at: EngineSession.supportDirectory, withIntermediateDirectories: true)
        let server = PermissionSocketServer(path: socketPath)
        do {
            try server.start { [weak self] request, reply in
                MainActor.assumeIsolated { self?.handle(request, reply: reply) }
            }
            self.server = server
        } catch {
            ToastCenter.shared.fail(nil, "Agents can't use the Browser plane", detail: "\(error)")
        }
    }

    private func stop() {
        server?.stop()
        server = nil
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private func handle(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard enabled else { return reply(["error": "Browser Control is off (Octet Settings › Plugins)."]) }
        guard request["method"] as? String == "tool", let params = request["params"] as? [String: Any],
              let tool = params["tool"] as? String else { return reply(["error": "Unknown request."]) }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let origin = Asker(pane: params["from_pane"] as? String, workspace: params["from_workspace"] as? String)
        Task { @MainActor in
            do {
                reply(["result": try await self.run(tool, arguments, origin: origin)])
            } catch {
                reply(["error": String(describing: error)])
            }
        }
    }

    // MARK: - Pages

    /// Who's asking: the agent's pane or workspace.
    struct Asker {
        let pane: String?
        let workspace: String?
        var key: String { pane ?? workspace ?? "" }
    }

    private final class WeakPage {
        weak var page: BrowserPage?
        init(_ page: BrowserPage) { self.page = page }
    }

    private var pageIDs: [ObjectIdentifier: Int] = [:]
    private var pagesByID: [Int: WeakPage] = [:]
    private var nextPageID = 1
    /// select_page's choice, per asker.
    private var selected: [String: Int] = [:]

    private func id(of page: BrowserPage) -> Int {
        if let id = pageIDs[ObjectIdentifier(page)], pagesByID[id]?.page === page { return id }
        let id = nextPageID
        nextPageID += 1
        pageIDs[ObjectIdentifier(page)] = id
        pagesByID[id] = WeakPage(page)
        return id
    }

    /// The asker's workspace: the one its pane is in, else the one in front.
    private func workspace(of asker: Asker) -> String? {
        let store = store ?? WindowRegistry.shared.windows.first?.store
        // Only one of this Octet's: a process can carry another session's ids.
        let known = Set(store?.snapshot.workspaces.map(\.workspaceId) ?? [])
        if let workspace = asker.workspace, known.contains(workspace) { return workspace }
        if let pane = asker.pane, let workspace = store?.snapshot.panes.first(where: { $0.paneId == pane })?.workspaceId,
           known.contains(workspace) { return workspace }
        let front = WindowRegistry.shared.key
        return front?.ui.panelWorkspaceID ?? front?.focusedWorkspace?.workspaceId
    }

    private func window(for workspace: String?) -> WindowContext? {
        let registry = WindowRegistry.shared
        return workspace.flatMap { registry.window(showing: $0) ?? registry.home(of: $0) } ?? registry.key ?? registry.windows.first
    }

    /// The asker's own page: its workspace's Browser plane page, made when
    /// `create`, with the plane opened when `show` and that workspace is on
    /// screen.
    private func ownPage(_ asker: Asker, create: Bool, show: Bool) throws -> BrowserPage {
        let asked = workspace(of: asker)
        guard let window = window(for: asked) else { throw Failure(message: "Octet has no window open.") }
        // With no workspace to go by (no window in front), the one this window shows.
        let workspace = asked ?? window.ui.panelWorkspaceID ?? window.focusedWorkspace?.workspaceId ?? ""
        let ui = window.ui
        let page: BrowserPage
        if let existing = ui.panelBrowserPages[workspace] {
            page = existing
        } else if create {
            page = BrowserPage(private: false, draftKey: workspace.isEmpty ? nil : workspace)
            ui.panelBrowserPages[workspace] = page
        } else {
            throw Failure(message: "Your workspace has no page in the Browser plane. Call new_page with a URL first.")
        }
        if page.view.frame.isEmpty { fitOffscreen(page) }
        if show, ui.panelWorkspaceID == workspace {
            let visible = ui.sidePanelVisible && (ui.activePlaneId == Plane.make(.browser).id || ui.splitPlaneIds.contains(Plane.make(.browser).id))
            if !visible { ui.showPlane(.browser) }
        }
        return page
    }

    /// A page not on screen still loads and runs, at the size it'd be given.
    private func fitOffscreen(_ page: BrowserPage) {
        guard page.view.window == nil else { return }
        page.view.setFrameSize(page.customViewport ?? NSSize(width: 1280, height: 800))
    }

    private func isStart(_ page: BrowserPage) -> Bool {
        page.view.url == nil || page.view.url?.scheme == "about"
    }

    private func page(for arguments: [String: Any], asker: Asker, create: Bool = false, show: Bool = false) throws -> BrowserPage {
        if let raw = arguments["pageId"] ?? selected[asker.key].map({ $0 as Any }) {
            let id = (raw as? Int) ?? (raw as? Double).map(Int.init) ?? Int("\(raw)") ?? -1
            guard let page = pagesByID[id]?.page else {
                if arguments["pageId"] == nil { selected[asker.key] = nil; return try ownPage(asker, create: create, show: show) }
                throw Failure(message: "There's no page \(id) now (its plane was closed). Call list_pages.")
            }
            return page
        }
        return try ownPage(asker, create: create, show: show)
    }

    /// Every page in a Browser plane, with its workspace.
    private func allPages() -> [(page: BrowserPage, workspace: String, window: WindowContext)] {
        WindowRegistry.shared.windows.flatMap { window in
            window.ui.panelBrowserPages.sorted { $0.key < $1.key }.map { (page: $0.value, workspace: $0.key, window: window) }
        }
    }

    private func workspaceLabel(_ id: String, in window: WindowContext) -> String {
        guard let workspace = window.store.snapshot.workspaces.first(where: { $0.workspaceId == id }) else { return "workspace" }
        return workspace.label.isEmpty ? "workspace \(workspace.number)" : workspace.label
    }

    // MARK: - Tools

    private func run(_ tool: String, _ arguments: [String: Any], origin asker: Asker) async throws -> [String: Any] {
        switch tool {
        case "list_pages":
            return ["text": listPages(asker)]
        case "new_page":
            guard let url = (arguments["url"] as? String).flatMap(BrowserAddress.url(from:)) else {
                throw Failure(message: "Give a URL to load.")
            }
            let page = try ownPage(asker, create: true, show: arguments["background"] as? Bool != true)
            page.agent.install()
            page.agent.lastDriven = Date()
            page.load(url)
            selected[asker.key] = id(of: page)
            let note = try await waitForLoad(page, timeout: timeout(arguments, default: 15))
            return ["text": "Page \(id(of: page)) is your workspace's Browser plane page.\n" + note + "\n\n" + listPages(asker)]
        case "select_page":
            guard let page = try? page(for: ["pageId": arguments["pageId"] as Any], asker: asker) else {
                throw Failure(message: "There's no page \(arguments["pageId"] ?? "") now. Call list_pages.")
            }
            selected[asker.key] = id(of: page)
            if arguments["bringToFront"] as? Bool == true, let entry = allPages().first(where: { $0.page === page }),
               entry.window.ui.panelWorkspaceID == entry.workspace {
                entry.window.ui.showPlane(.browser)
            }
            return ["text": "Selected page \(id(of: page)).\n\n" + listPages(asker)]
        default:
            break
        }

        let page = try page(for: arguments, asker: asker, create: tool == "navigate_page", show: tool == "navigate_page")
        await announceCursor(for: tool, on: page, asker: asker)
        let agent = page.agent
        agent.install()
        agent.lastDriven = Date()
        // A blocked page answers nothing until the dialog goes.
        if let dialog = agent.dialog, tool != "handle_dialog" {
            throw Failure(message: BrowserAgent.describe(dialog))
        }
        switch tool {
        case "close_page":
            page.showStart()
            if selected[asker.key] == id(of: page) { selected[asker.key] = nil }
            return ["text": "Closed page \(id(of: page)): the plane is on its start page."]
        case "navigate_page":
            return ["text": try await navigate(page, arguments)]
        case "resize_page":
            guard let width = number(arguments["width"]), let height = number(arguments["height"]), width >= 100, height >= 100 else {
                throw Failure(message: "Give a width and a height of at least 100.")
            }
            page.customViewport = CGSize(width: width, height: height)
            fitOffscreen(page)
            return ["text": "The page's viewport is now \(Int(width)) × \(Int(height)) CSS pixels."]
        case "emulate":
            return ["text": try emulate(page, arguments)]
        case "wait_for":
            let texts = (arguments["text"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            guard !texts.isEmpty else { throw Failure(message: "Give at least one text to wait for.") }
            let ms = timeout(arguments, default: 5) * 1000
            let found = try await value(agent.agentCall("waitFor", ["texts": texts, "timeout": ms], timeout: ms / 1000 + 5), page)
            return ["text": "Element with text \"\(found as? String ?? texts[0])\" found.\n\n" + (try await snapshot(page, verbose: false))]
        case "take_snapshot":
            let text = try await snapshot(page, verbose: arguments["verbose"] as? Bool == true)
            return ["text": text, "summary": "Snapshot of \(page.view.url?.absoluteString ?? "the page") (\(text.split(separator: "\n").count) lines)."]
        case "take_screenshot":
            return try await screenshot(page, arguments)
        case "evaluate_script":
            return try await evaluate(page, arguments)
        case "get_css_styles":
            guard let uid = arguments["uid"] as? String else { throw Failure(message: "Give the element's uid.") }
            let pageIdx = max(0, Int(number(arguments["pageIdx"]) ?? 0))
            let pageSize = max(1, Int(number(arguments["pageSize"]) ?? 10))
            let text = try await value(agent.agentCall("styles", ["uid": uid, "pageIdx": pageIdx, "pageSize": pageSize]), page)
            return ["text": text as? String ?? ""]
        case "click":
            return try await act(page, arguments, "click", ["uid": try uid(arguments), "dbl": arguments["dblClick"] as? Bool == true])
        case "hover":
            return try await act(page, arguments, "hover", ["uid": try uid(arguments)])
        case "drag":
            guard let from = arguments["from_uid"] as? String, let to = arguments["to_uid"] as? String else {
                throw Failure(message: "Give from_uid and to_uid.")
            }
            return try await act(page, arguments, "drag", ["fromUid": from, "toUid": to])
        case "fill":
            return try await act(page, arguments, "fill", ["uid": try uid(arguments), "value": "\(arguments["value"] ?? "")"])
        case "fill_form":
            let elements = (arguments["elements"] as? [[String: Any]] ?? []).compactMap { element -> [String: String]? in
                guard let uid = element["uid"] as? String else { return nil }
                return ["uid": uid, "value": "\(element["value"] ?? "")"]
            }
            guard !elements.isEmpty else { throw Failure(message: "Give the elements to fill, each with a uid and a value.") }
            return try await act(page, arguments, "fillForm", ["elements": elements])
        case "type_text":
            guard let text = arguments["text"] as? String else { throw Failure(message: "Give the text to type.") }
            var result = try await act(page, [:], "typeText", ["text": text])
            if let key = arguments["submitKey"] as? String, !key.isEmpty, agent.dialog == nil {
                let pressed = try await act(page, [:], "pressKey", ["combo": key])
                result["text"] = [result["text"] as? String, pressed["text"] as? String].compactMap { $0 }.joined(separator: "\n")
            }
            return result
        case "press_key":
            guard let key = arguments["key"] as? String, !key.isEmpty else { throw Failure(message: "Give a key, e.g. \"Enter\".") }
            return try await act(page, arguments, "pressKey", ["combo": key])
        case "upload_file":
            let files = arguments["files"] as? [[String: Any]] ?? []
            guard !files.isEmpty else { throw Failure(message: "Give the files to upload.") }
            return try await act(page, arguments, "upload", ["uid": try uid(arguments), "files": files])
        case "handle_dialog":
            let accept = arguments["action"] as? String != "dismiss"
            guard let dialog = agent.dialog, agent.answerDialog(accept: accept, text: arguments["promptText"] as? String) else {
                throw Failure(message: "No dialog is open.")
            }
            _ = try? await waitForLoad(page, timeout: 3)
            return ["text": "\(accept ? "Accepted" : "Dismissed") the \(dialog.kind.rawValue) dialog \"\(dialog.message)\"."]
        case "list_console_messages":
            return ["text": listConsole(agent, arguments)]
        case "get_console_message":
            guard let msgid = number(arguments["msgid"]).map(Int.init),
                  let message = agent.console.first(where: { $0.id == msgid }) else {
                throw Failure(message: "No console message with that msgid. Call list_console_messages.")
            }
            var lines = ["ID: \(message.id)", "Message: \(message.type)> \(message.text)"]
            if let source = message.source { lines.append("Source: \(source)") }
            if !message.args.isEmpty { lines.append("### Arguments"); lines += message.args.enumerated().map { "Arg #\($0.offset): \($0.element)" } }
            if let stack = message.stack, !stack.isEmpty { lines.append("### Stack trace"); lines.append(stack) }
            return ["text": lines.joined(separator: "\n")]
        case "list_network_requests":
            return ["text": listNetwork(agent, arguments)]
        case "get_network_request":
            return try networkRequest(agent, arguments)
        case "performance_start_trace":
            return try await startTrace(page, arguments)
        case "performance_stop_trace":
            guard agent.recording != nil else { throw Failure(message: "No recording is running. Call performance_start_trace.") }
            return try await stopTrace(page)
        case "performance_analyze_insight":
            guard let recording = agent.lastRecording else { throw Failure(message: "No recording yet. Call performance_start_trace.") }
            return ["text": BrowserInsights.analyze(recording, insight: arguments["insightName"] as? String ?? "",
                                                    network: agent.network.filter { $0.navigation == agent.navigation })]
        case "lighthouse_audit":
            return try await lighthouse(page, arguments)
        default:
            throw Failure(message: "Unknown tool \(tool).")
        }
    }

    #if DEBUG
    /// Verification hook: opens `url` in the workspace's Browser plane and has an
    /// agent fill the first text field and click "Continue", to see its cursor.
    func debugCursorDemo(workspace: String, url: String) {
        Task { @MainActor in
            let asker = Asker(pane: nil, workspace: workspace)
            _ = try? await self.run("new_page", ["url": url], origin: asker)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let snapshot = (try? await self.run("take_snapshot", [:], origin: asker))?["text"] as? String ?? ""
            func uid(containing label: String) -> String? {
                for line in snapshot.split(separator: "\n") where line.contains(label) {
                    guard let range = line.range(of: "uid=") else { continue }
                    return String(line[range.upperBound...].prefix { !$0.isWhitespace })
                }
                return nil
            }
            if let email = uid(containing: "Email") {
                _ = try? await self.run("fill", ["uid": email, "value": "jack@example.com"], origin: asker)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let go = uid(containing: "Continue") { _ = try? await self.run("click", ["uid": go], origin: asker) }
        }
    }
    #endif

    // MARK: The agent's cursor

    private static let cursorTools: Set<String> = ["click", "hover", "drag", "fill", "fill_form", "type_text", "press_key"]

    /// Tells the page who is about to act on it, so the cursor it draws
    /// carries their name and colour; it stays off when the setting is.
    private func announceCursor(for tool: String, on page: BrowserPage, asker: Asker) async {
        guard Self.cursorTools.contains(tool), !isStart(page) else { return }
        let who = agentIdentity(for: asker)
        _ = try? await page.agent.agentCall("cursorIdentity", ["name": who.name, "hue": who.hue,
                                                              "on": SettingsStore.shared.values.showAgentCursors], timeout: 5)
    }

    /// The agent behind a request: the conversation working in its workspace,
    /// else the agent in its terminal pane.
    private func agentIdentity(for asker: Asker) -> (name: String, hue: String) {
        let fallback = "#8B6BFF"
        func hue(_ hex: String?) -> String { hex.map { $0.hasPrefix("#") ? $0 : "#" + $0 } ?? fallback }
        if let workspace = asker.workspace {
            let sessions = AgentCenter.shared.sessions.filter { $0.workspaceId == workspace }
            if let session = sessions.first(where: { $0.conversation.isRunning }) ?? sessions.first {
                let writer = AgentEditActivity.writer(of: session)
                return (writer.name, hue(writer.hueHex))
            }
        }
        for window in WindowRegistry.shared.windows {
            if let pane = asker.pane, let agent = window.store.snapshot.agents.first(where: { $0.paneId == pane }),
               let brand = AgentBrand.forAgent(agent.agent) {
                return (brand.displayName, hue(brand.hueHex))
            }
        }
        return ("Agent", fallback)
    }

    // MARK: Helpers

    private func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as String: Double(value)
        default: nil
        }
    }

    private func uid(_ arguments: [String: Any]) throws -> String {
        guard let uid = arguments["uid"] as? String, !uid.isEmpty else { throw Failure(message: "Give the element's uid, from take_snapshot.") }
        return uid
    }

    private func timeout(_ arguments: [String: Any], default seconds: Double) -> Double {
        guard let ms = number(arguments["timeout"]), ms > 0 else { return seconds }
        return ms / 1000
    }

    /// A call's value, or the dialog that stopped it as an error.
    private func value(_ outcome: BrowserAgent.Outcome, _ page: BrowserPage) throws -> Any? {
        switch outcome {
        case .value(let value): return value
        case .dialog(let dialog): throw Failure(message: BrowserAgent.describe(dialog))
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits for a load to finish, and says where the page ended up.
    @discardableResult
    private func waitForLoad(_ page: BrowserPage, timeout: Double) async throws -> String {
        await pause(0.15)
        let deadline = Date().addingTimeInterval(timeout)
        while page.view.isLoading, Date() < deadline, page.agent.dialog == nil { await pause(0.05) }
        if let failure = page.failure {
            return "Couldn't load \(failure.url.absoluteString): \(failure.message)"
        }
        let url = page.view.url?.absoluteString ?? "about:blank"
        if page.view.isLoading { return "Still loading \(url) after \(Int(timeout)) seconds." }
        return "Loaded \(url)" + ((page.view.title ?? "").isEmpty ? "." : " (\(page.view.title!)).")
    }

    /// After input: lets a navigation it started finish and the DOM settle.
    private func settle(_ page: BrowserPage, from url: URL?) async -> String? {
        await pause(0.1)
        if page.view.isLoading || page.view.url != url {
            let note = try? await waitForLoad(page, timeout: 10)
            if page.view.url != url { return "The page navigated: " + (note ?? page.view.url?.absoluteString ?? "") }
            return nil
        }
        _ = try? await page.agent.agentCall("settle", [:], timeout: 5)
        return nil
    }

    private func act(_ page: BrowserPage, _ arguments: [String: Any], _ function: String, _ callArguments: KeyValuePairs<String, Any>) async throws -> [String: Any] {
        let before = page.view.url
        let outcome = try await page.agent.agentCall(function, callArguments)
        var lines: [String] = []
        switch outcome {
        case .value(let value):
            lines.append(value as? String ?? "Done.")
        case .dialog(let dialog):
            lines.append("Done, and " + BrowserAgent.describe(dialog).prefix(1).lowercased() + BrowserAgent.describe(dialog).dropFirst())
            return ["text": lines.joined(separator: "\n")]
        }
        if let note = await settle(page, from: before) { lines.append(note) }
        if let dialog = page.agent.dialog { lines.append(BrowserAgent.describe(dialog)) }
        else if arguments["includeSnapshot"] as? Bool == true { lines.append("\n" + (try await snapshot(page, verbose: false))) }
        return ["text": lines.joined(separator: "\n")]
    }

    private func snapshot(_ page: BrowserPage, verbose: Bool) async throws -> String {
        if isStart(page) { return "The page is on the Browser plane's start page (nothing loaded). Call navigate_page or new_page." }
        let text = try await value(page.agent.agentCall("snapshot", ["verbose": verbose]), page)
        return "## Latest page snapshot\n" + (text as? String ?? "")
    }

    private func listPages(_ asker: Asker) -> String {
        let own = try? ownPage(asker, create: false, show: false)
        let chosen = selected[asker.key].flatMap { pagesByID[$0]?.page }
        let pages = allPages()
        guard !pages.isEmpty else { return "## Pages\nNo Browser plane pages are open. new_page opens yours." }
        var lines = ["## Pages"]
        for entry in pages {
            let page = entry.page
            var line = "\(id(of: page)): \(isStart(page) ? "(start page)" : page.view.url?.absoluteString ?? "about:blank")"
            if let title = page.view.title, !title.isEmpty, !isStart(page) { line += " — \(title)" }
            line += " [\(workspaceLabel(entry.workspace, in: entry.window))"
            if page === own { line += ", yours" }
            if page === (chosen ?? own) { line += ", selected" }
            line += "]"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Navigation

    private func navigate(_ page: BrowserPage, _ arguments: [String: Any]) async throws -> String {
        let kind = arguments["type"] as? String ?? (arguments["url"] != nil ? "url" : "reload")
        if let script = arguments["initScript"] as? String, !script.isEmpty { page.agent.runOnNextDocument(script) }
        switch kind {
        case "url":
            guard let url = (arguments["url"] as? String).flatMap(BrowserAddress.url(from:)) else { throw Failure(message: "Give a URL for type url.") }
            page.load(url)
        case "back":
            guard page.view.canGoBack else { throw Failure(message: "There's no page to go back to.") }
            page.view.goBack()
        case "forward":
            guard page.view.canGoForward else { throw Failure(message: "There's no page to go forward to.") }
            page.view.goForward()
        case "reload":
            if arguments["ignoreCache"] as? Bool == true { page.hardReload() } else { page.reload() }
        default:
            throw Failure(message: "type is one of url, back, forward, reload.")
        }
        var note = try await waitForLoad(page, timeout: timeout(arguments, default: 15))
        if let dialog = page.agent.dialog { note += "\n" + BrowserAgent.describe(dialog) }
        return note
    }

    // MARK: Emulation

    private static let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private func emulate(_ page: BrowserPage, _ arguments: [String: Any]) throws -> String {
        var done: [String] = []
        var unsupported: [String] = []
        if let scheme = arguments["colorScheme"] as? String {
            switch scheme {
            case "dark": page.view.appearance = NSAppearance(named: .darkAqua)
            case "light": page.view.appearance = NSAppearance(named: .aqua)
            default: page.view.appearance = nil
            }
            done.append("color scheme \(scheme)")
        }
        if let viewport = arguments["viewport"] as? String {
            if viewport.isEmpty {
                page.customViewport = nil
                done.append("viewport fits the pane")
            } else {
                let parts = viewport.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let size = parts.first?.split(separator: "x").compactMap { Double($0) } ?? []
                guard size.count >= 2, size[0] >= 100, size[1] >= 100 else {
                    throw Failure(message: "viewport is '<width>x<height>x<devicePixelRatio>[,mobile][,touch][,landscape]'.")
                }
                let landscape = parts.contains("landscape")
                page.customViewport = landscape ? CGSize(width: max(size[0], size[1]), height: min(size[0], size[1])) : CGSize(width: size[0], height: size[1])
                if parts.contains("mobile"), arguments["userAgent"] == nil { page.view.customUserAgent = Self.mobileAgent }
                done.append("viewport \(Int(page.customViewport!.width)) × \(Int(page.customViewport!.height))")
                if size.count > 2, size[2] != 1 { unsupported.append("device pixel ratio (this display's is used)") }
                if parts.contains("touch") { unsupported.append("touch events") }
            }
        }
        fitOffscreen(page)
        if let agent = arguments["userAgent"] as? String {
            page.view.customUserAgent = agent.isEmpty ? nil : agent
            done.append(agent.isEmpty ? "default user agent" : "user agent")
        }
        if let location = arguments["geolocation"] as? String {
            let parts = location.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if location.isEmpty {
                page.agent.clearGeolocation()
                done.append("geolocation cleared (from the next load)")
            } else {
                guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else {
                    throw Failure(message: "geolocation is '<latitude>,<longitude>'.")
                }
                page.agent.setGeolocation(latitude: parts[0], longitude: parts[1])
                done.append("geolocation \(parts[0]),\(parts[1])")
            }
        }
        if let raw = arguments["extraHttpHeaders"] as? String {
            if raw.isEmpty {
                page.agent.extraHeaders = [:]
                done.append("extra headers cleared")
            } else {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                    throw Failure(message: "extraHttpHeaders is a JSON object of strings.")
                }
                page.agent.extraHeaders = object.mapValues { "\($0)" }
                done.append("extra headers on top-level loads")
            }
        }
        if let network = arguments["networkConditions"] as? String, network != "No emulation" { unsupported.append("network throttling (\(network))") }
        if let rate = number(arguments["cpuThrottlingRate"]), rate > 1 { unsupported.append("CPU throttling") }
        var text = done.isEmpty ? "Nothing to emulate." : "Emulating: " + done.joined(separator: ", ") + "."
        if !unsupported.isEmpty { text += "\nNot supported in WebKit (Octet's browser): " + unsupported.joined(separator: ", ") + "." }
        return text
    }

    // MARK: Screenshots

    private func screenshot(_ page: BrowserPage, _ arguments: [String: Any]) async throws -> [String: Any] {
        let view = page.view
        guard !isStart(page) else { throw Failure(message: "Nothing is loaded. Call navigate_page first.") }
        let config = WKSnapshotConfiguration()
        var restore: NSSize?
        var what = "the visible viewport"
        if let uid = arguments["uid"] as? String, !uid.isEmpty {
            guard let rect = try await value(page.agent.agentCall("rect", ["uid": uid]), page) as? [String: Double] else {
                throw Failure(message: "Couldn't find where that element is.")
            }
            let scale = view.bounds.width / max(rect["viewportWidth"] ?? 1, 1)
            let frame = CGRect(x: (rect["x"] ?? 0) * scale, y: (rect["y"] ?? 0) * scale,
                               width: (rect["width"] ?? 0) * scale, height: (rect["height"] ?? 0) * scale).intersection(view.bounds)
            guard !frame.isNull, frame.width >= 1, frame.height >= 1 else { throw Failure(message: "That element has no visible area.") }
            config.rect = frame
            what = "the element"
        } else if arguments["fullPage"] as? Bool == true,
                  let extent = try await value(page.agent.agentCall("extent"), page) as? [String: Double] {
            let scale = view.bounds.width / max(extent["viewportWidth"] ?? 1, 1)
            let height = min((extent["height"] ?? 0) * scale, 16_000)
            if height > view.bounds.height + 1 {
                restore = view.frame.size
                view.setFrameSize(NSSize(width: view.frame.width, height: height))
                await pause(0.3)
            }
            what = "the full page"
        }
        defer { if let restore { view.setFrameSize(restore) } }
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: config) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: Failure(message: "Couldn't take the screenshot" + (view.window == nil ? ": the page isn't on screen. Open the Browser plane in its workspace." : ": \(error?.localizedDescription ?? "unknown error")."))) }
            }
        }
        let format = (arguments["format"] as? String ?? "webp").lowercased()
        let quality = number(arguments["quality"]).map { $0 / 100 } ?? 0.8
        guard let encoded = Self.encode(image, format: format, quality: quality, maxWidth: 1280) else {
            throw Failure(message: "Couldn't encode the screenshot.")
        }
        var text = "Took a screenshot of \(what)."
        if encoded.mime != "image/\(format)" { text += " (macOS can't write \(format) here, so it's \(encoded.mime.dropFirst(6)).)" }
        return ["text": text, "image": ["data": encoded.data.base64EncodedString(), "mimeType": encoded.mime]]
    }

    static func encode(_ image: NSImage, format: String, quality: Double, maxWidth: CGFloat) -> (data: Data, mime: String)? {
        guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if CGFloat(cg.width) > maxWidth {
            let height = Int(CGFloat(cg.height) * maxWidth / CGFloat(cg.width))
            guard let context = CGContext(data: nil, width: Int(maxWidth), height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: Int(maxWidth), height: height))
            guard let scaled = context.makeImage() else { return nil }
            cg = scaled
        }
        let attempts: [(UTType, String)] = switch format {
        case "png": [(.png, "image/png")]
        case "jpeg", "jpg": [(.jpeg, "image/jpeg")]
        default: [(.webP, "image/webp"), (.jpeg, "image/jpeg")]
        }
        for (type, mime) in attempts {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { continue }
            let options = type == .png ? nil : [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            CGImageDestinationAddImage(destination, cg, options)
            if CGImageDestinationFinalize(destination) { return (data as Data, mime) }
        }
        return nil
    }

    // MARK: Scripts

    private func evaluate(_ page: BrowserPage, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard let function = arguments["function"] as? String, !function.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Give a function, e.g. () => document.title.")
        }
        let uids = (arguments["args"] as? [Any] ?? []).compactMap { $0 as? String }
        let token = String(UUID().uuidString.prefix(8))
        if !uids.isEmpty { _ = try value(await page.agent.agentCall("markArgs", ["uids": uids, "token": token]), page) }
        let body = """
        const els = Array.from({ length: count }, (_, i) => {
          const el = document.querySelector('[data-octet-arg="' + token + '-' + i + '"]');
          if (el) el.removeAttribute('data-octet-arg');
          return el;
        });
        const fn = (
        \(function)
        );
        const value = await fn(...els);
        const seen = new WeakSet();
        const json = JSON.stringify(value, (k, v) => {
          if (typeof v === 'object' && v !== null) { if (seen.has(v)) return '[Circular]'; seen.add(v); }
          if (typeof v === 'bigint') return v.toString();
          if (typeof Element !== 'undefined' && v instanceof Element) return '<' + v.localName + '>';
          return v;
        });
        return json === undefined ? 'null' : json;
        """
        let before = page.view.url
        page.agent.autoDialog = arguments["dialogAction"] as? String ?? "accept"
        defer { page.agent.autoDialog = nil }
        let outcome = try await page.agent.run(body, arguments: ["count": uids.count, "token": token], world: .page)
        let result: Any?
        switch outcome {
        case .value(let value): result = value
        case .dialog(let dialog): throw Failure(message: BrowserAgent.describe(dialog))
        }
        let json = (result.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) })
            .map { String(decoding: $0, as: UTF8.self) } ?? "null"
        var text = "Script ran on page and returned:\n```json\n\(json)\n```"
        if arguments["waitForStableDom"] as? Bool != false, let note = await settle(page, from: before) { text += "\n" + note }
        return ["text": text, "summary": "Script ran on page."]
    }

    // MARK: Console and network

    private func pageOf<T>(_ items: [T], _ arguments: [String: Any]) -> (items: [T], note: String) {
        guard let size = number(arguments["pageSize"]).map(Int.init), size > 0 else { return (items, "") }
        let index = max(0, Int(number(arguments["pageIdx"]) ?? 0))
        let start = min(index * size, items.count)
        let slice = Array(items[start..<min(start + size, items.count)])
        let pages = max(1, Int((Double(items.count) / Double(size)).rounded(.up)))
        return (slice, "Showing \(slice.isEmpty ? 0 : start + 1)-\(start + slice.count) of \(items.count) (page \(index + 1) of \(pages)).")
    }

    private func listConsole(_ agent: BrowserAgent, _ arguments: [String: Any]) -> String {
        let types = Set((arguments["types"] as? [Any] ?? []).compactMap { $0 as? String })
        let preserved = arguments["includePreservedMessages"] as? Bool == true
        let stacks = arguments["includeStackTraces"] as? Bool == true
        let all = agent.console.filter { (preserved || $0.navigation == agent.navigation) && (types.isEmpty || types.contains($0.type)) }
        let (shown, note) = pageOf(all, arguments)
        guard !shown.isEmpty else { return "## Console messages\n<no console messages found>" }
        var lines = ["## Console messages"]
        if !note.isEmpty { lines.append(note) }
        var navigation = shown.first?.navigation
        for message in shown {
            if preserved, message.navigation != navigation { lines.append("--- navigation ---"); navigation = message.navigation }
            lines.append("msgid=\(message.id) [\(message.type)] \(message.text.count > 500 ? String(message.text.prefix(500)) + "…" : message.text)")
            if stacks, let stack = message.stack, !stack.isEmpty { lines.append(stack.split(separator: "\n").prefix(8).map { "    " + $0 }.joined(separator: "\n")) }
        }
        return lines.joined(separator: "\n")
    }

    private func listNetwork(_ agent: BrowserAgent, _ arguments: [String: Any]) -> String {
        let types = Set((arguments["resourceTypes"] as? [Any] ?? []).compactMap { $0 as? String })
        let preserved = arguments["includePreservedRequests"] as? Bool == true
        let all = agent.network.filter { (preserved || $0.navigation == agent.navigation) && (types.isEmpty || types.contains($0.resourceType)) }
        let (shown, note) = pageOf(all, arguments)
        guard !shown.isEmpty else { return "## Network requests\nNo requests found." }
        var lines = ["## Network requests"]
        if !note.isEmpty { lines.append(note) }
        for request in shown {
            let status = request.failed.map { "[failed - \($0)]" } ?? request.status.map { "[\($0)]" } ?? (request.end == nil && request.start != nil && request.resourceType != "websocket" ? "[pending]" : "[loaded]")
            lines.append("reqid=\(request.id) \(request.method) \(request.url) \(status) \(request.resourceType)")
        }
        return lines.joined(separator: "\n")
    }

    private func networkRequest(_ agent: BrowserAgent, _ arguments: [String: Any]) throws -> [String: Any] {
        let wanted = number(arguments["reqid"]).map(Int.init)
        guard let request = wanted.map({ id in agent.network.first { $0.id == id } }) ?? agent.network.last else {
            throw Failure(message: "No request with that reqid. Call list_network_requests.")
        }
        var lines = ["## Request \(request.url)", "Status: \(request.failed.map { "failed (\($0))" } ?? request.status.map { "\($0) \(request.statusText ?? "")" } ?? "unknown")",
                     "Method: \(request.method)", "Type: \(request.resourceType)"]
        if let start = request.start, let end = request.end { lines.append(String(format: "Duration: %.0f ms", end - start)) }
        if let size = request.size, size > 0 { lines.append("Size: \(size) bytes") }
        func headers(_ title: String, _ values: [String: String]) {
            guard !values.isEmpty else { return }
            lines.append("### \(title)")
            lines += values.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }
        }
        headers("Request Headers", request.requestHeaders)
        headers("Response Headers", request.responseHeaders)
        if request.requestHeaders.isEmpty, request.responseHeaders.isEmpty, ["document", "fetch", "xhr"].contains(request.resourceType) == false {
            lines.append("(Headers and bodies are captured for the document, fetch and XHR requests; this one comes from Resource Timing.)")
        }
        var save: [String: String] = [:]
        if let body = request.requestBody {
            if (arguments["requestFilePath"] as? String)?.isEmpty == false { save["request"] = body }
            else { lines.append("### Request Body"); lines.append(body.count > 10_000 ? String(body.prefix(10_000)) + "… (\(body.count) characters)" : body) }
        }
        if let body = request.responseBody {
            if (arguments["responseFilePath"] as? String)?.isEmpty == false { save["response"] = body }
            else { lines.append("### Response Body"); lines.append(body.count > 10_000 ? String(body.prefix(10_000)) + "… (\(body.count) characters; give responseFilePath for all of it)" : body) }
        }
        return ["text": lines.joined(separator: "\n"), "save": save]
    }

    // MARK: Performance

    private func startTrace(_ page: BrowserPage, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard !isStart(page) else { throw Failure(message: "Navigate to the page to record first.") }
        if arguments["reload"] as? Bool != false {
            page.reload()
            try await waitForLoad(page, timeout: 30)
            await pause(1)
        }
        _ = try value(await page.agent.agentCall("startRecording"), page)
        page.agent.recording = ["started": Date().timeIntervalSince1970]
        if arguments["autoStop"] as? Bool == false {
            return ["text": "Recording on page \(id(of: page)). Interact with the page, then call performance_stop_trace."]
        }
        // Long enough for LCP to settle and late layout shifts to land.
        await pause(3)
        return try await stopTrace(page)
    }

    private func stopTrace(_ page: BrowserPage) async throws -> [String: Any] {
        guard let metrics = try value(await page.agent.agentCall("metrics"), page) as? [String: Any] else {
            throw Failure(message: "Couldn't read the page's performance data.")
        }
        page.agent.recording = nil
        page.agent.lastRecording = metrics
        let document = page.agent.network.last { $0.resourceType == "document" && $0.navigation == page.agent.navigation }
        var save: [String: String] = [:]
        if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
            save["trace"] = String(decoding: data, as: UTF8.self)
        }
        return ["text": BrowserInsights.summary(metrics, document: document), "save": save]
    }

    // MARK: Audits

    private func lighthouse(_ page: BrowserPage, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard !isStart(page) else { throw Failure(message: "Navigate to the page to audit first.") }
        let mobile = arguments["device"] as? String == "mobile"
        let previous = (page.customViewport, page.view.customUserAgent)
        if mobile {
            page.customViewport = CGSize(width: 412, height: 823)
            page.view.customUserAgent = Self.mobileAgent
            fitOffscreen(page)
        }
        defer {
            if mobile {
                page.customViewport = previous.0
                page.view.customUserAgent = previous.1
                fitOffscreen(page)
            }
        }
        if arguments["mode"] as? String != "snapshot" || mobile {
            page.reload()
            try await waitForLoad(page, timeout: 30)
            await pause(1)
        }
        guard var report = try value(await page.agent.agentCall("audit", [:], timeout: 60), page) as? [String: Any],
              var results = report["results"] as? [String: [[String: Any]]] else {
            throw Failure(message: "Couldn't audit the page.")
        }
        let errors = page.agent.console.filter { $0.navigation == page.agent.navigation && $0.type == "error" }
        results["best-practices", default: []].append(["id": "errors-in-console", "title": "No errors logged to the console", "weight": 1,
                                                       "passed": errors.isEmpty, "items": errors.prefix(10).map(\.text), "count": errors.count])
        report["results"] = results
        report["device"] = mobile ? "mobile" : "desktop"
        var lines = ["## Audit of \(report["url"] as? String ?? "") (\(mobile ? "mobile" : "desktop"))",
                     "Checks run in the page: a subset of Lighthouse's, without its performance category."]
        var scores: [String: Int] = [:]
        for category in ["accessibility", "best-practices", "seo"] {
            let checks = results[category] ?? []
            let total = checks.reduce(0.0) { $0 + ($1["weight"] as? Double ?? Double($1["weight"] as? Int ?? 1)) }
            let passed = checks.filter { $0["passed"] as? Bool == true }.reduce(0.0) { $0 + ($1["weight"] as? Double ?? Double($1["weight"] as? Int ?? 1)) }
            let score = total > 0 ? Int((passed / total * 100).rounded()) : 100
            scores[category] = score
            lines.append("\n### \(category) — \(score)/100")
            for check in checks where check["passed"] as? Bool != true {
                lines.append("- FAIL \(check["id"] ?? ""): \(check["title"] ?? "") (\(check["count"] ?? 0))")
                for item in (check["items"] as? [String] ?? []).prefix(5) { lines.append("    • \(item)") }
            }
            let passing = checks.filter { $0["passed"] as? Bool == true }.compactMap { $0["id"] as? String }
            if !passing.isEmpty { lines.append("- passed: " + passing.joined(separator: ", ")) }
        }
        report["scores"] = scores
        var save: [String: String] = [:]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            save["report"] = String(decoding: data, as: UTF8.self)
        }
        return ["text": lines.joined(separator: "\n"), "save": save]
    }
}
