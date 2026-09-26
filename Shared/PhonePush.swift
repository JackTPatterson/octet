import Foundation

/// An agent notice sent to your phone through ntfy (ntfy.sh or your own
/// server): install the ntfy app, subscribe to a topic, put the topic in
/// Settings. Only the agent, the tab and what happened are sent.
enum PhonePush {
    static func request(server: String, topic: String, event: AgentEvent, agentName: String) -> URLRequest? {
        let topic = topic.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty, topic.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let base = URL(string: server.trimmingCharacters(in: .whitespaces).isEmpty ? "https://ntfy.sh" : server),
              base.scheme == "https" || base.scheme == "http" else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(topic))
        request.httpMethod = "POST"
        request.httpBody = Data("\(agentName) \(event.kind.title) in \(event.label)".utf8)
        request.setValue(event.kind == .needsInput ? "\(agentName) needs you" : "\(agentName) finished", forHTTPHeaderField: "Title")
        request.setValue(event.kind == .needsInput ? "high" : "default", forHTTPHeaderField: "Priority")
        request.setValue(event.kind == .needsInput ? "raising_hand" : "white_check_mark", forHTTPHeaderField: "Tags")
        return request
    }
}
