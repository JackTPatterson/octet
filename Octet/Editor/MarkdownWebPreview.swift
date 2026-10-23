import AppKit
import SwiftUI
import WebKit

/// A Markdown file as it reads on GitHub: its blocks rendered as HTML, with
/// the file's own HTML (centred headers, badges, pictures, details) drawn as
/// written and images loaded from beside the file. Typing in the code beside
/// it updates the page in place, keeping where it's scrolled to. Links to
/// the web open in the browser, links to files open here, and `#anchors`
/// move within the page.
struct MarkdownWebPreview: NSViewRepresentable {
    let text: String
    let baseURL: URL
    /// A linked file, opened in Octet's editor.
    let openFile: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(into: view, text: text, baseURL: baseURL)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.openFile = openFile
        context.coordinator.update(view, text: text, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var shown: String?
        private var folder: URL?
        private var palette: ThemePalette?
        private var loaded = false
        /// The page written for the file's folder, so relative images load.
        private var page: URL?
        var openFile: (URL) -> Void = { _ in }

        func load(into view: WKWebView, text: String, baseURL: URL) {
            shown = text
            folder = baseURL
            palette = Theme.palette
            loaded = false
            let page = FileManager.default.temporaryDirectory
                .appendingPathComponent("octet-markdown-\(UUID().uuidString).html")
            let html = MarkdownPage.html(body: MarkdownHTML.body(text), base: baseURL, palette: Theme.palette)
            do {
                try html.write(to: page, atomically: true, encoding: .utf8)
            } catch {
                view.loadHTMLString(html, baseURL: baseURL)
                return
            }
            removePage()
            self.page = page
            // Read access to the whole disk: the file's images can be anywhere
            // its relative paths lead.
            view.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }

        func update(_ view: WKWebView, text: String, baseURL: URL) {
            // Another file, or another theme, is a new page.
            guard baseURL == folder, Theme.palette == palette else { return load(into: view, text: text, baseURL: baseURL) }
            guard text != shown else { return }
            shown = text
            guard loaded else { return load(into: view, text: text, baseURL: baseURL) }
            let body = MarkdownHTML.body(text)
            guard let data = try? JSONSerialization.data(withJSONObject: [body]),
                  let argument = String(data: data, encoding: .utf8) else { return }
            view.evaluateJavaScript("document.getElementById('content').innerHTML = \(argument)[0];")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            // `#anchor` resolves against the file's folder (the page's base):
            // it means a heading here.
            let local = url.isFileURL ? URL(fileURLWithPath: url.path).standardizedFileURL : nil
            if let fragment = url.fragment, let local,
               local == folder?.standardizedFileURL || local.path == page?.path {
                guard let data = try? JSONSerialization.data(withJSONObject: [fragment.removingPercentEncoding ?? fragment]),
                      let argument = String(data: data, encoding: .utf8) else { return }
                webView.evaluateJavaScript("document.getElementById(\(argument)[0])?.scrollIntoView({behavior: 'smooth'});")
                return
            }
            var isFolder: ObjCBool = false
            if let local, FileManager.default.fileExists(atPath: local.path, isDirectory: &isFolder), !isFolder.boolValue {
                openFile(local)
            } else {
                NSWorkspace.shared.open(url)
            }
        }

        private func removePage() {
            if let page { try? FileManager.default.removeItem(at: page) }
        }

        deinit { removePage() }
    }
}

/// The viewer's page: GitHub's Markdown layout in the theme's colours.
enum MarkdownPage {
    static func html(body: String, base: URL, palette: ThemePalette) -> String {
        func css(_ hex: String) -> String { hex.hasPrefix("#") ? hex : "#" + hex }
        let folder = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <base href="\(MarkdownHTML.escape(folder))">
        <style>
        :root { color-scheme: \(palette.isLight ? "light" : "dark"); }
        html, body { background: transparent; margin: 0; }
        body { color: \(css(palette.textPrimary)); font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
               -webkit-font-smoothing: antialiased; }
        #content { max-width: 760px; margin: 0 auto; padding: 22px 28px 48px; word-wrap: break-word; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 24px 0 12px; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        h1, h2 { padding-bottom: .3em; border-bottom: 1px solid \(css(palette.divider)); }
        p, ul, ol, blockquote, pre, table, .alert, details { margin: 0 0 16px; }
        a { color: \(css(palette.accent)); text-decoration: none; }
        a:hover { text-decoration: underline; }
        img { max-width: 100%; vertical-align: middle; }
        code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: \(css(palette.hover));
               padding: .15em .35em; border-radius: 5px; }
        pre { background: \(css(palette.card)); border: 1px solid \(css(palette.border)); border-radius: 8px;
              padding: 12px 14px; overflow-x: auto; line-height: 1.45; }
        pre code { background: none; padding: 0; }
        blockquote { color: \(css(palette.textSecondary)); border-left: 3px solid \(css(palette.border));
                     margin-left: 0; padding: 0 14px; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li > ul, li > ol { margin: .25em 0 0; }
        li input[type=checkbox] { margin: 0 .4em 0 -1.3em; vertical-align: middle; }
        hr { border: 0; border-top: 1px solid \(css(palette.divider)); margin: 24px 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid \(css(palette.border)); padding: 6px 13px; }
        th { font-weight: 600; background: \(css(palette.card)); }
        details summary { cursor: pointer; }
        .alert { border-left: 3px solid var(--tone); padding: 2px 14px; }
        .alert-title { color: var(--tone); font-weight: 600; margin-bottom: 4px; }
        .alert-note { --tone: \(css(palette.accent)); } .alert-tip { --tone: \(css(palette.success)); }
        .alert-important { --tone: \(css(palette.syntaxVariable)); }
        .alert-warning { --tone: \(css(palette.warning)); } .alert-caution { --tone: \(css(palette.danger)); }
        </style></head>
        <body><div id="content">\(body)</div></body></html>
        """
    }
}
