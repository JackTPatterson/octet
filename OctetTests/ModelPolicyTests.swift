import XCTest

final class ModelPolicyTests: XCTestCase {
    private let claude = [
        ModelPolicy.Option(id: "claude-opus-5", efforts: ["low", "medium", "high", "xhigh", "max"]),
        ModelPolicy.Option(id: "claude-sonnet-5", efforts: ["low", "medium", "high"]),
        ModelPolicy.Option(id: "claude-haiku-4-5", efforts: []),
    ]

    func testAnswersAreReadLineByLine() {
        let answer = ModelPolicy.parse("model: claude-sonnet-5\nnoise\neffort: Medium\nmessage: 5h at 88%\nmodel:\n")
        XCTAssertEqual(answer, ModelPolicy.Answer(model: "claude-sonnet-5", effort: "medium", message: "5h at 88%"))
        XCTAssertEqual(ModelPolicy.parse(""), ModelPolicy.Answer())
    }

    func testWindowsBecomeVariables() {
        XCTAssertEqual(ModelPolicy.variable(forWindow: "5h"), "OCTET_USAGE_5H")
        XCTAssertEqual(ModelPolicy.variable(forWindow: "7d Opus"), "OCTET_USAGE_7D_OPUS")
    }

    func testThePolicySeesThePickAndTheUsage() {
        let windows = [UsageWindow(name: "5h", used: 0.874, resetsAt: Date(timeIntervalSince1970: 1_000)),
                       UsageWindow(name: "7d", used: 0.2, resetsAt: nil)]
        let env = ModelPolicy.environment(agent: "claude", pick: .init(model: "claude-opus-5", effort: nil),
                                          options: claude, windows: windows)
        XCTAssertEqual(env["OCTET_MODEL"], "claude-opus-5")
        XCTAssertEqual(env["OCTET_EFFORT"], "")
        XCTAssertEqual(env["OCTET_MODELS"], "claude-opus-5 claude-sonnet-5 claude-haiku-4-5")
        XCTAssertEqual(env["OCTET_EFFORTS"], "low medium high xhigh max")
        XCTAssertEqual(env["OCTET_USAGE_5H"], "87")
        XCTAssertEqual(env["OCTET_USAGE_7D"], "20")
        XCTAssertEqual(env["OCTET_USAGE"], "87")
        XCTAssertEqual(env["OCTET_USAGE_WINDOW"], "5h")
        XCTAssertEqual(env["OCTET_USAGE_RESETS_AT"], "1000")
    }

    func testOnlyWhatTheAgentOffersIsTaken() {
        let pick = ModelPolicy.Pick(model: "claude-opus-5", effort: "xhigh")
        // A smaller model keeps the effort only if it takes it.
        XCTAssertEqual(ModelPolicy.resolve(.init(model: "claude-sonnet-5"), pick: pick, options: claude),
                       .init(model: "claude-sonnet-5", effort: nil))
        XCTAssertEqual(ModelPolicy.resolve(.init(model: "claude-sonnet-5", effort: "medium"), pick: pick, options: claude),
                       .init(model: "claude-sonnet-5", effort: "medium"))
        XCTAssertEqual(ModelPolicy.resolve(.init(model: "claude-haiku-4-5", effort: "low"), pick: pick, options: claude),
                       .init(model: "claude-haiku-4-5", effort: nil))
        // Unknown models and efforts are ignored; nothing keeps the pick.
        XCTAssertEqual(ModelPolicy.resolve(.init(model: "gpt-9", effort: "turbo"), pick: pick, options: claude), pick)
        XCTAssertEqual(ModelPolicy.resolve(.init(), pick: pick, options: claude), pick)
    }

    func testTheKeyChangesWithUsageAndPick() {
        let pick = ModelPolicy.Pick(model: "claude-opus-5", effort: nil)
        let low = [UsageWindow(name: "5h", used: 0.5, resetsAt: nil)]
        let high = [UsageWindow(name: "5h", used: 0.9, resetsAt: nil)]
        XCTAssertEqual(ModelPolicy.key(agent: "claude", pick: pick, windows: low),
                       ModelPolicy.key(agent: "claude", pick: pick, windows: low))
        XCTAssertNotEqual(ModelPolicy.key(agent: "claude", pick: pick, windows: low),
                          ModelPolicy.key(agent: "claude", pick: pick, windows: high))
        XCTAssertNotEqual(ModelPolicy.key(agent: "claude", pick: pick, windows: low),
                          ModelPolicy.key(agent: "claude", pick: .init(model: "claude-sonnet-5"), windows: low))
    }

    func testModelPoliciesReadFromAManifest() throws {
        let manifest = try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"""
        {"id": "p", "name": "P", "contributes": {"modelPolicies": [{"id": "usage", "agents": ["claude"], "run": "sh x.sh"}]}}
        """#.utf8))
        XCTAssertNil(OctetPlugins.validate(manifest))
        let policy = try XCTUnwrap(manifest.contributes.modelPolicies.first)
        XCTAssertEqual(policy.run, "sh x.sh")
        XCTAssertTrue(policy.applies(to: "claude"))
        XCTAssertFalse(policy.applies(to: "codex"))
        let bad = try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"""
        {"id": "p", "name": "P", "contributes": {"modelPolicies": [{"id": "usage", "agents": ["pi"], "run": "x"}]}}
        """#.utf8))
        XCTAssertNotNil(OctetPlugins.validate(bad))
    }

    /// The registry's model switcher, run as Octet runs it.
    func testTheModelSwitcherStepsDownAsUsageFills() throws {
        let root = try TestPlugins.pluginsPath()
        let found = OctetPlugins.discover(bundled: root, user: "/nonexistent")
        guard let plugin = found.plugins.first(where: { $0.id == "model-switcher" }) else {
            throw XCTSkip("The plugins checkout predates the model switcher")
        }
        let policy = try XCTUnwrap(plugin.manifest.contributes.modelPolicies.first)

        func answer(_ pick: ModelPolicy.Pick, _ windows: [UsageWindow], settings: [String: String] = [:]) -> ModelPolicy.Pick {
            var env = ModelPolicy.environment(agent: "claude", pick: pick, options: claude, windows: windows)
            env["OCTET_PLUGIN_DIR"] = plugin.directory
            env.merge(settings) { $1 }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", policy.run]
            process.environment = env.merging(["PATH": "/usr/bin:/bin"]) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ModelPolicy.resolve(ModelPolicy.parse(String(decoding: data, as: UTF8.self)), pick: pick, options: claude)
        }
        let opus = ModelPolicy.Pick(model: "claude-opus-5", effort: "xhigh")
        func used(_ percent: Double, _ name: String = "5h") -> [UsageWindow] {
            [UsageWindow(name: name, used: percent / 100, resetsAt: nil)]
        }
        XCTAssertEqual(answer(opus, used(50)), opus)
        XCTAssertEqual(answer(opus, used(75)), .init(model: "claude-opus-5", effort: "medium"))
        XCTAssertEqual(answer(opus, used(90)), .init(model: "claude-sonnet-5", effort: "medium"))
        XCTAssertEqual(answer(opus, used(97)), .init(model: "claude-haiku-4-5", effort: nil))
        // A window for one family counts only on it.
        XCTAssertEqual(answer(opus, used(90, "7d Opus")), .init(model: "claude-sonnet-5", effort: "medium"))
        let sonnet = ModelPolicy.Pick(model: "claude-sonnet-5", effort: "low")
        XCTAssertEqual(answer(sonnet, used(99, "7d Opus")), sonnet)
        // The thresholds are the person's.
        XCTAssertEqual(answer(opus, used(75), settings: ["EFFORT_DOWN_AT": "80"]), opus)
    }
}
