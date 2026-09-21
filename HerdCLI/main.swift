import Foundation

// herd-cli: helpers that run inside session server panes.
//
//   herd-cli hook <agent>              subagent hook for that agent (stdin JSON)
//   herd-cli agent-watch …             live subagent transcript viewer
//   herd-cli install-subagent-hook …   add the hook to an agent's config
//   herd-cli uninstall-subagent-hook … remove it
//   herd-cli mcp-permission --socket <path>
//                                      permission prompt tool for conversations
//                                      Herd drives headless (stdio MCP server)
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
    guard let agent = arguments.dropFirst().first, !agent.isEmpty else { fail("usage: herd-cli hook <agent>") }
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
        fail("usage: herd-cli agent-watch --dir <session>/subagents [--tool-use-id <id>] [--description <text>] [--title <text>]")
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
            print(changed ? "Installed Herd subagent hook in \(spec.file)" : "Already installed in \(spec.file)")
        } catch {
            fail("install failed for \(spec.hostId): \(error)")
        }
    }

case "uninstall-subagent-hook", "uninstall-claude-hook":
    let specs = hookSpecs(arguments.dropFirst().first)
    for spec in specs {
        do {
            let changed = try SubagentHookInstaller.uninstall(spec: spec)
            print(changed ? "Removed Herd subagent hook from \(spec.file)" : "Not installed in \(spec.file)")
        } catch {
            fail("uninstall failed for \(spec.hostId): \(error)")
        }
    }

case "mcp-permission":
    guard let socketPath = option("--socket", in: Array(arguments.dropFirst())) else {
        fail("usage: herd-cli mcp-permission --socket <path>")
    }
    while let line = readLine() {
        if let reply = PermissionMCP.respond(to: line, ask: { PermissionMCP.askApp(socketPath: socketPath, arguments: $0) }) {
            print(reply)
        }
    }

default:
    fail("usage: herd-cli <hook <agent>|agent-watch|install-subagent-hook [agent]|uninstall-subagent-hook [agent]|mcp-permission --socket <path>>")
}
