import SwiftUI

extension ShellSyntax.Role {
    /// The colour a shell word of this role is drawn in, wherever Octet
    /// highlights a command: the command line, and commands shown in a
    /// conversation. `argument` is the plain words' colour, which differs:
    /// full strength on the command line, quieter in a transcript.
    func color(argument: Color = Theme.textPrimary) -> Color {
        switch self {
        case .command: Theme.accent
        case .builtin, .reserved: Theme.palette.color(\.syntaxBuiltin)
        case .flag: Theme.palette.color(\.syntaxFlag)
        case .string: Theme.palette.color(\.syntaxString)
        case .path, .glob: Theme.palette.color(\.syntaxPath)
        case .variable, .assignment, .expansion: Theme.palette.color(\.syntaxVariable)
        case .redirect, .separator: Theme.textSecondary
        case .comment: Theme.textTertiary
        case .argument: argument
        }
    }
}
