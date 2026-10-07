import Foundation

/// Whether the last thing an agent changed was ever checked: the evidence
/// next to "I've fixed it". Read off a conversation's tool calls, in order:
/// the files edited, and whether a test run (or at least a build or lint)
/// came after the last edit.
enum Verification: Equatable {
    /// Nothing was edited.
    case noEdits
    /// A test run finished after the last edit, and it passed or didn't.
    case tested(passed: Bool)
    /// A build, type check or lint ran after the last edit, but no tests.
    case checked(passed: Bool)
    /// Nothing ran after the last edit (`edits` of them since the last check).
    case unchecked(edits: Int)

    /// What a person should be told, or nil when there is nothing to say.
    var message: String? {
        switch self {
        case .noEdits: nil
        case .tested(let passed): passed ? "Tests passed after the last edit" : "Tests failed after the last edit"
        case .checked(let passed): passed ? "Built or linted after the last edit, no tests" : "The build or lint failed after the last edit"
        case .unchecked(let edits): edits == 1 ? "No tests since the last edit" : "No tests since the last \(edits) edits"
        }
    }

    /// Worth drawing the eye to: unchecked, or checked and failed.
    var needsLook: Bool {
        switch self {
        case .noEdits: false
        case .tested(let passed): !passed
        case .checked: true
        case .unchecked: true
        }
    }

    enum Check: Equatable { case test, build }

    /// The verdict for `items`, in order.
    static func assess(_ items: [AgentItem]) -> Verification {
        var lastEdit: Int?
        var editsSinceCheck = 0
        var edits = 0
        // After the last edit: the most telling check that finished.
        var test: Bool?
        var build: Bool?
        for (index, item) in items.enumerated() {
            guard case .tool(let call) = item.kind else { continue }
            if !Recap.editedPaths(call).isEmpty {
                lastEdit = index
                edits += 1
                editsSinceCheck += 1
                test = nil
                build = nil
                continue
            }
            guard lastEdit != nil, Recap.isCommand(call.name), call.result != nil || call.isError else { continue }
            let command = (call.inputObject?["command"] as? String) ?? call.summary
            switch check(command) {
            case .test:
                test = !call.isError
                editsSinceCheck = 0
            case .build:
                build = !call.isError
                editsSinceCheck = 0
            case nil: break
            }
        }
        guard edits > 0 else { return .noEdits }
        if let test { return .tested(passed: test) }
        if let build { return .checked(passed: build) }
        return .unchecked(edits: editsSinceCheck)
    }

    // MARK: - Recognising a command

    /// Whether a shell command runs tests, or builds or lints. A compound
    /// command counts when any part of it does; tests win over builds.
    static func check(_ command: String) -> Check? {
        let lowered = command.lowercased()
        if testPatterns.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }) { return .test }
        if buildPatterns.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }) { return .build }
        return nil
    }

    private static let testPatterns = [
        #"\b(swift|cargo|go|dotnet|mix|deno|bun|flutter|dart|zig)\s+test\b"#,
        #"\bcargo\s+nextest\b"#,
        #"\bxcodebuild\b.*\btest\b"#,
        #"\b(npm|pnpm|yarn|bun)\s+(run\s+)?test[\w:-]*"#,
        #"\bnpx\s+(jest|vitest|mocha|playwright\s+test)\b"#,
        #"\b(jest|vitest|mocha|pytest|rspec|phpunit|tox|nosetests|ctest|karma)\b"#,
        #"\bpython3?\s+-m\s+(pytest|unittest)\b"#,
        #"\b(make|rake)\s+(test|tests|check)\b"#,
        #"\b(mvn|gradle|gradlew|\./gradlew)\b.*\btest\b"#,
        #"\bnode\s+--test\b"#,
        #"\bbundle\s+exec\s+rspec\b"#,
    ]

    private static let buildPatterns = [
        #"\b(swift|cargo|go|zig|dotnet)\s+(build|check|vet)\b"#,
        #"\bcargo\s+clippy\b"#,
        #"\bxcodebuild\b"#,
        #"\btsc\b"#,
        #"\b(npm|pnpm|yarn|bun)\s+(run\s+)?(build|lint|typecheck|type-check|check)[\w:-]*"#,
        #"\b(eslint|ruff|mypy|pyright|flake8|swiftlint|biome|shellcheck|golangci-lint)\b"#,
        #"\b(mvn|gradle|gradlew|\./gradlew)\b.*\b(build|compile\w*|check)\b"#,
        #"\bmake\b(\s+all)?\s*$"#,
    ]
}
