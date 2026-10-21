import Foundation

/// Letting an agent drive Octet's own Browser plane: the page beside the
/// terminal, which the person watches. The tools are chrome-devtools MCP's,
/// by name and arguments, so an agent that knows those knows these, but they
/// act on the plane's WebKit page instead of a Chrome reached over CDP:
/// localhost dev servers, the person's sign-ins in the plane, and what the
/// agent does shows on screen. The agents' side is a stdio MCP server
/// (`octet-cli browser-mcp`); it asks the app over a Unix socket only this
/// user can open, one JSON line each way. Off until the Browser Control
/// plugin is turned on.
enum BrowserControl {
    static let socketName = "browser.sock"
    static let socketVariable = "OCTET_BROWSER_SOCKET"

    static func socketPath(session: String?, home: String = NSHomeDirectory()) -> String {
        let base = home + "/Library/Application Support/Octet"
        guard let session, !session.isEmpty, session != "octet" else { return base + "/" + socketName }
        return base + "/sessions/\(session)/" + socketName
    }

    static func environment(session: String, home: String = NSHomeDirectory()) -> [String: String] {
        [socketVariable: socketPath(session: session, home: home)]
    }

    static func resolveSocket(environment: [String: String]) -> String {
        if let path = environment[socketVariable], !path.isEmpty { return path }
        return socketPath(session: environment["OCTET_SESSION"] ?? PeerControl.session(ofServer: environment[EngineProtocol.socketPathVariable]))
    }

    /// Where a request comes from: a pane or a conversation Octet started.
    /// Nil elsewhere: an agent in another terminal app has no plane to drive.
    struct Origin: Equatable {
        let pane: String?
        let workspace: String?

        static func current(_ environment: [String: String]) -> Origin? {
            func value(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
            let pane = value(EngineProtocol.paneIdVariable)
            let inPane = pane != nil && value(EngineProtocol.socketPathVariable) != nil
            guard inPane || value(socketVariable) != nil else { return nil }
            return Origin(pane: pane, workspace: value(EngineProtocol.workspaceIdVariable))
        }

        var params: [String: Any] {
            var params: [String: Any] = [:]
            if let pane { params["from_pane"] = pane }
            if let workspace { params["from_workspace"] = workspace }
            return params
        }
    }

    static let notInOctet = "This only works inside Octet: run it from an Octet terminal pane or conversation."

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// One tool call, answered by the app.
    static func call(socketPath: String, tool: String, arguments: [String: Any], origin: Origin) throws -> [String: Any] {
        let connection: EngineSocketConnection
        do {
            connection = try EngineSocketConnection(path: socketPath)
        } catch {
            throw Failure(message: "Octet isn't reachable, or Browser Control is off (Octet Settings › Plugins).")
        }
        var params = origin.params
        params["tool"] = tool
        params["arguments"] = arguments
        try connection.send(["method": "tool", "params": params])
        let line = try connection.readLine()
        guard let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw Failure(message: "Octet sent back something unreadable.")
        }
        if let error = answer["error"] as? String { throw Failure(message: error) }
        return answer["result"] as? [String: Any] ?? [:]
    }
}

/// The agents' side: chrome-devtools MCP's tools, answered by the plane.
enum BrowserMCP {
    static let serverName = "octet-browser"

    // MARK: - Tools

    private static let pageId: [String: Any] = [
        "type": "number",
        "description": "Targets a specific page by ID, from list_pages or new_page. Defaults to your workspace's Browser plane page.",
    ]
    private static let uid: [String: Any] = ["type": "string", "description": "The uid of an element on the page from the page content snapshot"]
    private static let includeSnapshot: [String: Any] = ["type": "boolean", "description": "Whether to include a snapshot in the response. Default is false."]
    private static let timeout: [String: Any] = ["type": "integer", "description": "Maximum wait time in milliseconds. If set to 0, the default timeout will be used."]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var properties = properties
        if name != "list_pages" && name != "new_page" && properties["pageId"] == nil { properties["pageId"] = pageId }
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    static let tools: [[String: Any]] = [
        // Pages
        tool("list_pages", "Get a list of pages open in Octet's Browser plane: one per workspace that has the plane open. Yours is marked."),
        tool("new_page", "Load a URL in your workspace's Browser plane, opening the plane beside the terminal if it isn't. Octet has one page per workspace (no tabs), so this replaces what the plane showed. Returns the page's ID.",
             ["url": ["type": "string", "description": "URL to load."],
              "background": ["type": "boolean", "description": "Don't open the plane if it isn't open: the page loads unseen. Default false."],
              "timeout": timeout], required: ["url"]),
        tool("select_page", "Select a page as the default for later calls that leave out pageId.",
             ["pageId": ["type": "number", "description": "The ID of the page to select. Call list_pages to list pages."],
              "bringToFront": ["type": "boolean", "description": "Whether to show the Browser plane for it."]], required: ["pageId"]),
        tool("close_page", "Closes the page: the plane goes back to its start page.",
             ["pageId": ["type": "number", "description": "The ID of the page to close. Call list_pages to list pages."]], required: ["pageId"]),
        tool("navigate_page", "Go to a URL, or back, forward, or reload.",
             ["type": ["type": "string", "enum": ["url", "back", "forward", "reload"], "description": "Navigate the page by URL, back or forward in history, or reload."],
              "url": ["type": "string", "description": "Target URL (only type=url)"],
              "ignoreCache": ["type": "boolean", "description": "Whether to ignore cache on reload."],
              "initScript": ["type": "string", "description": "A JavaScript script to be executed on each new document before any other scripts for the next navigation."],
              "handleBeforeUnload": ["type": "string", "enum": ["accept", "dismiss"], "description": "Whether to accept or dismiss beforeunload dialogs triggered by this navigation. Default is accept."],
              "timeout": timeout]),
        tool("resize_page", "Sets the page's viewport to the given size in CSS pixels (the plane scrolls if it's smaller). Use emulate with an empty viewport to fit the pane again.",
             ["width": ["type": "number", "description": "Page width"], "height": ["type": "number", "description": "Page height"]], required: ["width", "height"]),
        tool("emulate", "Emulates various features on the target page. WebKit can't throttle the network or CPU; those report as unsupported.",
             ["colorScheme": ["type": "string", "enum": ["dark", "light", "auto"], "description": "Emulate the dark or the light mode. Set to \"auto\" to reset to the default."],
              "viewport": ["type": "string", "description": "Emulate device viewports '<width>x<height>x<devicePixelRatio>[,mobile][,touch][,landscape]'. 'mobile' also uses a mobile Safari user agent. Empty string to fit the pane again."],
              "userAgent": ["type": "string", "description": "User agent to emulate. Set to empty string to clear the user agent override."],
              "geolocation": ["type": "string", "description": "Geolocation (`<latitude>,<longitude>`) to emulate. Empty string to clear it."],
              "extraHttpHeaders": ["type": "string", "description": "Extra HTTP headers as a JSON string object, sent with the page's top-level navigations (not its subresources). Pass an empty string to clear."],
              "networkConditions": ["type": "string", "enum": ["Offline", "Slow 3G", "Fast 3G", "Slow 4G", "Fast 4G"], "description": "Not supported in WebKit."],
              "cpuThrottlingRate": ["type": "number", "description": "Not supported in WebKit."]]),
        tool("wait_for", "Wait for the specified text to appear on the selected page.",
             ["text": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "Non-empty list of texts. Resolves when any value appears on the page."],
              "timeout": timeout], required: ["text"]),
        // Reading
        tool("take_snapshot", "Take a text snapshot of the target page based on the a11y tree. The snapshot lists page elements along with a unique identifier (uid). Always use the latest snapshot. Prefer taking a snapshot over taking a screenshot.",
             ["verbose": ["type": "boolean", "description": "Whether to include generic containers too. Default is false."],
              "filePath": ["type": "string", "description": "The absolute path, or a path relative to the current working directory, to save the snapshot to instead of attaching it to the response."]]),
        tool("take_screenshot", "Take a screenshot of the page or element.",
             ["format": ["type": "string", "enum": ["png", "jpeg", "webp"], "description": "Type of format to save the screenshot as. Default is \"webp\" (jpeg where macOS can't write webp)."],
              "quality": ["type": "number", "minimum": 0, "maximum": 100, "description": "Compression quality for JPEG and WebP formats (0-100)."],
              "uid": ["type": "string", "description": "The uid of an element on the page from the page content snapshot. If omitted, takes a page screenshot."],
              "fullPage": ["type": "boolean", "description": "If set to true takes a screenshot of the full page instead of the currently visible viewport. Incompatible with uid."],
              "filePath": ["type": "string", "description": "The absolute path, or a path relative to the current working directory, to save the screenshot to instead of attaching it to the response."]]),
        tool("evaluate_script", "Evaluate a JavaScript function inside the target page. Returns the response as JSON, so returned values have to be JSON-serializable.",
             ["function": ["type": "string", "description": "A JavaScript function declaration to be executed by the tool in the target page.\nExample without arguments: `() => document.title` or `async () => await fetch(\"example.com\")`.\nExample with arguments: `(el) => el.innerText`\n"],
              "args": ["type": "array", "items": uid, "description": "An optional list of arguments to pass to the function."],
              "dialogAction": ["type": "string", "description": "Handle dialogs while execution. \"accept\", \"dismiss\", or string for response of window.prompt. Defaults to accept."],
              "waitForStableDom": ["type": "boolean", "description": "Whether to wait for the DOM to settle. Pass false if the script only reads data. Defaults to true."],
              "filePath": ["type": "string", "description": "The absolute or relative path to a file to save the script output to. If omitted, the output is returned inline."]],
             required: ["function"]),
        tool("get_css_styles", "Retrieve matched CSS rules, inline styles, inherited styles, and cascade information for an element identified by its UID. Results are paginated and return 10 rules per page by default; use pageIdx to page through the remaining rules. Requires a UID from take_snapshot. Rules in cross-origin stylesheets can't be read.",
             ["uid": uid,
              "pageIdx": ["type": "integer", "minimum": 0, "default": 0, "description": "Page number to return (0-based)."],
              "pageSize": ["type": "integer", "default": 10, "description": "Maximum number of CSS rules to return per page."]], required: ["uid"]),
        // Input
        tool("click", "Clicks on the provided element", ["uid": uid, "dblClick": ["type": "boolean", "description": "Set to true for double clicks. Default is false."], "includeSnapshot": includeSnapshot], required: ["uid"]),
        tool("hover", "Hover over the provided element", ["uid": uid, "includeSnapshot": includeSnapshot], required: ["uid"]),
        tool("drag", "Drag an element onto another element",
             ["from_uid": ["type": "string", "description": "The uid of the element to drag"],
              "to_uid": ["type": "string", "description": "The uid of the element to drop into"], "includeSnapshot": includeSnapshot],
             required: ["from_uid", "to_uid"]),
        tool("fill", "Type text into an input, text area or select an option from a <select> element.",
             ["uid": uid, "value": ["type": "string", "description": "The value to fill in. \"true\" or \"false\" for checkboxes and toggles, \"true\" for radio buttons."], "includeSnapshot": includeSnapshot],
             required: ["uid", "value"]),
        tool("fill_form", "Fill out multiple form elements (inputs, selects, checkboxes, radios) at once. ALWAYS prefer this tool over multiple individual 'fill' or 'click' calls when interacting with forms.",
             ["elements": ["type": "array", "description": "Elements from snapshot to fill out.",
                           "items": ["type": "object", "properties": ["uid": uid, "value": ["type": "string", "description": "Value for the element."]], "required": ["uid", "value"]] as [String: Any]],
              "includeSnapshot": includeSnapshot], required: ["elements"]),
        tool("type_text", "Type text using keyboard into a previously focused input",
             ["text": ["type": "string", "description": "The text to type"],
              "submitKey": ["type": "string", "description": "Optional key to press after typing. E.g., \"Enter\", \"Tab\", \"Escape\""]], required: ["text"]),
        tool("press_key", "Press a key or key combination. Use this when other input methods like fill() cannot be used (e.g., keyboard shortcuts, navigation keys, or special key combinations).",
             ["key": ["type": "string", "description": "A key or a combination (e.g., \"Enter\", \"Control+A\", \"Control++\", \"Control+Shift+R\"). Modifiers: Control, Shift, Alt, Meta"], "includeSnapshot": includeSnapshot],
             required: ["key"]),
        tool("upload_file", "Upload a file through a provided element.",
             ["uid": ["type": "string", "description": "The uid of the file input element, or of an element (a label or button) that opens a file chooser"],
              "filePaths": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "One or more file paths to upload, absolute or relative to the current working directory."],
              "includeSnapshot": includeSnapshot], required: ["uid", "filePaths"]),
        tool("handle_dialog", "If a browser dialog (alert, confirm, prompt) was opened, use this command to handle it",
             ["action": ["type": "string", "enum": ["accept", "dismiss"], "description": "Whether to dismiss or accept the dialog"],
              "promptText": ["type": "string", "description": "Optional prompt text to enter into the dialog."]], required: ["action"]),
        // Debugging
        tool("list_console_messages", "List all console messages for the target page since the last navigation.",
             ["pageSize": ["type": "integer", "description": "Maximum number of messages to return. When omitted, returns all messages."],
              "pageIdx": ["type": "integer", "minimum": 0, "description": "Page number to return (0-based)."],
              "types": ["type": "array", "items": ["type": "string", "enum": ["log", "debug", "info", "error", "warn", "dir", "dirxml", "table", "trace", "clear", "startGroup", "startGroupCollapsed", "endGroup", "assert", "profile", "profileEnd", "count", "timeEnd", "verbose", "issue"]], "description": "Filter messages to only return messages of the specified types."],
              "includePreservedMessages": ["type": "boolean", "default": false, "description": "Set to true to return the preserved messages over the last 3 navigations."],
              "includeStackTraces": ["type": "boolean", "default": false, "description": "Set to true to include the stack trace for each message when available."]]),
        tool("get_console_message", "Gets a console message by its ID. You can get all messages by calling list_console_messages.",
             ["msgid": ["type": "number", "description": "The msgid of a console message on the page from the listed console messages"]], required: ["msgid"]),
        tool("list_network_requests", "Lists the most recent requests for the target page since the last navigation. The document, fetch and XHR requests carry status and headers; other resources come from Resource Timing.",
             ["pageSize": ["type": "integer", "description": "Maximum number of requests to return. When omitted, returns all requests."],
              "pageIdx": ["type": "integer", "minimum": 0, "description": "Page number to return (0-based)."],
              "resourceTypes": ["type": "array", "items": ["type": "string", "enum": ["document", "stylesheet", "image", "media", "font", "script", "texttrack", "xhr", "fetch", "prefetch", "eventsource", "websocket", "manifest", "signedexchange", "ping", "cspviolationreport", "preflight", "fedcm", "other"]], "description": "Filter requests to only return requests of the specified resource types."],
              "includePreservedRequests": ["type": "boolean", "default": false, "description": "Set to true to return the preserved requests over the last 3 navigations."]]),
        tool("get_network_request", "Gets a network request by its reqid, with its headers and bodies where they were captured.",
             ["reqid": ["type": "number", "description": "The reqid of the network request. If omitted returns the most recent request."],
              "requestFilePath": ["type": "string", "description": "The absolute or relative path to save the request body to. If omitted, the body is returned inline."],
              "responseFilePath": ["type": "string", "description": "The absolute or relative path to save the response body to. If omitted, the body is returned inline."]]),
        tool("performance_start_trace", "Start a performance recording on the target page: navigation timing, paint, LCP, layout shifts, long tasks and resources, from the browser's Performance APIs (WebKit has no DevTools trace). Use to find frontend performance issues and Core Web Vitals.",
             ["reload": ["type": "boolean", "default": true, "description": "Whether the page is reloaded once recording has started. Navigate to the right URL BEFORE starting."],
              "autoStop": ["type": "boolean", "default": true, "description": "Whether the recording stops by itself after the page settles."],
              "filePath": ["type": "string", "description": "A path to save the raw recording (JSON) to."]]),
        tool("performance_stop_trace", "Stop the active performance recording on the target page.",
             ["filePath": ["type": "string", "description": "A path to save the raw recording (JSON) to."]]),
        tool("performance_analyze_insight", "Provides more detailed information on a specific Performance Insight that was highlighted in the results of a recording.",
             ["insightSetId": ["type": "string", "description": "The id for the specific insight set. Only use the ids given in the \"Available insight sets\" list."],
              "insightName": ["type": "string", "description": "The name of the Insight you want more information on. For example: \"DocumentLatency\" or \"LCPBreakdown\""]],
             required: ["insightSetId", "insightName"]),
        tool("lighthouse_audit", "Audit the page for accessibility, SEO and best practices, with checks run in the page (a subset of Lighthouse's; WebKit can't run Lighthouse itself). This excludes performance: use performance_start_trace.",
             ["mode": ["type": "string", "enum": ["navigation", "snapshot"], "default": "navigation", "description": "\"navigation\" reloads & audits. \"snapshot\" analyzes current state."],
              "device": ["type": "string", "enum": ["desktop", "mobile"], "default": "desktop", "description": "Device to emulate while auditing."],
              "outputDirPath": ["type": "string", "description": "Directory to write report.json to. If omitted, nothing is written."]]),
    ]

    static var toolNames: [String] { tools.compactMap { $0["name"] as? String } }

    static let instructions = """
    You're running inside Octet, and Octet's Browser plane (the page beside the terminal) is yours to drive with these tools: the same names and arguments as chrome-devtools MCP, acting on the plane's WebKit page. The person sees what you do there, so say in the conversation what you found or did.
    - Start with new_page (or list_pages) and pass that pageId to later calls; leaving it out uses your workspace's page. There's one page per workspace, no tabs.
    - Read with take_snapshot, not screenshots: it returns the page's structure with a uid for each element, which click, fill, hover, drag and upload_file take. Uids last until the page navigates; take a new snapshot after. take_screenshot is for when the look is the point.
    - localhost and dev servers on this Mac load fine. Sign-ins in the plane are the person's: never sign out, change credentials or act on an account beyond the task.
    - Input is dispatched as DOM events: it works for forms, links and app handlers, but CSS :hover doesn't apply and some sites ignore untrusted events. Prefer fill_form for forms.
    - Dialogs (alert, confirm, prompt) wait for handle_dialog; a call that opens one says so. Avoid clicking what raises one unless the task needs it.
    - list_console_messages and list_network_requests are since the last navigation. Lighthouse and traces are approximations from the page's own APIs.
    - If calls keep failing (2–3 tries), elements don't respond or pages don't load, stop and tell the person what you tried instead of retrying the same thing.
    """

    // MARK: - Serving

    /// Tools whose answer can go to a file the agent names, and which key.
    /// The file is written here, in the agent's folder, not by the app.
    static func respond(to line: String, origin: BrowserControl.Origin?, cwd: String,
                        call: (String, [String: Any]) throws -> [String: Any]) -> String? {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch request["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": serverName, "version": "1"]]
            if origin != nil { result["instructions"] = instructions }
        case "tools/list":
            result = ["tools": origin == nil ? [] : tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            var arguments = params["arguments"] as? [String: Any] ?? [:]
            guard origin != nil else {
                result = content([text(BrowserControl.notInOctet)], error: true)
                break
            }
            guard toolNames.contains(name) else {
                result = content([text("Unknown tool \(name).")], error: true)
                break
            }
            do {
                if name == "upload_file" { arguments["files"] = try readUploads(arguments["filePaths"], cwd: cwd) }
                let answer = try call(name, arguments)
                result = content(try deliver(answer, tool: name, arguments: arguments, cwd: cwd))
            } catch {
                result = content([text(String(describing: error))], error: true)
            }
        default:
            guard id != nil else { return nil }
            result = [:]
        }
        guard let id else { return nil }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        return (try? JSONSerialization.data(withJSONObject: response)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }

    private static func content(_ items: [[String: Any]], error: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["content": items]
        if error { result["isError"] = true }
        return result
    }

    /// The app's answer as MCP content, writing what the agent asked to go
    /// to a file: `text`, an `image` (`data`, `mimeType`), and for some tools
    /// a `save` of named parts (`snapshot`, `output`, `trace`, `request`,
    /// `response`, `report`).
    static func deliver(_ answer: [String: Any], tool: String, arguments: [String: Any], cwd: String) throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var notes: [String] = []
        let save = answer["save"] as? [String: String] ?? [:]
        func write(_ value: String, base64: Bool = false, to rawPath: String) throws -> String {
            let path = resolve(rawPath, cwd: cwd)
            let data = base64 ? (Data(base64Encoded: value) ?? Data()) : Data(value.utf8)
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                throw BrowserControl.Failure(message: "Couldn't write \(path): \(error.localizedDescription)")
            }
            return path
        }
        var body = answer["text"] as? String ?? ""
        switch tool {
        case "take_snapshot", "evaluate_script":
            if let path = arguments["filePath"] as? String, !path.isEmpty {
                let saved = try write(body, to: path)
                body = (answer["summary"] as? String).map { $0 + "\n" } ?? ""
                notes.append("Saved to \(saved).")
            }
        case "performance_start_trace", "performance_stop_trace":
            if let path = arguments["filePath"] as? String, !path.isEmpty, let trace = save["trace"] {
                notes.append("Raw recording saved to \(try write(trace, to: path)).")
            }
        case "get_network_request":
            for (key, part) in [("requestFilePath", "request"), ("responseFilePath", "response")] {
                if let path = arguments[key] as? String, !path.isEmpty, let value = save[part] {
                    notes.append("The \(part) body was saved to \(try write(value, base64: save[part + "Base64"] == "1", to: path)).")
                }
            }
        case "lighthouse_audit":
            if let directory = arguments["outputDirPath"] as? String, !directory.isEmpty, let report = save["report"] {
                notes.append("Report saved to \(try write(report, to: (directory as NSString).appendingPathComponent("report.json"))).")
            }
        default:
            break
        }
        if let image = answer["image"] as? [String: Any], let data = image["data"] as? String {
            let mime = image["mimeType"] as? String ?? "image/png"
            if tool == "take_screenshot", let path = arguments["filePath"] as? String, !path.isEmpty {
                notes.append("Saved screenshot to \(try write(data, base64: true, to: path)).")
            } else {
                items.append(["type": "image", "data": data, "mimeType": mime])
            }
        }
        let full = ([body] + notes).filter { !$0.isEmpty }.joined(separator: "\n")
        items.insert(text(full.isEmpty ? "Done." : full), at: 0)
        return items
    }

    static func resolve(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
    }

    /// Files for upload_file, read here (the agent's folder) and sent to the
    /// app as base64, so relative paths mean what the agent meant.
    static let maxUploadBytes = 25_000_000

    static func readUploads(_ raw: Any?, cwd: String) throws -> [[String: Any]] {
        let paths = (raw as? [Any] ?? []).compactMap { $0 as? String }
        guard !paths.isEmpty else { throw BrowserControl.Failure(message: "Give at least one file path.") }
        var total = 0
        return try paths.map { raw in
            let path = resolve(raw, cwd: cwd)
            guard let data = FileManager.default.contents(atPath: path) else {
                throw BrowserControl.Failure(message: "Couldn't read \(path).")
            }
            total += data.count
            guard total <= maxUploadBytes else { throw BrowserControl.Failure(message: "The files come to more than 25 MB.") }
            return ["name": (path as NSString).lastPathComponent, "type": mimeType(of: path), "data": data.base64EncodedString()]
        }
    }

    static func mimeType(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "pdf": "application/pdf"
        case "json": "application/json"
        case "csv": "text/csv"
        case "txt", "md": "text/plain"
        case "html", "htm": "text/html"
        case "zip": "application/zip"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        default: "application/octet-stream"
        }
    }
}
