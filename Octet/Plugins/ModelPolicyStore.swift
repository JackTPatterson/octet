import Combine
import Foundation

/// Runs enabled plugins' model policies for Octet's Claude and Codex
/// conversations: whenever the account's usage or a conversation's pick
/// changes, each idle conversation is moved onto what the first policy that
/// answers chose, or back onto the person's own pick. A conversation mid-turn
/// is left alone until the turn ends.
@MainActor
final class ModelPolicyStore {
    static let shared = ModelPolicyStore()

    private var subscriptions: Set<AnyCancellable> = []
    private var asking: Set<String> = []

    func start() {
        guard subscriptions.isEmpty else { return }
        // Conversations open, close, pick and finish turns through the center.
        Publishers.Merge4(
            AccountStore.shared.$accounts.map { _ in () },
            AgentCenter.shared.objectWillChange.map { _ in () },
            OctetPluginHost.shared.objectWillChange.map { _ in () },
            PluginSettingsStore.shared.$revision.map { _ in () }
        )
        // Throttled, not debounced: one conversation streaming mustn't keep
        // the others from being looked at.
        .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        .store(in: &subscriptions)
    }

    private func evaluate() {
        for session in AgentCenter.shared.sessions where !session.conversation.isRunning {
            evaluate(session)
        }
    }

    private func evaluate(_ session: AgentSession) {
        guard let agent = Self.agent(of: session), !asking.contains(session.id) else { return }
        let options = Self.options(for: session)
        guard !options.isEmpty else { return }
        let personal = session.personalPick
        var pick = personal
        // A Codex conversation that never picked runs Codex's default.
        if !options.contains(where: { $0.id == pick.model }) {
            guard let fallback = Self.defaultModel(for: session) else { return }
            pick.model = fallback
        }
        let windows = AccountStore.shared.accounts[agent]?.live ?? []
        let host = OctetPluginHost.shared
        let policies = host.plugins.filter(host.isEnabled).flatMap { plugin in
            plugin.manifest.contributes.modelPolicies.filter { $0.applies(to: agent) && !$0.run.isEmpty }.map { ($0, plugin) }
        }
        let key = ModelPolicy.key(agent: agent, pick: pick, windows: windows)
            + "|" + policies.map { "\($0.1.id)@\($0.1.manifest.version)" }.joined(separator: ",")
            + "|\(PluginSettingsStore.shared.revision)"
        guard session.policyKey != key else { return }
        session.policyKey = key
        guard !policies.isEmpty else {
            // Uninstalled or switched off: back to the person's own pick.
            if session.policyHeld != nil { apply(ModelPolicy.Answer(), pick: pick, options: options, to: session) }
            return
        }
        asking.insert(session.id)
        let environment = ModelPolicy.environment(agent: agent, pick: pick, options: options, windows: windows)
        ask(policies[...], environment: environment, in: session.cwd) { [weak self, weak session] answer in
            guard let self, let session else { return }
            self.asking.remove(session.id)
            // Picked again, or a turn started, while it was asked: next time.
            guard session.personalPick == personal, !session.conversation.isRunning else {
                session.policyKey = nil
                return
            }
            self.apply(answer, pick: pick, options: options, to: session)
        }
    }

    /// Asks each policy in turn until one answers.
    private func ask(_ policies: ArraySlice<(OctetPluginManifest.ModelPolicyContribution, OctetPlugin)>,
                     environment: [String: String], in directory: String,
                     done: @escaping @MainActor (ModelPolicy.Answer) -> Void) {
        guard let (policy, plugin) = policies.first else { return done(ModelPolicy.Answer()) }
        let timeout = min(max(policy.timeoutSeconds ?? 5, 1), 20)
        let env = OctetPluginHost.environment(plugin, directory: directory).merging(environment) { _, octet in octet }
        StatusCommand.run(policy.run, in: directory, environment: env, timeout: timeout) { [weak self] output in
            let answer = ModelPolicy.parse(output)
            if answer.model != nil || answer.effort != nil {
                done(answer)
            } else {
                self?.ask(policies.dropFirst(), environment: environment, in: directory, done: done)
            }
        }
    }

    private func apply(_ answer: ModelPolicy.Answer, pick: ModelPolicy.Pick, options: [ModelPolicy.Option],
                       to session: AgentSession) {
        let target = ModelPolicy.resolve(answer, pick: pick, options: options)
        session.applyPolicy(target, message: answer.message) { Self.modelName($0, for: session) }
    }

    static func agent(of session: AgentSession) -> String? {
        switch session.engine {
        case .claude: "claude"
        case .codex: "codex"
        default: nil
        }
    }

    static func options(for session: AgentSession) -> [ModelPolicy.Option] {
        switch session.engine {
        case .claude:
            return AgentSession.models.map { model in
                let efforts = model.efforts
                    ?? (AgentSession.supportsEffort(model: model.id) ? AgentSession.efforts.filter { $0 != "ultracode" } : [])
                return ModelPolicy.Option(id: model.id, efforts: efforts)
            }
        case .codex:
            return CodexCatalogStore.shared.models.map { ModelPolicy.Option(id: $0.id, efforts: $0.efforts) }
        default:
            return []
        }
    }

    private static func defaultModel(for session: AgentSession) -> String? {
        session.engine == .codex ? CodexCatalogStore.shared.defaultModel?.id : nil
    }

    static func modelName(_ id: String, for session: AgentSession) -> String {
        switch session.engine {
        case .claude: AgentSession.model(id)?.title ?? id
        case .codex: CodexCatalogStore.shared.models.first { $0.id == id }?.displayName ?? id
        default: id
        }
    }
}
