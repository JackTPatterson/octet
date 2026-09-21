// The app-wide terminal runtime: a single config built from a string (the
// renderer's own user config files are NOT loaded), and only the runtime
// actions Herd needs:
// SET_TITLE, PWD, MOUSE_SHAPE, MOUSE_VISIBILITY, MOUSE_OVER_LINK, CELL_SIZE,
// RENDERER_HEALTH, OPEN_URL, SHOW_CHILD_EXITED/CLOSE_*/QUIT (-> surface exit).
// Every other action returns false (unhandled).

import AppKit
import GhosttyKit

extension TerminalEngine {
    /// Maps to a `ghostty_config_t` and the various operations on that.
    class Config {
        private(set) var config: ghostty_config_t? {
            didSet {
                // Free the old value whenever we change
                guard let old = oldValue else { return }
                ghostty_config_free(old)
            }
        }

        /// Return the errors found while loading the configuration.
        var errors: [String] {
            guard let cfg = self.config else { return [] }

            var diags: [String] = []
            let diagsCount = ghostty_config_diagnostics_count(cfg)
            for i in 0..<diagsCount {
                let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                let message = String(cString: diag.message)
                diags.append(message)
            }

            return diags
        }

        /// Herd: build a config from defaults + the given config-file-syntax string.
        /// `ghostty_config_load_default_files` / CLI args are deliberately skipped so
        /// the user's personal terminal configuration files never leak into Herd.
        init(overrides: String) {
            self.config = Self.loadConfig(overrides: overrides)
        }

        deinit {
            self.config = nil
        }

        static func loadConfig(overrides: String) -> ghostty_config_t? {
            guard let cfg = ghostty_config_new() else {
                logger.critical("ghostty_config_new failed")
                return nil
            }

            if !overrides.isEmpty {
                let len = overrides.utf8CString.count - 1
                overrides.withCString { ptr in
                    ghostty_config_load_string(cfg, ptr, UInt(len), "herd")
                }
            }

            // Finalize will make our defaults available.
            ghostty_config_finalize(cfg)

            // Log any configuration errors.
            let diagsCount = ghostty_config_diagnostics_count(cfg)
            if diagsCount > 0 {
                for i in 0..<diagsCount {
                    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                    let message = String(cString: diag.message)
                    logger.warning("config error: \(message, privacy: .public)")
                }
            }

            return cfg
        }
    }

    class App {
        /// The global app configuration.
        private(set) var config: Config

        /// The terminal engine app instance.
        private(set) var app: ghostty_app_t? {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }

        /// Herd: applies new config-file-syntax overrides to the running app and
        /// every surface (fonts, colors, cursor, opacity, input options).
        func updateConfig(overrides: String) {
            let newConfig = Config(overrides: overrides)
            // Kept even when the config is rejected, so Settings can say why.
            lastConfigErrors = newConfig.config == nil ? ["The terminal rejected the new settings."] + newConfig.errors : newConfig.errors
            guard let app, let cfg = newConfig.config else { return }
            ghostty_app_update_config(app, cfg)
            config = newConfig
        }

        /// Diagnostics from the most recent update; nil before the first.
        private(set) var lastConfigErrors: [String]?

        /// Applies the renderer's background blur to a window.
        func applyBackgroundBlur(to window: NSWindow) {
            guard let app else { return }
            ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
        }

        init(overrides: String) {
            self.config = Config(overrides: overrides)
            guard let cfg = self.config.config else { return }

            // Create our "runtime" config. The "runtime" is the configuration that the engine
            // uses to interface with the application runtime environment.
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in App.confirmReadClipboard(userdata, string: str, state: state, request: request ) },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm) },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) },
                tmux_control_cb: nil
            )

            // Create the engine app.
            guard let app = ghostty_app_new(&runtime_cfg, cfg) else {
                logger.critical("ghostty_app_new failed")
                return
            }
            self.app = app

            // Set our initial focus state
            ghostty_app_set_focus(app, NSApp?.isActive ?? false)

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(keyboardSelectionDidChange(notification:)),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive(notification:)),
                name: NSApplication.didBecomeActiveNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidResignActive(notification:)),
                name: NSApplication.didResignActiveNotification,
                object: nil)
        }

        deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: App Operations

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        // MARK: Notifications

        // Called when the selected keyboard changes. We have to notify the engine so that
        // it can reload the keyboard mapping for input.
        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_keyboard_changed(app)
        }

        // Called when the app becomes active.
        @objc private func applicationDidBecomeActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, true)
        }

        // Called when the app becomes inactive.
        @objc private func applicationDidResignActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, false)
        }

        // MARK: Engine Callbacks (macOS)

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            let surface = self.surfaceUserdata(from: userdata)
            DispatchQueue.main.async { surface.notifyExit() }
        }

        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) -> Bool {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else { return false }

            // Get our pasteboard
            guard let pasteboard = NSPasteboard.terminal(location) else { return false }

            // Return false if there is no text-like clipboard content so
            // performable paste bindings can pass through to the terminal.
            guard let str = pasteboard.getOpinionatedStringContents() else { return false }

            completeClipboardRequest(surface, data: str, state: state)
            return true
        }

        /// A full terminal app would show a confirmation sheet for unsafe pastes and OSC 52
        /// reads. Herd has no such UI, so a paste is completed (confirmed) and an
        /// OSC 52 read is denied by completing with an empty string.
        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else { return }
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                guard let string, let valueStr = String(cString: string, encoding: .utf8) else { return }
                completeClipboardRequest(surface, data: valueStr, state: state, confirmed: true)
            default:
                completeClipboardRequest(surface, data: "", state: state, confirmed: true)
            }
        }

        static func completeClipboardRequest(
            _ surface: ghostty_surface_t,
            data: String,
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false
        ) {
            data.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
            }
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            guard let pasteboard = NSPasteboard.terminal(location) else { return }
            guard let content = content, len > 0 else { return }

            // Convert the C array to Swift array
            let contentArray = (0..<len).compactMap { i in
                TerminalEngine.ClipboardContent.from(content: content[i])
            }
            guard !contentArray.isEmpty else { return }

            // The engine asks for confirmation when `confirm` is set (OSC 52
            // writes under clipboard-write=ask). We have no prompt UI; with the
            // default config OSC 52 writes are allowed without confirmation, so a
            // confirm request is simply ignored.
            if confirm { return }

            // Declare all types
            let types = contentArray.compactMap { item in
                NSPasteboard.PasteboardType(mimeType: item.mime)
            }
            pasteboard.declareTypes(types, owner: nil)

            // Set data for each type
            for item in contentArray {
                guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                pasteboard.setString(item.data, forType: type)
            }
        }

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            let state = Unmanaged<App>.fromOpaque(userdata!).takeUnretainedValue()

            // Wakeup can be called from any thread so we schedule the app tick
            // from the main thread.
            DispatchQueue.main.async { state.appTick() }
        }

        /// Returns the surface view from the userdata.
        static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView {
            return Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        }

        static private func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
            guard let surface_ud = ghostty_surface_userdata(surface) else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(surface_ud).takeUnretainedValue()
        }

        /// Returns the surface view for a surface-targeted action.
        static private func surfaceView(from target: ghostty_target_s) -> SurfaceView? {
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
            guard let surface = target.target.surface else { return nil }
            return surfaceView(from: surface)
        }

        // MARK: Actions (macOS)

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Make sure it a target we understand so all our action handlers can assert
            switch target.tag {
            case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
                break

            default:
                TerminalEngine.logger.warning("unknown action target=\(target.tag.rawValue, privacy: .public)")
                return false
            }

            // Action dispatch
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                guard let surfaceView = surfaceView(from: target) else { return false }
                guard let cTitle = action.action.set_title.title,
                      let title = String(cString: cTitle, encoding: .utf8) else { return false }
                surfaceView.setTitle(title)

            case GHOSTTY_ACTION_PWD:
                guard let surfaceView = surfaceView(from: target) else { return false }
                guard let cPwd = action.action.pwd.pwd,
                      let pwd = String(cString: cPwd, encoding: .utf8) else { return false }
                surfaceView.pwd = pwd

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                guard let surfaceView = surfaceView(from: target) else { return false }
                surfaceView.setCursorShape(action.action.mouse_shape)

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                guard let surfaceView = surfaceView(from: target) else { return false }
                switch action.action.mouse_visibility {
                case GHOSTTY_MOUSE_VISIBLE:
                    surfaceView.setCursorVisibility(true)
                case GHOSTTY_MOUSE_HIDDEN:
                    surfaceView.setCursorVisibility(false)
                default:
                    return false
                }

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                guard let surfaceView = surfaceView(from: target) else { return false }
                let v = action.action.mouse_over_link
                guard v.len > 0, let url = v.url else {
                    surfaceView.hoverUrl = nil
                    return true
                }
                let buffer = Data(bytes: url, count: v.len)
                surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)

            case GHOSTTY_ACTION_CELL_SIZE:
                guard let surfaceView = surfaceView(from: target) else { return false }
                let v = action.action.cell_size
                let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
                DispatchQueue.main.async { [weak surfaceView] in
                    guard let surfaceView else { return }
                    surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
                }

            case GHOSTTY_ACTION_RENDERER_HEALTH:
                guard let surfaceView = surfaceView(from: target) else { return false }
                let health = action.action.renderer_health
                DispatchQueue.main.async { [weak surfaceView] in
                    surfaceView?.healthy = health == GHOSTTY_RENDERER_HEALTH_HEALTHY
                }

            case GHOSTTY_ACTION_OPEN_URL:
                return openURL(action.action.open_url)

            case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                // The child (the session server) exited. Instead of the stock
                // "Process exited" banner, report the exit to the host. Returning
                // true suppresses the in-terminal "press any key" message.
                guard let surfaceView = surfaceView(from: target) else { return false }
                DispatchQueue.main.async { surfaceView.notifyExit() }

            case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_QUIT:
                // Herd has one surface per host view: any close/quit request from
                // the core means "this terminal is done".
                if let surfaceView = surfaceView(from: target) {
                    DispatchQueue.main.async { surfaceView.notifyExit() }
                } else {
                    return false
                }

            default:
                return false
            }

            // If we reached here then we assume performed since all unknown actions
            // are captured in the switch and return false.
            return true
        }

        private static func openURL(
            _ v: ghostty_action_open_url_s
        ) -> Bool {
            let action = TerminalEngine.Action.OpenURL(c: v)

            // If the URL doesn't have a valid scheme we assume its a file path. The URL
            // initializer will gladly take invalid URLs (e.g. plain file paths) and turn
            // them into schema-less URLs, but these won't open properly in text editors.

            let url: URL
            if let candidate = URL(string: action.url), candidate.scheme != nil {
                url = candidate
            } else {
                // Expand ~ to the user's home directory so that file paths
                // like ~/Documents/file.txt resolve correctly.
                let expandedPath = NSString(string: action.url).standardizingPath
                url = URL(filePath: expandedPath)
            }

            switch action.kind {
            case .text:
                // Open with the default editor for the extension or just system text editor
                let editor = NSWorkspace.shared.urlForApplication(toOpen: url)
                if let textEditor = editor {
                    NSWorkspace.shared.open([url], withApplicationAt: textEditor, configuration: NSWorkspace.OpenConfiguration())
                    return true
                }

            case .html:
                // The extension will be HTML and we do the right thing automatically.
                break

            case .unknown:
                break
            }

            // Open with the default application for the URL
            NSWorkspace.shared.open(url)
            return true
        }
    }
}
