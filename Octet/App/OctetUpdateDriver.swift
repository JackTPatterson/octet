import AppKit
import Sparkle
import SwiftUI

/// Sparkle's user interface, in Octet's own style for the parts people look
/// at: checking, "Octet X is available" with its release notes, the
/// download, and ready to install, all in one glass card.
///
/// Why a user driver of our own rather than styling Sparkle's window: the
/// standard window renders release notes in a web view, which with no
/// stylesheet of ours read as raw text on a black page, and its layout can't
/// be changed. SPUUserDriver is Sparkle's public seam for exactly this. The
/// rarer prompts (permission to check automatically, "you're up to date",
/// errors, "installed") still go to Sparkle's SPUStandardUserDriver, which
/// this wraps, so nothing Sparkle can ask goes unanswered. Every `reply` and
/// `cancellation` Sparkle hands over is called exactly once (or dropped when
/// Sparkle dismisses the session itself).
@MainActor
final class OctetUpdateDriver: NSObject {
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    private let model = UpdatePromptModel()
    private var window: UpdatePromptWindow?
    /// The choice Sparkle is waiting on, for the found and ready stages.
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    /// Stops a check or a download in progress.
    private var cancellation: (() -> Void)?
    /// Asks the app to quit again, when something held up the install.
    private var retryTerminating: (() -> Void)?

    override init() {
        super.init()
        model.act = { [weak self] action in self?.perform(action) }
    }

    private func perform(_ action: UpdatePromptModel.Action) {
        switch action {
        case .install:
            if model.stage == .installing {
                retryTerminating?()
                return
            }
            answer(.install)
        case .later:
            answer(.dismiss)
            close()
        case .skip:
            AppUpdateStatus.shared.version = nil
            answer(.skip)
            close()
        case .cancel:
            let cancel = cancellation
            cancellation = nil
            close()
            cancel?()
        }
    }

    private func answer(_ choice: SPUUserUpdateChoice) {
        let pending = reply
        reply = nil
        pending?(choice)
    }

    private func present(focus: Bool) {
        if window == nil { window = UpdatePromptWindow(model: model) }
        guard let window else { return }
        if !window.isVisible { window.center() }
        if focus { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }

    /// Hands the session to Sparkle's own window for a prompt Octet doesn't
    /// draw, after putting away Octet's card.
    private func handOff() {
        close()
        cancellation = nil
        reply = nil
    }

    // MARK: - Preview

    #if DEBUG
    private static var preview: OctetUpdateDriver?

    /// Verification hook (OCTET_OPEN_WINDOW=update-preview, or
    /// "update-preview:downloading" / ":ready" / ":checking"): the dialog
    /// with sample data and no Sparkle session behind it. Its buttons just
    /// move it through the stages and close it.
    static func showPreview(stage: String?) {
        let driver = OctetUpdateDriver()
        preview = driver
        let model = driver.model
        model.newVersion = "0.2.0"
        model.currentVersion = "0.1.0 (19)"
        model.date = Date().addingTimeInterval(-3 * 3600)
        model.notes = ReleaseNotes.markdown(fromHTML: """
        <h2>Highlights</h2>
        <ul>
          <li>A calmer <strong>status bar</strong>: quiet items that open the plane they're about.</li>
          <li>This update dialog, in Octet's own style.</li>
          <li>Ports show as <code>localhost:3000</code> with what serves them.</li>
        </ul>
        <h3>Fixes</h3>
        <ul>
          <li>Split borders are quiet hairlines instead of near-white.</li>
          <li>The Browser plane opens a dev server straight from the footer.</li>
        </ul>
        <p>See <a href="https://github.com/JackTPatterson/octet">the repository</a> for everything else.</p>
        """)
        switch stage {
        case "checking": model.stage = .checking
        case "downloading": model.stage = .downloading(received: 9_400_000, expected: 24_929_470)
        case "ready": model.stage = .readyToInstall
        default: model.stage = .found
        }
        model.act = { action in
            switch (action, model.stage) {
            case (.install, .found): model.stage = .downloading(received: 9_400_000, expected: 24_929_470)
            case (.install, .downloading): model.stage = .readyToInstall
            case (.install, .readyToInstall): model.stage = .installing
            default:
                driver.close()
                preview = nil
            }
        }
        driver.present(focus: false)
    }
    #endif
}

extension OctetUpdateDriver: @preconcurrency SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        reply = nil
        model.reset(stage: .checking)
        present(focus: true)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // An update that only points at a web page has nothing to install;
        // Sparkle's own prompt (with its "Learn More") handles that.
        if appcastItem.isInformationOnlyUpdate {
            handOff()
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }
        cancellation = nil
        self.reply = reply
        let bundle = Bundle.main
        let currentDisplay = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        model.reset(stage: .found)
        model.newVersion = ReleaseNotes.versionLabel(display: appcastItem.displayVersionString,
                                                     build: appcastItem.versionString, comparedTo: currentDisplay)
        model.currentVersion = ReleaseNotes.versionLabel(display: currentDisplay, build: currentBuild,
                                                         comparedTo: appcastItem.displayVersionString)
        model.date = appcastItem.date
        AppUpdateStatus.shared.version = appcastItem.displayVersionString
        model.critical = appcastItem.isCriticalUpdate
        model.downloaded = state.stage != .notDownloaded
        if let description = appcastItem.itemDescription, !description.isEmpty {
            model.notes = ReleaseNotes.markdown(description, format: appcastItem.itemDescriptionFormat)
        } else if appcastItem.releaseNotesURL != nil {
            // Sparkle fetches it and calls back with the page.
            model.notesLoading = true
        }
        present(focus: state.userInitiated)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let encoding = downloadData.textEncodingName
            .map { CFStringConvertIANACharSetNameToEncoding($0 as CFString) }
            .flatMap { $0 == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding($0)) }
            ?? .utf8
        let text = String(data: downloadData.data, encoding: encoding) ?? String(decoding: downloadData.data, as: UTF8.self)
        let path = downloadData.url.pathExtension.lowercased()
        let format = ["md", "markdown"].contains(path) ? "markdown" : path == "txt" ? "plain-text" : downloadData.mimeType
        model.notes = ReleaseNotes.markdown(text, format: format)
        model.notesLoading = false
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        model.notesLoading = false
        model.notesFailed = true
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        handOff()
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        handOff()
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        model.stage = .downloading(received: 0, expected: 0)
        present(focus: false)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        model.stage = .downloading(received: 0, expected: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if case .downloading(let received, let expected) = model.stage {
            model.stage = .downloading(received: received + length, expected: expected)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        model.stage = .extracting(0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.stage = .extracting(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.reply = reply
        model.stage = .readyToInstall
        present(focus: false)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        retryTerminating = applicationTerminated ? nil : retryTerminatingApplication
        model.stage = .installing
        model.canRetryTerminating = !applicationTerminated
        present(focus: false)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        AppUpdateStatus.shared.version = nil
        handOff()
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            (standard as SPUUserDriver).showUpdateInFocus?()
        }
    }

    func dismissUpdateInstallation() {
        handOff()
        retryTerminating = nil
        standard.dismissUpdateInstallation()
    }
}

// MARK: - Model

/// What the update card shows, and the buttons' way back to the driver.
@MainActor
final class UpdatePromptModel: ObservableObject {
    enum Stage: Equatable {
        case checking
        case found
        case downloading(received: UInt64, expected: UInt64)
        case extracting(Double)
        case readyToInstall
        case installing
    }

    enum Action { case install, later, skip, cancel }

    @Published var stage: Stage = .checking
    @Published var newVersion = ""
    @Published var currentVersion = ""
    @Published var date: Date?
    /// Release notes as Markdown, once known.
    @Published var notes: String?
    @Published var notesLoading = false
    @Published var notesFailed = false
    /// A critical update can't be skipped.
    @Published var critical = false
    /// Already downloaded in the background: installing is immediate.
    @Published var downloaded = false
    @Published var canRetryTerminating = false
    var act: (Action) -> Void = { _ in }

    func reset(stage: Stage) {
        self.stage = stage
        newVersion = ""
        currentVersion = ""
        date = nil
        notes = nil
        notesLoading = false
        notesFailed = false
        critical = false
        downloaded = false
        canRetryTerminating = false
    }
}

// MARK: - Window

/// A borderless window holding just the glass card, so it looks like one of
/// Octet's dialogs rather than a system panel. Borderless windows won't
/// become key on their own, which the buttons' Return and Escape need.
private final class UpdatePromptWindow: NSWindow {
    init(model: UpdatePromptModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 540, height: 200),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: UpdatePromptView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
        // Named for DebugSnapshot's window-<title>.png and for VoiceOver.
        title = "Software Update"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

private struct UpdatePromptView: View {
    @ObservedObject var model: UpdatePromptModel

    var body: some View {
        Group {
            if model.stage == .checking {
                checking
            } else {
                card
            }
        }
        .octetGlass(cornerRadius: Theme.Radius.sheet, fill: Theme.card)
        .environment(\.colorScheme, Theme.colorScheme)
    }

    private var checking: some View {
        HStack(spacing: 12) {
            appIcon(size: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text("Checking for updates…")
                    .font(Theme.interfaceFont(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                LoadingLine(width: 120)
            }
            Spacer(minLength: 16)
            OctetButton(title: "Cancel", kind: .secondary) { model.act(.cancel) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .frame(width: 380)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            notes
            if let progress { progressRow(progress) }
            buttons
        }
        .padding(20)
        .frame(width: 540)
    }

    private var title: String {
        switch model.stage {
        case .readyToInstall: "Octet \(model.newVersion) is ready to install"
        case .installing: "Installing Octet \(model.newVersion)…"
        default: "Octet \(model.newVersion) is available"
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            appIcon(size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.interfaceFont(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    VersionTag(label: model.currentVersion, current: true)
                    OctetIcon("arrow.right", size: 11).foregroundStyle(Theme.textTertiary)
                    VersionTag(label: model.newVersion, current: false)
                    if let date = model.date {
                        Text("Released " + date.formatted(.relative(presentation: .named)))
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 4)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's new")
                .font(Theme.headerFont)
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
            Group {
                if let notes = model.notes, !notes.isEmpty {
                    ScrollView {
                        MarkdownView(text: notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(height: 240)
                } else {
                    HStack(spacing: 8) {
                        if model.notesLoading { LoadingLine(width: 40) }
                        Text(model.notesLoading ? "Loading release notes…"
                             : model.notesFailed ? "The release notes couldn't be loaded."
                             : "No release notes for this version.")
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).fill(Theme.terminalBackground.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    /// Download progress (0...1, nil while its size is unknown) and a line
    /// saying what's happening.
    private var progress: (value: Double?, label: String)? {
        switch model.stage {
        case .downloading(let received, let expected):
            guard expected > 0 else { return (nil, "Downloading…") }
            let of = ByteCountFormatter.string(fromByteCount: Int64(expected), countStyle: .file)
            let done = ByteCountFormatter.string(fromByteCount: Int64(min(received, expected)), countStyle: .file)
            return (Double(received) / Double(expected), "Downloading \(done) of \(of)")
        case .extracting(let value): return (value, "Preparing the update…")
        case .installing: return (nil, model.canRetryTerminating ? "Waiting for Octet to quit…" : "Installing…")
        default: return nil
        }
    }

    private func progressRow(_ progress: (value: Double?, label: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value = progress.value {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hover)
                        Capsule().fill(Theme.accent).frame(width: max(4, proxy.size.width * min(1, value)))
                    }
                }
                .frame(height: 4)
            } else {
                LoadingLine(width: 120)
            }
            Text(progress.label)
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            switch model.stage {
            case .found:
                if !model.critical {
                    OctetButton(title: "Skip This Version", kind: .ghost) { model.act(.skip) }
                }
                Spacer()
                OctetButton(title: "Remind Me Later", kind: .secondary) { model.act(.later) }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: "Install and Relaunch", kind: .primary) { model.act(.install) }
                    .keyboardShortcut(.defaultAction)
            case .downloading:
                Spacer()
                OctetButton(title: "Cancel", kind: .secondary) { model.act(.cancel) }
                    .keyboardShortcut(.cancelAction)
            case .readyToInstall:
                Spacer()
                // Sparkle installs it when Octet next quits.
                OctetButton(title: "Install on Quit", kind: .secondary) { model.act(.later) }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: "Install and Relaunch", kind: .primary) { model.act(.install) }
                    .keyboardShortcut(.defaultAction)
            case .installing where model.canRetryTerminating:
                Spacer()
                OctetButton(title: "Quit and Install", kind: .primary) { model.act(.install) }
                    .keyboardShortcut(.defaultAction)
            default:
                EmptyView()
            }
        }
    }

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A version in a small rounded tag: the one installed quiet, the new one
/// in the accent colour.
struct VersionTag: View {
    let label: String
    let current: Bool

    var body: some View {
        Text(label)
            .font(Theme.monoFont.monospacedDigit())
            .foregroundStyle(current ? Theme.textSecondary : Theme.accent)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(current ? Theme.hover : Theme.accent.opacity(0.14)))
            .help(current ? "Installed" : "New")
    }
}
