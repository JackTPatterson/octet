import Foundation

// octet-cli: helpers that run inside session server panes.
//
//   octet-cli hook <agent>              subagent hook for that agent (stdin JSON)
//   octet-cli agent-watch …             live subagent transcript viewer
//   octet-cli install-subagent-hook …   add the hook to an agent's config
//   octet-cli uninstall-subagent-hook … remove it
//   octet-cli open [folder]             a workspace on a folder (default: here)
//   octet-cli run <agent> [--in <folder>] [--prompt <text>]
//                                      an agent in a new tab
//   octet-cli send <text>               type and run it in the pane in front (asks)
//   octet-cli panes                     every pane: id, agent, status, folder
//   octet-cli read [--pane <id>] [--lines <n>]
//                                      a pane's screen as text (default: the
//                                      pane in front); --lines reads that many
//                                      lines back through its scrollback
//   octet-cli mcp-permission --socket <path>
//                                      permission prompt tool for conversations
//                                      Octet drives headless (stdio MCP server)
//
// <agent> is an agent id, e.g. claude or codex; omitting it means every
// agent installed on this machine.

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// One agent's hook config, or every installed agent's when unnamed.
func hookSpecs(_ agent: String?) -> [SubagentHookSpec] {
    guard let agent, !agent.isEmpty else { return SubagentHookInstaller.available() }
    guard let spec = SubagentHookInstaller.spec(agent) else { fail("unknown agent: \(agent)") }
    return [spec]
}

var executablePath: String {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

switch arguments.first {
case "hook":
    guard let agent = arguments.dropFirst().first, !agent.isEmpty else { fail("usage: octet-cli hook <agent>") }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    SubagentHook.handlePreToolUse(
        payload: input,
        environment: environment,
        cliPath: executablePath
    )
    exit(0)

case "agent-watch":
    let args = Array(arguments.dropFirst())
    guard let directory = option("--dir", in: args) else {
        fail("usage: octet-cli agent-watch --dir <session>/subagents [--tool-use-id <id>] [--description <text>] [--title <text>]")
    }
    SubagentWatch.run(
        directory: directory,
        toolUseId: option("--tool-use-id", in: args),
        description: option("--description", in: args),
        since: option("--since", in: args).flatMap(TimeInterval.init) ?? 0,
        title: option("--title", in: args) ?? "Subagent",
        environment: environment
    )

case "install-subagent-hook", "install-claude-hook":
    let specs = hookSpecs(arguments.dropFirst().first)
    guard !specs.isEmpty else { fail("no agent config found to install into") }
    for spec in specs {
        do {
            let changed = try SubagentHookInstaller.install(cliPath: executablePath, spec: spec)
            print(changed ? "Installed Octet subagent hook in \(spec.file)" : "Already installed in \(spec.file)")
        } catch {
            fail("install failed for \(spec.hostId): \(error)")
        }
    }

case "uninstall-subagent-hook", "uninstall-claude-hook":
    let specs = hookSpecs(arguments.dropFirst().first)
    for spec in specs {
        do {
            let changed = try SubagentHookInstaller.uninstall(spec: spec)
            print(changed ? "Removed Octet subagent hook from \(spec.file)" : "Not installed in \(spec.file)")
        } catch {
            fail("uninstall failed for \(spec.hostId): \(error)")
        }
    }

case "open", "run", "send":
    let command: OctetURL
    switch arguments[0] {
    case "open":
        let folder = arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        command = .open(path: URL(fileURLWithPath: folder).standardizedFileURL.path)
    case "run":
        guard let agent = arguments.dropFirst().first, !agent.hasPrefix("--") else {
            fail("usage: octet-cli run <agent> [--in <folder>] [--prompt <text>]")
        }
        let folder = option("--in", in: arguments) ?? FileManager.default.currentDirectoryPath
        command = .run(agent: agent, path: URL(fileURLWithPath: folder).standardizedFileURL.path,
                       prompt: option("--prompt", in: arguments))
    default:
        let text = arguments.dropFirst().joined(separator: " ")
        guard !text.isEmpty else { fail("usage: octet-cli send <text>") }
        command = .send(text: text)
    }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [command.url.absoluteString]
    try? open.run()
    open.waitUntilExit()
    exit(open.terminationStatus)
case "panes", "read":
    // Inside a pane the session server says where it is; elsewhere, Octet's
    // session (or OCTET_SESSION's).
    let socket = option("--socket", in: arguments) ?? environment[EngineProtocol.socketPathVariable]
        ?? EngineClient.socketPath(session: option("--session", in: arguments) ?? environment["OCTET_SESSION"] ?? "octet")
    let client = EngineClient(socketPath: socket)
    do {
        let snapshot = try client.call("session.snapshot")["snapshot"] as? [String: Any] ?? [:]
        if arguments[0] == "panes" {
            print(PaneListing.lines(snapshot: snapshot).joined(separator: "\n"))
            exit(0)
        }
        guard let pane = option("--pane", in: arguments) ?? snapshot["focused_pane_id"] as? String else {
            fail("No pane in front; name one with --pane (see octet-cli panes).")
        }
        var params: [String: Any] = ["pane_id": pane, "source": "visible"]
        if let lines = option("--lines", in: arguments).flatMap(Int.init), lines > 0 {
            params["source"] = "recent"
            params["lines"] = lines
        }
        let read = try client.call("pane.read", params)["read"] as? [String: Any]
        print(PaneListing.trimmed(read?["text"] as? String ?? ""))
        exit(0)
    } catch EngineSocketError.server(_, let message) {
        fail(message.isEmpty ? "The session refused that." : message)
    } catch {
        fail("Couldn't reach Octet's session at \(socket): \(error)")
    }
case "mcp-permission":
    guard let socketPath = option("--socket", in: Array(arguments.dropFirst())) else {
        fail("usage: octet-cli mcp-permission --socket <path>")
    }
    while let line = readLine() {
        if let reply = PermissionMCP.respond(to: line, ask: { PermissionMCP.askApp(socketPath: socketPath, arguments: $0) }) {
            print(reply)
        }
    }

default:
    fail("usage: octet-cli <open [folder]|run <agent> [--in <folder>] [--prompt <text>]|send <text>|panes|read [--pane <id>] [--lines <n>]|hook <agent>|agent-watch|install-subagent-hook [agent]|uninstall-subagent-hook [agent]|mcp-permission --socket <path>>")
}
