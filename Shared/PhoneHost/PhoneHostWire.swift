import Foundation

/// Octet's projects, threads and transcripts as T3's orchestration schemas
/// encode them. Every shape here is checked against the real contract schemas
/// by `tools/host-conformance`.
enum PhoneHostWire {
    static func date(_ date: Date) -> String { PhoneHostRouter.date(date) }

    /// A slug the provider-instance schema accepts: a letter, then letters, digits, `_` or `-`.
    static func slug(_ text: String) -> String {
        var out = text.filter { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-" }
        if out.isEmpty || !(out.first!.isLetter) { out = "agent" + out }
        return String(out.prefix(64))
    }

    // MARK: - Projects and threads

    static func project(_ project: PhoneProject) -> [String: Any] {
        [
            "id": project.id, "title": nonEmpty(project.title, "Workspace"), "workspaceRoot": nonEmpty(project.folder, "/"),
            "defaultModelSelection": NSNull(), "scripts": [Any](),
            "createdAt": date(project.createdAt), "updatedAt": date(project.updatedAt),
        ]
    }

    private static func modelSelection(_ thread: PhoneThread) -> [String: Any] {
        ["instanceId": slug(thread.agent), "model": nonEmpty(thread.model ?? "", "default")]
    }

    private static func runID(_ messageID: String) -> String { "run-" + messageID }

    /// The runs a transcript implies: one per user message, the last one carrying the thread's status.
    private static func runs(_ items: [PhoneItem]) -> [(id: String, userMessageID: String, at: Date)] {
        items.compactMap { item in
            if case .user(let id, _, let at) = item { return (runID(id), id, at) }
            return nil
        }
    }

    static func runStatus(_ status: PhoneThreadStatus) -> String {
        switch status {
        case .idle, .completed: "completed"
        case .running: "running"
        case .waiting: "waiting"
        case .failed: "failed"
        }
    }

    private static func shellStatus(_ status: PhoneThreadStatus) -> String {
        switch status {
        case .idle: "idle"
        case .completed: "completed"
        case .running: "running"
        case .waiting: "waiting"
        case .failed: "failed"
        }
    }

    private static func latestMessage(_ items: [PhoneItem]) -> [String: Any]? {
        for item in items.reversed() {
            switch item {
            case .user(let id, let text, let at): return ["id": id, "role": "user", "text": text, "updatedAt": date(at)]
            case .assistant(let id, let text, let at): return ["id": id, "role": "assistant", "text": text, "updatedAt": date(at)]
            default: continue
            }
        }
        return nil
    }

    static func threadShell(_ thread: PhoneThread, items: [PhoneItem]) -> [String: Any] {
        let runs = runs(items)
        let live = thread.status == .running || thread.status == .waiting
        let lastUser = items.reversed().compactMap { item -> Date? in
            if case .user(_, _, let at) = item { return at }
            return nil
        }.first
        var shell: [String: Any] = [
            "createdBy": "user", "creationSource": "server",
            "id": thread.id, "projectId": thread.projectID, "title": nonEmpty(thread.title, "Agent"),
            "providerInstanceId": slug(thread.agent), "modelSelection": modelSelection(thread),
            "runtimeMode": "approval-required", "interactionMode": "default",
            "branch": NSNull(), "worktreePath": NSNull(),
            "lineage": ["parentThreadId": NSNull(), "relationshipToParent": NSNull(), "rootThreadId": thread.id],
            "forkedFrom": NSNull(), "activeProviderThreadId": NSNull(),
            "latestRunId": runs.last.map { $0.id } ?? NSNull(),
            "activeRunId": live ? (runs.last.map { $0.id } ?? NSNull()) : NSNull(),
            "status": shellStatus(thread.status),
            "pendingRuntimeRequest": NSNull(),
            "latestVisibleMessage": latestMessage(items) ?? NSNull(),
            "latestUserMessageAt": lastUser.map(date) ?? NSNull(),
            "hasActionableProposedPlan": false,
            "itemCount": items.count, "visibleItemCount": items.count,
            "createdAt": date(thread.createdAt), "updatedAt": date(thread.updatedAt),
            "archivedAt": NSNull(), "settledOverride": NSNull(), "settledAt": NSNull(), "deletedAt": NSNull(),
        ]
        if let approval = thread.approval {
            shell["pendingRuntimeRequest"] = ["id": approval.id, "kind": approval.kind, "createdAt": date(approval.createdAt), "blocking": true] as [String: Any]
        }
        return shell
    }

    static func shellSnapshot(projects: [PhoneProject], threads: [(PhoneThread, [PhoneItem])], sequence: Int) -> [String: Any] {
        [
            "schemaVersion": 1, "snapshotSequence": sequence,
            "threads": threads.map { threadShell($0.0, items: $0.1) }, "archivedThreads": [Any](),
            "projects": projects.map(project),
        ]
    }

    // MARK: - A thread's projection

    private static func base(_ id: String, _ ordinal: Int, run: String?, at: Date, status: String = "completed") -> [String: Any] {
        [
            "id": id, "threadId": "", "runId": run.map { $0 as Any } ?? NSNull(), "nodeId": NSNull(), "providerThreadId": NSNull(),
            "providerTurnId": NSNull(), "nativeItemRef": NSNull(), "parentItemId": NSNull(), "ordinal": ordinal,
            "status": status, "title": NSNull(), "startedAt": date(at), "completedAt": status == "completed" ? date(at) : NSNull(),
            "updatedAt": date(at),
        ]
    }

    static func projection(_ thread: PhoneThread, items: [PhoneItem]) -> [String: Any] {
        let model = modelSelection(thread)
        var appThread = threadShell(thread, items: items)
        for key in ["latestRunId", "activeRunId", "status", "pendingRuntimeRequest", "latestVisibleMessage", "latestUserMessageAt",
                    "hasActionableProposedPlan", "itemCount", "visibleItemCount"] { appThread[key] = nil }

        let runList = runs(items)
        var runDicts: [[String: Any]] = []
        for (index, run) in runList.enumerated() {
            let last = index == runList.count - 1
            runDicts.append([
                "id": run.id, "threadId": thread.id, "ordinal": index + 1, "providerInstanceId": slug(thread.agent),
                "modelSelection": model, "providerThreadId": NSNull(), "userMessageId": run.userMessageID, "rootNodeId": NSNull(),
                "activeAttemptId": NSNull(), "status": last ? runStatus(thread.status) : "completed",
                "requestedAt": date(run.at), "startedAt": date(run.at),
                "completedAt": last && (thread.status == .running || thread.status == .waiting) ? NSNull() : date(thread.updatedAt),
                "checkpointId": NSNull(), "contextHandoffId": NSNull(),
            ])
        }

        var messages: [[String: Any]] = []
        var turnItems: [[String: Any]] = []
        var currentRun: String?
        let live = thread.status == .running || thread.status == .waiting
        for (ordinal, item) in items.enumerated() {
            let isLast = ordinal == items.count - 1
            var turnItem: [String: Any]
            switch item {
            case .user(let id, let text, let at):
                currentRun = runID(id)
                messages.append(["createdBy": "user", "creationSource": "mobile", "id": id, "threadId": thread.id, "runId": currentRun!,
                                 "nodeId": NSNull(), "role": "user", "text": text, "attachments": [Any](), "streaming": false,
                                 "createdAt": date(at), "updatedAt": date(at)])
                turnItem = base("item-" + id, ordinal, run: currentRun, at: at)
                turnItem.merge(["createdBy": "user", "creationSource": "mobile", "type": "user_message", "messageId": id,
                                "inputIntent": "turn_start", "text": text, "attachments": [Any]()]) { $1 }
            case .assistant(let id, let text, let at):
                let streaming = live && isLast
                messages.append(["createdBy": "agent", "creationSource": "provider", "id": id, "threadId": thread.id,
                                 "runId": currentRun.map { $0 as Any } ?? NSNull(), "nodeId": NSNull(), "role": "assistant", "text": text,
                                 "attachments": [Any](), "streaming": streaming, "createdAt": date(at), "updatedAt": date(at)])
                turnItem = base("item-" + id, ordinal, run: currentRun, at: at, status: streaming ? "running" : "completed")
                turnItem.merge(["type": "assistant_message", "messageId": id, "text": text, "streaming": streaming]) { $1 }
            case .reasoning(let id, let text, let at):
                turnItem = base("item-" + id, ordinal, run: currentRun, at: at)
                turnItem.merge(["type": "reasoning", "text": text, "streaming": false]) { $1 }
            case .tool(let id, let name, let input, let output, let failed, let at):
                let done = output != nil
                turnItem = base("item-" + id, ordinal, run: currentRun, at: at,
                                status: done ? (failed ? "failed" : "completed") : "running")
                turnItem["title"] = name
                turnItem.merge(["type": "command_execution", "input": input, "outputIndicatesFailure": failed]) { $1 }
                if let output { turnItem["output"] = output }
            }
            turnItem["threadId"] = thread.id
            turnItems.append(turnItem)
        }

        var runtimeRequests: [[String: Any]] = []
        if let approval = thread.approval {
            let ordinal = turnItems.count
            var request = base("item-" + approval.id, ordinal, run: currentRun, at: approval.createdAt, status: "waiting")
            request["threadId"] = thread.id
            request.merge(["type": "approval_request", "requestId": approval.id, "requestKind": approval.kind, "prompt": approval.prompt]) { $1 }
            turnItems.append(request)
            runtimeRequests.append([
                "id": approval.id, "nodeId": "node-" + approval.id, "providerTurnId": NSNull(), "nativeRequestRef": NSNull(),
                "kind": approval.kind, "status": "pending",
                "responseCapability": ["type": "live", "providerSessionId": "session-" + thread.id] as [String: Any],
                "createdAt": date(approval.createdAt), "resolvedAt": NSNull(),
            ])
        }

        let visible: [[String: Any]] = turnItems.enumerated().map { position, item in
            ["position": position, "visibility": "local", "sourceThreadId": thread.id, "sourceItemId": item["id"] as Any, "item": item]
        }
        return [
            "thread": appThread, "runs": runDicts, "attempts": [Any](), "nodes": [Any](), "subagents": [Any](),
            "providerSessions": [Any](), "providerThreads": [Any](), "providerTurns": [Any](), "runtimeRequests": runtimeRequests,
            "messages": messages, "plans": [Any](), "turnItems": turnItems, "checkpointScopes": [Any](), "checkpoints": [Any](),
            "contextHandoffs": [Any](), "contextTransfers": [Any](), "visibleTurnItems": visible,
            "updatedAt": date(thread.updatedAt),
        ]
    }

    // MARK: - Server config

    static func environment(_ config: PhoneHostConfig, router: PhoneHostRouter) -> [String: Any] { router.descriptor() }

    static func serverConfig(router: PhoneHostRouter, backend: PhoneHostBackend) -> [String: Any] {
        let home = backend.homeFolder
        return [
            "environment": router.descriptor(),
            "auth": router.authDescriptor,
            "cwd": nonEmpty(home, "/"),
            "keybindingsConfigPath": home + "/.octet/keybindings.json",
            "keybindings": [Any](), "issues": [Any](), "providers": backend.providers().map(provider), "availableEditors": [Any](),
            "observability": ["logsDirectoryPath": NSTemporaryDirectory(), "localTracingEnabled": false,
                              "otlpTracesEnabled": false, "otlpMetricsEnabled": false] as [String: Any],
            "settings": PhoneHostSettingsFixture.object,
        ]
    }

    static func provider(_ provider: PhoneProvider) -> [String: Any] {
        [
            "instanceId": slug(provider.id), "driver": slug(provider.id), "displayName": nonEmpty(provider.name, provider.id),
            "enabled": true, "installed": true, "version": NSNull(), "status": "ready", "auth": ["status": "unknown"],
            "checkedAt": date(Date()),
            "models": provider.models.map { model -> [String: Any] in
                ["slug": model.id, "name": nonEmpty(model.name, model.id), "isCustom": false, "isDefault": model.isDefault,
                 "capabilities": NSNull()]
            },
            "slashCommands": [Any](), "skills": [Any](),
        ]
    }

    private static func nonEmpty(_ text: String, _ fallback: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
    }
}
