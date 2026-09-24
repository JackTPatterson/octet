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
