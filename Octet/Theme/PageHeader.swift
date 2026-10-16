import SwiftUI

/// One step of a page's breadcrumb, after T3 Code's: the page's own name in
/// muted text, then pickers for what the page shows ("All providers").
enum Breadcrumb: Identifiable {
    case title(String)
    /// Opens `spec`'s menu from the page's `octetDropdownHost`; `label`
    /// says what's chosen, `mark` draws before it (a provider's logo, say).
    case picker(spec: OctetDropdownSpec, label: String, mark: AnyView? = nil)

    var id: String {
        switch self {
        case .title(let text): "title:" + text
        case .picker(let spec, _, _): "picker:" + spec.id
        }
    }
}

/// The 52pt header every full page over the content area shares (Usage,
/// Pull Requests): a breadcrumb on the left, the page's controls on the
/// right, then a close button. The page draws the dropdown host, so its
/// menus open over the page body rather than inside the header.
struct PageHeader<Trailing: View>: View {
    let crumbs: [Breadcrumb]
    @ObservedObject var dropdowns: OctetDropdownState
    var close: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    static var height: CGFloat { 52 }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Text("/").font(Theme.interfaceFont(13, weight: .medium)).foregroundStyle(Theme.textMuted)
                            .accessibilityHidden(true)
                    }
                    switch crumb {
                    case .title(let text):
                        Text(text).font(Theme.interfaceFont(13, weight: .medium)).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    case .picker(let spec, let label, let mark):
                        BreadcrumbPicker(spec: spec, label: label, mark: mark, dropdowns: dropdowns)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Breadcrumb")
            Spacer(minLength: 12)
            trailing()
            if let close {
                OctetIconButton(icon: "xmark", help: "Close (Esc)", action: close)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
    }
}

/// A crumb that picks: foreground text with a rounded hover fill, and a
/// small chevron that shows on hover or while its menu is open.
private struct BreadcrumbPicker: View {
    let spec: OctetDropdownSpec
    let label: String
    let mark: AnyView?
    @ObservedObject var dropdowns: OctetDropdownState
    @State private var hovered = false

    var body: some View {
        OctetDropdownAnchor(spec: spec, state: dropdowns) { open in
            HStack(spacing: 5) {
                if let mark { mark }
                Text(label).font(Theme.interfaceFont(13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                OctetIcon("chevron.down", size: 10)
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovered || open ? 1 : 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered || open ? Theme.hover : .clear))
        }
        .onHover { hovered = $0 }
        // Pulls the text back into line with the plain crumbs; the hover
        // fill reaches out into the gap instead.
        .padding(.horizontal, -6)
        .accessibilityLabel(label)
        .accessibilityHint("Opens a menu")
    }
}
