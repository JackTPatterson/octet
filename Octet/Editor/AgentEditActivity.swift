import AppKit
import Combine

/// Watches the agents' conversations for the edits they make to files, so
/// the editor beside a conversation can show them as they happen: a cursor
/// at the place an edit is about to land, and the file refreshed the moment
/// the edit has landed rather than on the next poll.
@MainActor
final class AgentEditActivity: ObservableObject {
    static let shared = AgentEditActivity()

    /// Who is editing, for the cursor's label and colour.
    struct Writer: Equatable {
        var name: String
        var brandId: String?
        var hueHex: String?
    }

    /// An edit the agent has started and not finished.
    struct Pending: Equatable {
        var path: String
        var writer: Writer
        var tool: String
        /// The text it is about to replace, to put the cursor where it lands.
        var oldString: String?
    }

    /// What one tool call in a conversation says about a file.
    struct Call: Equatable {
        var itemId: String
        var path: String
        var tool: String
        var oldString: String?
        var finished: Bool
        var failed: Bool
    }

    /// The edits in flight, by file path.
    @Published private(set) var pending: [String: Pending] = [:]

    /// An edit finished: the file on disk has changed.
    let landed = PassthroughSubject<(path: String, writer: Writer), Never>()

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    private var sessionWatches: [String: AnyCancellable] = [:]
    private var centerWatch: AnyCancellable?
    private var landedWatch: AnyCancellable?
    /// Calls already reported as landed, so each is reported once; and the
    /// sessions whose existing history has been taken as the starting point.
    private var reported: Set<String> = []
    private var baselined: Set<String> = []
    private var recent: [String: (writer: Writer, at: Date)] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        centerWatch = AgentCenter.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in self?.watch(sessions) }
        // An edit that has landed refreshes its file at once.
        landedWatch = landed.sink { event in
            EditorBufferRegistry.shared.existing(atPath: event.path)?.refreshFromDisk(writer: event.writer)
        }
    }

    #if DEBUG
    /// Verification hook: an edit in flight, then landed, without an agent.
    func debugSetPending(_ pending: Pending?) {
        if let pending { self.pending[pending.path] = pending } else { self.pending = [:] }
    }

    func debugLand(path: String, writer: Writer) {
        landed.send((path, writer))
    }
    #endif

    private func watch(_ sessions: [AgentSession]) {
        let ids = Set(sessions.map(\.id))
        for id in sessionWatches.keys where !ids.contains(id) { sessionWatches[id] = nil }
        for session in sessions where sessionWatches[session.id] == nil {
            scan(session)
            sessionWatches[session.id] = session.objectWillChange
                .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self, weak session] _ in
                    guard let self, let session else { return }
                    self.scan(session)
                }
        }
    }

    // MARK: Reading a conversation

    /// The file edits among `items`, newest last.
    static func calls(in items: some Sequence<AgentItem>) -> [Call] {
        items.compactMap { item in
            guard case .tool(let call) = item.kind, editTools.contains(call.name), let raw = call.filePath else { return nil }
            let input = call.inputObject
            var old = input?["old_string"] as? String
            if old == nil, let edits = input?["edits"] as? [[String: Any]] { old = edits.first?["old_string"] as? String }
            return Call(itemId: item.id, path: canonical(raw), tool: call.name, oldString: old,
                        finished: call.result != nil, failed: call.isError)
        }
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func scan(_ session: AgentSession) {
        let writer = Self.writer(of: session)
        let calls = Self.calls(in: session.conversation.items.suffix(40))
        // What was already there when the session was first seen isn't news.
        if baselined.insert(session.id).inserted {
            for call in calls where call.finished { reported.insert(call.itemId) }
        }
        var inFlight: [String: Pending] = [:]
        for call in calls {
            if !call.finished {
                guard session.conversation.isRunning else { continue }
                inFlight[call.path] = Pending(path: call.path, writer: writer, tool: call.tool, oldString: call.oldString)
            } else if !call.failed, reported.insert(call.itemId).inserted {
                recent[call.path] = (writer, Date())
                landed.send((call.path, writer))
            }
        }
        // This session's edits in flight replace what it had before; other
        // sessions' stay.
        var merged = pending.filter { $0.value.writer != writer }
        merged.merge(inFlight) { _, new in new }
        if merged != pending { pending = merged }
    }

    static func writer(of session: AgentSession) -> Writer {
        let brand = AgentBrand.forAgent(session.engine.agent)
        return Writer(name: brand?.displayName ?? session.engine.displayName, brandId: session.engine.agent, hueHex: brand?.hueHex)
    }

    /// Who most likely changed `path`: the agent whose edit landed in the
    /// last few seconds, else one working in a folder that holds it.
    func writer(for path: String) -> Writer? {
        if let hit = recent[path], Date().timeIntervalSince(hit.at) < 20 { return hit.writer }
        let working = AgentCenter.shared.sessions.first { $0.conversation.isRunning && path.hasPrefix($0.cwd) }
        return working.map(Self.writer(of:))
    }
}
