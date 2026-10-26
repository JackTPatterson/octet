import Foundation

/// One environment variable a credential profile sets, such as Supabase's
/// `SUPABASE_ACCESS_TOKEN`. A secret's value lives in the Keychain; only a
/// plain one (`AWS_PROFILE`) is kept in settings.
struct CredentialVariable: Codable, Equatable, Identifiable {
    var name: String
    var secret = true
    var value = ""

    var id: String { name }

    init(name: String, secret: Bool = true, value: String = "") {
        self.name = name
        self.secret = secret
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case name, secret, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        secret = try container.decodeIfPresent(Bool.self, forKey: .secret) ?? true
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

/// A named bundle of environment for command-line tools, such as "Aventix"
/// with its Supabase token and "JPX" with its own, chosen per project folder.
struct CredentialProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var variables: [CredentialVariable]
}

/// A folder (and everything under it) using a credential profile.
struct CredentialAssignment: Codable, Equatable {
    var folder: String
    var profileId: String
}

enum CredentialProfiles {
    /// A starting point for a new profile.
    struct Template: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let variables: [CredentialVariable]
    }

    static let templates: [Template] = [
        Template(id: "supabase", title: "Supabase CLI", symbol: "cylinder.split.1x2.fill", variables: [
            CredentialVariable(name: "SUPABASE_ACCESS_TOKEN"),
            CredentialVariable(name: "SUPABASE_DB_PASSWORD"),
        ]),
        Template(id: "github", title: "GitHub CLI", symbol: "chevron.left.forwardslash.chevron.right", variables: [
            CredentialVariable(name: "GH_TOKEN"),
        ]),
        Template(id: "vercel", title: "Vercel", symbol: "triangle.fill", variables: [
            CredentialVariable(name: "VERCEL_TOKEN"),
            CredentialVariable(name: "VERCEL_ORG_ID", secret: false),
        ]),
        Template(id: "cloudflare", title: "Cloudflare", symbol: "cloud.fill", variables: [
            CredentialVariable(name: "CLOUDFLARE_API_TOKEN"),
            CredentialVariable(name: "CLOUDFLARE_ACCOUNT_ID", secret: false),
        ]),
        Template(id: "aws", title: "AWS", symbol: "server.rack", variables: [
            CredentialVariable(name: "AWS_PROFILE", secret: false),
            CredentialVariable(name: "AWS_REGION", secret: false),
        ]),
        Template(id: "stripe", title: "Stripe CLI", symbol: "creditcard.fill", variables: [
            CredentialVariable(name: "STRIPE_API_KEY"),
        ]),
        Template(id: "fly", title: "Fly.io", symbol: "paperplane.fill", variables: [
            CredentialVariable(name: "FLY_API_TOKEN"),
        ]),
        Template(id: "custom", title: "Custom", symbol: "key.fill", variables: [
            CredentialVariable(name: ""),
        ]),
    ]

    /// Keychain entry names: one per profile and variable.
    static func keychainAccount(profileId: String, variable: String) -> String { "\(profileId):\(variable)" }

    /// Reads a secret by its Keychain account. The app installs the real
    /// reader; code without a Keychain gets none.
    nonisolated(unsafe) static var readSecret: (String) -> String? = { _ in nil }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: (profiles: [CredentialProfile], assignments: [CredentialAssignment]) = ([], [])

    static func configure(profiles: [CredentialProfile], assignments: [CredentialAssignment]) {
        lock.withLock { current = (profiles, assignments) }
    }

    static var configured: (profiles: [CredentialProfile], assignments: [CredentialAssignment]) {
        lock.withLock { current }
    }

    static var hasAssignments: Bool { !configured.assignments.isEmpty }

    /// The profiles `directory` uses, shallow folders first and later
    /// assignments after earlier ones, so what comes last wins. A worktree
    /// counts as its project's checkout, wherever it lives (`root`).
    static func profiles(for directory: String, root: String? = nil, profiles: [CredentialProfile],
                         assignments: [CredentialAssignment]) -> [CredentialProfile] {
        let byId = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matching = assignments.enumerated().filter { _, assignment in
            AccountProfiles.contains(assignment.folder, directory)
                || root.map { AccountProfiles.contains(assignment.folder, $0) } == true
        }
        let ordered = matching.sorted { ($0.element.folder.count, $0.offset) < ($1.element.folder.count, $1.offset) }
        var seen = Set<String>()
        return ordered.compactMap { _, assignment in
            guard let profile = byId[assignment.profileId], seen.insert(profile.id).inserted else { return nil }
            return profile
        }
    }

    /// The variables those profiles set. Empty values are left unset, so a
    /// half-filled profile never blanks a variable the shell already has.
    static func environment(for directory: String, root: String? = nil, profiles: [CredentialProfile],
                            assignments: [CredentialAssignment],
                            secret: (String) -> String? = { readSecret($0) }) -> [String: String] {
        var environment: [String: String] = [:]
        for profile in self.profiles(for: directory, root: root, profiles: profiles, assignments: assignments) {
            for variable in profile.variables where !variable.name.isEmpty {
                let value = variable.secret
                    ? secret(keychainAccount(profileId: profile.id, variable: variable.name)) ?? ""
                    : variable.value
                if !value.isEmpty { environment[variable.name] = value }
            }
        }
        return environment
    }

    static func inForce(for directory: String) -> [CredentialProfile] {
        let (profiles, assignments) = configured
        guard !assignments.isEmpty else { return [] }
        return self.profiles(for: directory, root: AccountProfiles.projectRoot(of: directory),
                             profiles: profiles, assignments: assignments)
    }

    static func environment(for directory: String) -> [String: String] {
        let (profiles, assignments) = configured
        guard !assignments.isEmpty else { return [:] }
        return environment(for: directory, root: AccountProfiles.projectRoot(of: directory),
                           profiles: profiles, assignments: assignments)
    }
}
