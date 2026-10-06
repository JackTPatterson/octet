import AppKit
import CoreText
import UniformTypeIdentifiers

/// Fonts added from Settings › Text: installed into ~/Library/Fonts, as
/// Font Book does, so the terminal, Octet's interface and every other app
/// can use them, and activated for Octet at once.
@MainActor
enum CustomFonts {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts", isDirectory: true)
    }

    /// Asks for font files, installs them, and says which families they add.
    static func add(then done: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Add Fonts"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.font]
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { done(install(urls)) }
        }
    }

    /// Copies each file into the fonts folder (keeping one already there),
    /// activates it for this process, and returns the families found.
    @discardableResult
    static func install(_ urls: [URL]) -> [String] {
        var families: [String] = []
        var failures: [String] = []
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls {
            let found = Self.families(in: url)
            guard !found.isEmpty else {
                failures.append(url.lastPathComponent)
                continue
            }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                do { try FileManager.default.copyItem(at: url, to: destination) } catch {
                    failures.append(url.lastPathComponent)
                    continue
                }
            }
            // Already active (installed before, or picked up by macOS) is fine.
            CTFontManagerRegisterFontsForURL(destination as CFURL, .process, nil)
            families += found
        }
        if !failures.isEmpty {
            ToastCenter.shared.fail(nil, "Couldn't add \(failures.joined(separator: ", "))",
                                    detail: "Only TrueType and OpenType fonts (.ttf, .otf, .ttc) can be added.")
        }
        return Array(Set(families)).sorted()
    }

    /// The family names in a font file; empty for a file that isn't a font.
    static func families(in url: URL) -> [String] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
    }

    /// Fonts that are fixed-width, for the terminal.
    static var monospacedFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return visible(Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }))
    }

    /// Every installed family, for the interface.
    static var allFamilies: [String] { visible(Set(NSFontManager.shared.availableFontFamilies)) }

    private static func visible(_ families: Set<String>) -> [String] {
        families.filter { !$0.hasPrefix(".") }.sorted()
    }
}
