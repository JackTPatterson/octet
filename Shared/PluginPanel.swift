import Foundation

/// What a plugin's panel command prints: the button's badge, and the rows
/// and actions the panel shows.
///
///     { "badge": "2/3", "tone": "warning",
///       "rows": [{ "id": "web", "title": "web", "detail": "Up 3 min · :8080",
///                  "tone": "success", "url": "http://localhost:8080",
///                  "actions": [{ "id": "stop", "title": "Stop", "symbol": "stop.fill" }] }],
///       "actions": [{ "id": "up", "title": "Start All" }] }
///
/// An action runs the panel's `act` command with OCTET_ACTION set to its id,
/// and OCTET_ITEM to its row's id for a row's action. Printing nothing, or
/// something that isn't a panel, hides the button.
struct PluginPanel: Codable, Equatable {
    var badge: String?
    var tone: Tone?
    /// Shown when there are no rows.
    var message: String?
    var rows: [Row] = []
    var actions: [Action] = []

    enum Tone: String, Codable {
        case normal, muted, success, warning, danger
    }

    struct Row: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        var detail: String?
        var tone: Tone?
        /// Opened when the row is clicked; http and https only.
        var url: String?
        var actions: [Action] = []

        init(id: String, title: String, detail: String? = nil, tone: Tone? = nil, url: String? = nil, actions: [Action] = []) {
            self.id = id
            self.title = title
            self.detail = detail
            self.tone = tone
            self.url = url
            self.actions = actions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
            tone = try? c.decodeIfPresent(Tone.self, forKey: .tone)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
        }

        var link: URL? {
            url.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        }
    }

    struct Action: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        var symbol: String?
        /// Asks before running, with this question.
        var confirm: String?
    }

    init(badge: String? = nil, tone: Tone? = nil, message: String? = nil, rows: [Row] = [], actions: [Action] = []) {
        self.badge = badge
        self.tone = tone
        self.message = message
        self.rows = rows
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        // An unknown tone from a newer plugin reads as none, not a failure.
        tone = try? c.decodeIfPresent(Tone.self, forKey: .tone)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        rows = try c.decodeIfPresent([Row].self, forKey: .rows) ?? []
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
    }

    /// The panel in `output`, or nil to hide the button.
    static func parse(_ output: String) -> PluginPanel? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PluginPanel.self, from: data)
    }
}
