import Foundation

/// A corpus of command specs on disk, one file per command, loaded only when
/// that command is typed. The data comes from the MIT-licensed Fig
/// completion specs (withfig/autocomplete) via `SpecIngest`, normalised to
/// Octet's own shape; the licence and a notice sit beside it.
enum SpecCorpus {
    /// `~/Library/Application Support/Octet/completions`.
    static func directory(home: String = NSHomeDirectory()) -> String {
        "\(home)/Library/Application Support/Octet/completions"
    }

    static func indexPath(home: String = NSHomeDirectory()) -> String { directory(home: home) + "/index.json" }
    static func specPath(_ command: String, home: String = NSHomeDirectory()) -> String {
        directory(home: home) + "/specs/\(command).json"
    }

    struct Index: Codable, Equatable {
        var source: String
        var version: String
        var commands: [String]
        var ingestedAt: Date
    }

    static func index(home: String = NSHomeDirectory()) -> Index? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath(home: home))) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Index.self, from: data)
    }

    static func write(index: Index, home: String = NSHomeDirectory()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(atPath: directory(home: home), withIntermediateDirectories: true)
        try encoder.encode(index).write(to: URL(fileURLWithPath: indexPath(home: home)), options: .atomic)
    }

    /// The spec for a command, parsed from the ingested JSON.
    static func spec(for command: String, home: String = NSHomeDirectory()) -> CompletionSpec? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: specPath(command, home: home))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object)
    }

    // MARK: - Parsing Octet's normalised JSON

    static func parse(_ object: [String: Any]) -> CompletionSpec? {
        guard let name = object["name"] as? String else { return nil }
        return CompletionSpec(
            name: name,
            summary: object["description"] as? String ?? "",
            subcommands: (object["subcommands"] as? [[String: Any]] ?? []).compactMap(parseSubcommand),
            options: (object["options"] as? [[String: Any]] ?? []).compactMap(parseOption),
            argument: parseArgument(object["args"])
        )
    }

    private static func parseSubcommand(_ object: [String: Any]) -> CompletionSpec.Subcommand? {
        guard let name = object["name"] as? String else { return nil }
        return CompletionSpec.Subcommand(
            name: name,
            summary: object["description"] as? String ?? "",
            options: (object["options"] as? [[String: Any]] ?? []).compactMap(parseOption),
            argument: parseArgument(object["args"]),
            subcommands: (object["subcommands"] as? [[String: Any]] ?? []).compactMap(parseSubcommand)
        )
    }

    private static func parseOption(_ object: [String: Any]) -> CompletionSpec.Option? {
        let names = (object["names"] as? [String]) ?? (object["name"] as? String).map { [$0] } ?? []
        guard !names.isEmpty else { return nil }
        return CompletionSpec.Option(
            names: names,
            summary: object["description"] as? String ?? "",
            argument: parseArgument(object["args"])
        )
    }

    /// Fig describes argument values by template; Octet maps those onto its
    /// own sources, and named generators onto its cached ones.
    private static func parseArgument(_ raw: Any?) -> CompletionSpec.Argument? {
        guard let object = raw as? [String: Any] else { return nil }
        if let values = object["suggestions"] as? [String], !values.isEmpty {
            return .values(values)
        }
        if let generator = object["generator"] as? String {
            switch generator {
            case "branches": return .generator(CompletionSpecs.branches)
            case "npm-scripts": return .generator(CompletionSpecs.npm.subcommands.first { $0.name == "run" }?.argument.flatMap {
                if case .generator(let generator) = $0 { return generator } else { return nil }
            } ?? CompletionSpecs.branches)
            default: break
            }
        }
        switch object["template"] as? String {
        case "filepaths": return .file
        case "folders": return .directory
        default: return nil
        }
    }

    /// Specs Octet ships itself take priority: they carry Octet's generators.
    static func merged(for command: String, home: String = NSHomeDirectory()) -> CompletionSpec? {
        if let built = CompletionSpecs.spec(for: command) { return built }
        return spec(for: command, home: home)
    }
}
