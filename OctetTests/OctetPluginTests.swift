import XCTest

final class OctetPluginTests: XCTestCase {
    /// The GitHub plugin as it ships, read from the repository.
    private func bundledGitHubPlugin() throws -> OctetPlugin {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Plugins").path
        let found = OctetPlugins.discover(bundled: root, user: "/nonexistent")
        XCTAssertEqual(found.problems, [])
        return try XCTUnwrap(found.plugins.first { $0.id == "github-repos" })
    }

    func testBundledGitHubPluginCompletesGitClone() throws {
        let plugin = try bundledGitHubPlugin()
        XCTAssertTrue(plugin.isBundled)
        let spec = try XCTUnwrap(OctetPlugins.applying(
            plugin.manifest.contributes.completions.map { ($0, plugin) }, to: CompletionSpecs.git, command: "git"))
        let generator = try XCTUnwrap(Completions.generator(for: spec, words: ["clone"]))
        XCTAssertEqual(generator.kind, .repository)
        XCTAssertFalse(generator.perFolder)
        XCTAssertTrue(generator.command.contains("OCTET_PLUGIN_DIR='\(plugin.directory)'"))
        // The spec's own clone options survive the plugin adding values.
        XCTAssertTrue(spec.candidates(after: ["clone"]).names.contains { $0.value == "--depth" })
        // Commands the plugin doesn't touch are left alone.
        XCTAssertEqual(OctetPlugins.applying([], to: CompletionSpecs.git, command: "git"), CompletionSpecs.git)
    }

    func testMenuOpensByItselfOnlyWhereAPluginAsks() throws {
        let completions = try bundledGitHubPlugin().manifest.contributes.completions
        XCTAssertTrue(OctetPlugins.opensMenu("git clone ", contributions: completions))
        XCTAssertTrue(OctetPlugins.opensMenu("  git   clone  ", contributions: completions))
        XCTAssertFalse(OctetPlugins.opensMenu("git clone", contributions: completions))
        XCTAssertFalse(OctetPlugins.opensMenu("git clone https://x ", contributions: completions))
        XCTAssertFalse(OctetPlugins.opensMenu("git commit ", contributions: completions))
        XCTAssertFalse(OctetPlugins.opensMenu("git clone ", contributions: []))
    }

    func testRepositoriesShowByNameAndInsertTheirURL() {
        let context = CompletionContext.at(caret: 10, in: "git clone ")
        let generator = CompletionSpec.Generator(id: "t", command: "true", kind: .repository)
        var spec = CompletionSpecs.git
        spec.subcommands = spec.subcommands.map { var sub = $0; if sub.name == "clone" { sub.argument = .generator(generator) }; return sub }
        let values = ["https://github.com/acme/zeta.git\tacme/zeta\tprivate", "https://github.com/acme/a.git\tacme/a\t"]
        let repos = Completions.suggestions(for: context, spec: spec, generatorValues: values).filter { $0.kind == .repository }
        XCTAssertEqual(repos.map(\.shown), ["acme/zeta", "acme/a"])
        XCTAssertEqual(repos.first?.value, "https://github.com/acme/zeta.git")
        XCTAssertEqual(repos.first?.detail, "private")
        let typed = CompletionContext.at(caret: 13, in: "git clone zet")
        XCTAssertEqual(Completions.suggestions(for: typed, spec: spec, generatorValues: values)
            .filter { $0.kind == .repository }.map(\.shown), ["acme/zeta"])
    }

    func testDiscoveryReportsBrokenPluginsAndLetsUserOnesOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ folder: String, _ json: String, in base: String) throws {
            let dir = root.appendingPathComponent(base).appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        }
        try write("a", #"{"id":"a","name":"Bundled A","version":"1.0.0"}"#, in: "bundled")
        try write("a", #"{"id":"a","name":"Mine A","version":"2.0.0"}"#, in: "user")
        try write("bad-id", #"{"id":"Bad Id","name":"X"}"#, in: "user")
        try write("future", #"{"id":"future","name":"F","octet":99}"#, in: "user")
        try write("broken", "{", in: "user")
        try write("no-run", #"{"id":"nr","name":"N","contributes":{"completions":[{"command":"git","run":" "}]}}"#, in: "user")
        let found = OctetPlugins.discover(bundled: root.appendingPathComponent("bundled").path,
                                          user: root.appendingPathComponent("user").path)
        XCTAssertEqual(found.plugins.map(\.manifest.name), ["Mine A"])
        XCTAssertEqual(found.plugins.first?.isBundled, false)
        XCTAssertEqual(found.problems.count, 4)
    }

    func testPluginCanAddASubcommandAndATopLevelArgument() {
        let plugin = OctetPlugin(manifest: .init(id: "p", name: "P"), directory: "/tmp/p", isBundled: false)
        let sub = OctetPluginManifest.CompletionContribution(command: "deploy", path: ["to"], summary: "Deploy target", run: "echo prod")
        let top = OctetPluginManifest.CompletionContribution(command: "ssh", run: "echo host")
        let deploy = OctetPlugins.applying([(sub, plugin)], to: nil, command: "deploy")
        XCTAssertEqual(deploy?.subcommands.first?.name, "to")
        XCTAssertEqual(deploy?.subcommands.first?.summary, "Deploy target")
        XCTAssertNotNil(deploy.flatMap { Completions.generator(for: $0, words: ["to"]) })
        let ssh = OctetPlugins.applying([(top, plugin)], to: nil, command: "ssh")
        XCTAssertNotNil(ssh.flatMap { Completions.generator(for: $0, words: []) })
    }
}

final class RuntimeIconTests: XCTestCase {
    private func matcher() throws -> RuntimeMatcher {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Plugins").path
        let found = OctetPlugins.discover(bundled: root, user: "/nonexistent")
        XCTAssertEqual(found.problems, [])
        let plugin = try XCTUnwrap(found.plugins.first { $0.id == "dev-runtimes" })
        for runtime in plugin.manifest.contributes.runtimes {
            XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.directory + "/" + runtime.icon), runtime.id)
        }
        return RuntimeMatcher(plugins: [plugin])
    }

    private func id(_ matcher: RuntimeMatcher, _ arguments: [String], dependencies: Set<String> = []) -> String? {
        matcher.match(commands: arguments.map(RuntimeMatcher.words), dependencies: { dependencies })?.id
    }

    func testPathsShortenToTheirLastComponent() {
        XCTAssertEqual(RuntimeMatcher.words("/usr/local/bin/node /app/node_modules/.bin/vite --port 3000"),
                       "node vite --port 3000")
    }

    func testFrameworksWinOverTheRuntimeUnderThem() throws {
        let m = try matcher()
        XCTAssertEqual(id(m, ["npm run dev", "sh -c next dev", "/opt/node/bin/node /app/node_modules/.bin/next dev"]), "next")
        XCTAssertEqual(id(m, ["next-server (v15.1.0)"]), "next")
        XCTAssertEqual(id(m, ["node /app/node_modules/.bin/expo start --ios"]), "expo")
        XCTAssertEqual(id(m, ["node /app/node_modules/react-scripts/bin/react-scripts.js start"]), "node")
        XCTAssertEqual(id(m, ["sh -c react-scripts start"]), "react")
        XCTAssertEqual(id(m, ["/Library/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python manage.py runserver"]), "django")
        XCTAssertEqual(id(m, ["/app/.venv/bin/python -m uvicorn app.main:app --reload"]), "fastapi")
        XCTAssertEqual(id(m, ["bundle exec rails server"]), "rails")
    }

    func testViteTakesTheProjectsFramework() throws {
        let m = try matcher()
        let vite = ["node /app/node_modules/.bin/vite"]
        XCTAssertEqual(id(m, vite), "vite")
        XCTAssertEqual(id(m, vite, dependencies: ["@sveltejs/kit", "svelte"]), "sveltekit")
        XCTAssertEqual(id(m, vite, dependencies: ["svelte"]), "svelte")
        XCTAssertEqual(id(m, vite, dependencies: ["react", "react-dom"]), "react")
        XCTAssertEqual(id(m, vite, dependencies: ["vue"]), "vue")
    }

    func testLanguages() throws {
        let m = try matcher()
        XCTAssertEqual(id(m, ["python3.12 train.py"]), "python")
        XCTAssertEqual(id(m, ["cargo run --release", "/app/target/release/server"]), "rust")
        XCTAssertEqual(id(m, ["go run ./cmd/api"]), "go")
        XCTAssertEqual(id(m, ["node /app/node_modules/.bin/tsx watch src/index.ts"]), "typescript")
        XCTAssertEqual(id(m, ["tsx watch src/index.ts"]), "typescript")
        XCTAssertEqual(id(m, ["node server.js"]), "node")
        XCTAssertEqual(id(m, ["bun run index.ts"]), "bun")
        XCTAssertEqual(id(m, ["ruby script.rb"]), "ruby")
        XCTAssertEqual(id(m, ["java -jar app.jar"]), "java")
        XCTAssertEqual(id(m, ["swift run"]), "swift")
        XCTAssertEqual(id(m, ["bash ./deploy.sh"]), "gnubash")
        XCTAssertNil(id(m, ["sh -c ls -la"]))
        XCTAssertNil(id(m, []))
    }

    func testEditorsAndAgentsHideTheirHelpers() throws {
        let m = try matcher()
        XCTAssertNil(id(m, ["nvim main.py", "node /x/pyright-langserver --stdio"]))
        XCTAssertNil(id(m, ["claude", "uv run server.py", "python server.py"]))
    }
}

final class SubagentTabClosingTests: XCTestCase {
    func testFindsTheEnclosingAppsIdentifier() {
        let app = Bundle.main.bundleURL
        // The test host is an app bundle; any executable inside it resolves to it.
        let inside = app.appendingPathComponent("Contents/MacOS/octet-cli").path
        XCTAssertEqual(SubagentWatch.appBundleIdentifier(executable: inside), Bundle.main.bundleIdentifier)
        XCTAssertNil(SubagentWatch.appBundleIdentifier(executable: "/usr/local/bin/octet-cli"))
    }

    func testRendererForgetsAFinishWhenTheSubagentResumes() throws {
        let renderer = SubagentTranscriptRenderer()
        func line(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        try renderer.render(line: line(["type": "assistant", "message": [
            "stop_reason": "end_turn", "content": [["type": "text", "text": "Done"]]]]))
        XCTAssertNotNil(renderer.finishedAt)
        try renderer.render(line: line(["type": "user", "message": ["content": "One more thing"]]))
        XCTAssertNil(renderer.finishedAt)
    }
}

final class ColorlessServerTests: XCTestCase {
    func testFindsOnlyThisSessionsServerStartedWithNoColor() {
        let list = """
          46183 /Applications/Octet.app/Contents/MacOS/octet-engine server TERM=xterm HERDR_SESSION=octet NO_COLOR=1 HOME=/Users/x
            900 /Applications/Octet.app/Contents/MacOS/octet-engine server HERDR_SESSION=other NO_COLOR=1
            901 /Applications/Octet.app/Contents/MacOS/octet-engine --session octet HERDR_SESSION=octet NO_COLOR=1
            902 /usr/bin/node server NO_COLOR=1 HERDR_SESSION=octet
        """
        XCTAssertEqual(TerminalEnvironment.colorlessServer(session: "octet", processList: list), 46183)
        XCTAssertNil(TerminalEnvironment.colorlessServer(session: "octet", processList: """
          46183 /Applications/Octet.app/Contents/MacOS/octet-engine server HERDR_SESSION=octet FORCE_COLOR=3
        """))
    }

    func testTheLiveCheckRuns() {
        // Nothing to assert about this machine's servers; it must not hang or crash.
        _ = TerminalEnvironment.colorlessServer(session: "octet-tests-\(UUID().uuidString)")
    }
}

final class GitCloneMenuTests: XCTestCase {
    func testReposAreNotCrowdedOutByFilesOrHistory() {
        let generator = CompletionSpec.Generator(id: "t.crowd", command: "true", kind: .repository)
        var spec = CompletionSpecs.git
        spec.subcommands = spec.subcommands.map { var sub = $0; if sub.name == "clone" { sub.argument = .generator(generator) }; return sub }
        let files = (0..<30).map { (name: "f\($0)", isDirectory: $0 % 2 == 0) }
        let repos = (0..<5).map { "https://github.com/acme/r\($0).git\tacme/r\($0)\t" }
        let results = Completions.suggestions(for: CompletionContext.at(caret: 10, in: "git clone "),
                                              entries: files, history: ["git status", "git clone x"],
                                              spec: spec, generatorValues: repos)
        XCTAssertEqual(results.prefix(5).map(\.kind), Array(repeating: .repository, count: 5))
        XCTAssertFalse(results.contains { $0.kind == .file || $0.kind == .directory || $0.kind == .history })
    }

    @MainActor
    func testEveryoneWaitingOnOneRunHearsWhenItLands() {
        let generator = CompletionSpec.Generator(id: "t.wait.\(UUID().uuidString)", command: "echo hi", perFolder: false)
        let prefetch = expectation(description: "prefetch told")
        let menu = expectation(description: "menu told")
        GeneratorCache.shared.refreshIfStale(generator, cwd: "/tmp") { prefetch.fulfill() }
        GeneratorCache.shared.refreshIfStale(generator, cwd: "/tmp") { menu.fulfill() }
        wait(for: [prefetch, menu], timeout: 5)
        XCTAssertEqual(GeneratorCache.shared.values(generator, cwd: "/tmp"), ["hi"])
    }
}

final class GitCloneEdgeCaseTests: XCTestCase {
    private func cloneSpec() throws -> CompletionSpec {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Plugins").path
        let plugin = try XCTUnwrap(OctetPlugins.discover(bundled: root, user: "/nonexistent").plugins.first { $0.id == "github-repos" })
        return try XCTUnwrap(OctetPlugins.applying(plugin.manifest.contributes.completions.map { ($0, plugin) },
                                                  to: CompletionSpecs.git, command: "git"))
    }

    private let repos = ["https://github.com/acme/zeta.git\tacme/zeta\t"]
    private let files: [(name: String, isDirectory: Bool)] = [("src", true), ("README.md", false)]

    private func kinds(_ line: String, _ spec: CompletionSpec) -> Set<Completion.Kind> {
        let context = CompletionContext.at(caret: line.count, in: line)
        let values = Completions.generator(for: spec, words: context.wordsBeforeToken)
            .map { _ in repos } ?? []
        return Set(Completions.suggestions(for: context, entries: files, spec: spec, generatorValues: values).map(\.kind))
    }

    func testRepositoriesFillTheFirstArgument() throws {
        XCTAssertTrue(kinds("git clone ", try cloneSpec()).contains(.repository))
    }

    func testAfterTheRepositoryComesADirectory() throws {
        let spec = try cloneSpec()
        let after = kinds("git clone https://github.com/acme/zeta.git ", spec)
        XCTAssertFalse(after.contains(.repository))
        XCTAssertTrue(after.contains(.directory))
    }

    func testAnOptionsValueIsNotARepository() throws {
        let spec = try cloneSpec()
        XCTAssertFalse(kinds("git clone --depth ", spec).contains(.repository))
        XCTAssertFalse(kinds("git clone -b ", spec).contains(.repository))
        // Once the option has its value, the repository is still to come.
        XCTAssertTrue(kinds("git clone --depth 1 ", spec).contains(.repository))
        XCTAssertTrue(kinds("git clone -b main ", spec).contains(.repository))
        XCTAssertTrue(kinds("git clone --recurse-submodules ", spec).contains(.repository))
    }

    func testOtherGitSubcommandsAreUnaffected() throws {
        let spec = try cloneSpec()
        XCTAssertEqual(Completions.generator(for: spec, words: ["checkout"])?.id, CompletionSpecs.branches.id)
        XCTAssertNil(Completions.generator(for: spec, words: ["status"]))
    }
}

final class ShellLineTrackerTests: XCTestCase {
    func testTextReachingTheShellKeepsOctetOutUntilTheLineRunsOrClears() {
        var tracker = ShellLineTracker()
        tracker.keyReachedPane("p", .text)
        XCTAssertTrue(tracker.holdsLine("p"))
        XCTAssertFalse(tracker.holdsLine("q"), "per pane")
        tracker.keyReachedPane("p", .other)
        XCTAssertTrue(tracker.holdsLine("p"))
        tracker.keyReachedPane("p", .submit)
        XCTAssertFalse(tracker.holdsLine("p"))
        tracker.keyReachedPane("p", .text)
        tracker.keyReachedPane("p", .clear)
        XCTAssertFalse(tracker.holdsLine("p"))
    }

    func testAProgramExitingLeavesAFreshPrompt() {
        var tracker = ShellLineTracker()
        tracker.observe("p", programInFront: true)
        tracker.keyReachedPane("p", .text)      // typed into less, then `q`
        tracker.observe("p", programInFront: nil) // unknown changes nothing
        XCTAssertTrue(tracker.holdsLine("p"))
        tracker.observe("p", programInFront: false)
        XCTAssertFalse(tracker.holdsLine("p"))
    }

    func testTextTypedAtAPromptSurvivesPromptObservations() {
        var tracker = ShellLineTracker()
        tracker.observe("p", programInFront: false)
        tracker.keyReachedPane("p", .text)
        tracker.observe("p", programInFront: false)
        XCTAssertTrue(tracker.holdsLine("p"))
    }

    func testOctetHandingItsLineBack() {
        var tracker = ShellLineTracker()
        tracker.handedLine("p", submitted: false)
        XCTAssertTrue(tracker.holdsLine("p"))
        tracker.handedLine("p", submitted: true)
        XCTAssertFalse(tracker.holdsLine("p"))
    }
}

final class CompletionMenuTidinessTests: XCTestCase {
    private let files: [(name: String, isDirectory: Bool)] = [("src", true), ("README.md", false)]
    private let history = ["git push", "git status", "git clone x"]

    private func menu(_ line: String) -> [Completion] {
        Completions.suggestions(for: CompletionContext.at(caret: line.count, in: line),
                                entries: files, history: history, spec: CompletionSpecs.git)
    }

    func testTheCloneDestinationOffersOnlyFolders() {
        let results = menu("git clone https://github.com/acme/zeta.git ")
        XCTAssertEqual(results.map(\.value), ["src/"])
    }

    func testFlagsWaitForADash() {
        XCTAssertFalse(menu("git clone ").contains { $0.value.hasPrefix("-") })
        XCTAssertTrue(menu("git clone --").contains { $0.value == "--depth" })
    }

    func testHistoryWordsOnlyRightAfterTheCommand() {
        XCTAssertTrue(menu("git ").contains { $0.kind == .history && $0.value == "push" })
        XCTAssertFalse(menu("git add ").contains { $0.kind == .history })
    }
}

final class WholeWordTabTests: XCTestCase {
    private func whole(_ line: String) -> Bool {
        Completions.isCompleteWord(CompletionContext.at(caret: line.count, in: line), spec: CompletionSpecs.git,
                                   commands: ["git", "ls"])
    }

    func testTabFinishesAWordThatIsAlreadyWhole() {
        XCTAssertTrue(whole("git clone"))
        XCTAssertTrue(whole("git"))
        XCTAssertTrue(whole("git clone --depth"))
        XCTAssertFalse(whole("git clo"))
        XCTAssertFalse(whole("git clone "))
        XCTAssertFalse(whole("git clone src"))
    }
}

final class ShellLinePersistenceTests: XCTestCase {
    func testKeysNameAShellNotJustAPane() {
        XCTAssertEqual(ShellLineTracker.key(pane: "wE:p1", shellPid: 4321), "wE:p1#4321")
        XCTAssertEqual(ShellLineTracker.key(pane: "wE:p1", shellPid: nil), "wE:p1")
        XCTAssertEqual(ShellLineTracker.shellPid(inKey: "wE:p1#4321"), 4321)
        XCTAssertNil(ShellLineTracker.shellPid(inKey: "wE:p1"))
    }

    func testRestoredLinesOfExitedShellsAreDropped() {
        let saved = ShellLineTracker(holding: ["a#100", "b#200", "c"])
        let restored = saved.pruned { $0 == 100 }
        XCTAssertTrue(restored.holdsLine("a#100"))
        XCTAssertFalse(restored.holdsLine("b#200"))
        XCTAssertFalse(restored.holdsLine("c"), "without a pid it can't be checked, so it isn't trusted")
    }

    func testANewShellInAReusedPaneStartsClean() {
        var tracker = ShellLineTracker()
        tracker.keyReachedPane(ShellLineTracker.key(pane: "p1", shellPid: 100), .text)
        XCTAssertFalse(tracker.holdsLine(ShellLineTracker.key(pane: "p1", shellPid: 200)))
    }
}
