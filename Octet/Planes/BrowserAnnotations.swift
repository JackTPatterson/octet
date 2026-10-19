import AppKit
import Combine
import WebKit

@MainActor
final class BrowserAnnotations: NSObject, ObservableObject {
    static let world = WKContentWorld.world(name: "OctetAnnotations")
    @Published var items: [BrowserAnnotation] = [] {
        didSet {
            guard let draftFile else { return }
            do { try BrowserDrafts.save(items, to: draftFile, projectDirectory: projectDirectory) }
            catch { failure = "Couldn't save annotation drafts: " + error.localizedDescription }
        }
    }
    private let draftFile: URL?
    private var projectDirectory: String?
    func setProjectDirectory(_ directory: String?) {
        projectDirectory = directory
        guard let draftFile else { return }
        do { try BrowserDrafts.save(items, to: draftFile, projectDirectory: directory) }
        catch { failure = error.localizedDescription }
    }
    init(draftFile: URL? = nil) {
        self.draftFile = draftFile
        super.init()
        if let draftFile {
            do {
                items = try BrowserDrafts.load(draftFile).map { BrowserAnnotation(id: $0.id, context: $0.context, note: $0.note, screenshot: nil) }
            } catch { failure = "Couldn't restore annotation drafts: " + error.localizedDescription }
        }
    }
    @Published private(set) var picking = false
    @Published private(set) var capturing = false
    @Published var failure: String?
    private weak var view: WKWebView?
    private var generation = UUID()

    func attach(_ view: WKWebView) {
        self.view = view
        let controller = view.configuration.userContentController
        controller.add(AnnotationMessageHandler(owner: self), contentWorld: Self.world, name: "octetAnnotation")
        controller.addUserScript(WKUserScript(source: BrowserAnnotationScript.source, injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true, in: Self.world))
    }

    func toggle() {
        guard let view, ["http", "https"].contains(view.url?.scheme ?? ""), !capturing else { return }
        guard items.count < 8 else { failure = "Send or remove an annotation before adding more (maximum 8)."; return }
        let wanted = !picking
        view.evaluateJavaScript("globalThis.octetPicker?.set(\(wanted ? "true" : "false"))", in: nil, in: Self.world) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): self.picking = value as? Bool ?? false
            case .failure(let error): self.failure = error.localizedDescription
            }
        }
    }

    func navigationChanged() { generation = UUID(); picking = false; capturing = false }
    func clear() {
        navigationChanged(); items = []; failure = nil
        view?.evaluateJavaScript("globalThis.octetPicker?.set(false)", in: nil, in: Self.world) { _ in }
    }

    func receive(_ body: Any) {
        guard picking, !capturing, items.count < 8, let view else { return }
        if let value = body as? [String: Any], value["cancelled"] as? Bool == true { picking = false; return }
        do {
            let context = try BrowserElementContext.parse(body)
            guard let current = view.url, let captured = URL(string: context.url), current.host == captured.host,
                  current.scheme == captured.scheme, current.port == captured.port, current.path == captured.path else { return }
            picking = false; capturing = true; failure = nil
            let token = generation
            let scaleX = view.bounds.width / context.rect.viewportWidth
            let scaleY = view.bounds.height / context.rect.viewportHeight
            let rect = CGRect(x: context.rect.x * scaleX, y: context.rect.y * scaleY,
                              width: context.rect.width * scaleX, height: context.rect.height * scaleY).intersection(view.bounds)
            guard !rect.isEmpty, !rect.isNull else { capturing = false; throw BrowserElementContext.AnnotationError.invalid }
            let config = WKSnapshotConfiguration()
            config.rect = rect
            config.snapshotWidth = NSNumber(value: min(rect.width, 1000))
            view.takeSnapshot(with: config) { [weak self] image, error in
                guard let self, self.generation == token else { return }
                self.capturing = false
                let png = image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
                self.items.append(BrowserAnnotation(context: context, screenshot: png.flatMap { $0.count <= 4_000_000 ? $0 : nil }))
                if error != nil { self.failure = "Element context captured, but its screenshot was unavailable." }
            }
        } catch { picking = false; capturing = false; failure = error.localizedDescription }
    }
}

private final class AnnotationMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserAnnotations?
    init(owner: BrowserAnnotations) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        MainActor.assumeIsolated { owner?.receive(message.body) }
    }
}
