import SwiftUI

/// A file's icon in the Files tab: its language's logo when it has one,
/// otherwise a mark for what kind of file it is.
struct FileTypeIcon: View {
    let name: String
    var size: CGFloat = 13

    var body: some View {
        if let logo = LanguageLogo(path: name, size: size) {
            logo.frame(width: size, height: size)
        } else {
            OctetIcon(FileIcons.symbol(forName: name), size: size)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
