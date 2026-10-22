import AppKit
import SwiftUI

extension View {
    /// A popover Octet opens and closes itself, for hover cards. SwiftUI's
    /// `.popover` is transient: the next click anywhere is spent closing it,
    /// so a click on the row beside it did nothing and had to be repeated.
    /// This one never takes a click; `isPresented` alone shows and hides it.
    func hoverPopover<Content: View>(isPresented: Binding<Bool>, edge: NSRectEdge = .maxX,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        background(HoverPopoverAnchor(isPresented: isPresented, edge: edge, content: content))
    }
}

private struct HoverPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let edge: NSRectEdge
    let content: () -> Content

    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var host: NSHostingController<AnyView>?
        var dismissed: (() -> Void)?

        func popoverDidClose(_ notification: Notification) { dismissed?() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.dismissed = { if isPresented { isPresented = false } }
        if isPresented {
            let root = AnyView(content().environment(\.colorScheme, Theme.colorScheme))
            if let host = coordinator.host {
                host.rootView = root
            } else {
                coordinator.host = NSHostingController(rootView: root)
                coordinator.host?.sizingOptions = .preferredContentSize
            }
            guard coordinator.popover?.isShown != true, view.window != nil else { return }
            let popover = NSPopover()
            // Shown and closed by Octet alone: it never consumes a click.
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.contentViewController = coordinator.host
            popover.delegate = coordinator
            popover.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
            coordinator.popover = popover
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        } else if let popover = coordinator.popover, popover.isShown {
            popover.performClose(nil)
            coordinator.popover = nil
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.popover?.close()
        coordinator.popover = nil
    }
}
