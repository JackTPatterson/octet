import AppKit
import SwiftUI

/// Adding a model from Hugging Face: search its GGUF repos or paste a link,
/// pick a quantization, and watch Ollama pull it. What's downloading, and
/// what finished, is listed below with each one's progress.
struct HuggingFaceModelView: View {
    /// The conversation that switches to the model once it's in; nil from
    /// the File menu, where it's just added to OpenCode's models.
    var session: AgentSession?
    /// Closes the sheet; nil in the window of its own.
    var close: (() -> Void)?
    @ObservedObject private var downloads = HuggingFaceDownloads.shared
    @StateObject private var search = HuggingFaceSearch()
    @State private var query = ""
    @State private var chosen: HuggingFaceModel.Reference?
    @State private var quantization: String?
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 0) {
                results.frame(width: 300)
                Rectangle().fill(Theme.divider).frame(width: 1)
                detail
            }
            .frame(maxHeight: .infinity)
            if !downloads.downloads.isEmpty {
                Rectangle().fill(Theme.divider).frame(height: 1)
                downloadsList
            }
        }
        .frame(width: 720, height: 620)
        .background(Theme.chrome)
        .onAppear {
            downloads.checkOllama()
            searching = true
            if search.results.isEmpty { search.update("") }
        }
        .onChange(of: query) { _, text in
            search.update(text)
            if let reference = HuggingFaceModel.parse(text) { choose(reference) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a model from Hugging Face").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("GGUF models run on this Mac through Ollama, and show up in OpenCode's model menu.")
                        .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                ollamaStatus
                if let close {
                    OctetButton(title: "Done", kind: .secondary, compact: true) { close() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            OctetTextField(placeholder: "Search Hugging Face, or paste a model link or hf.co/… name", text: $query) {
                if let chosen, quantization != nil { start(chosen) }
            }
            .focused($searching)
        }
        .padding(16)
    }

    @ViewBuilder
    private var ollamaStatus: some View {
        switch downloads.ollama {
        case .unknown:
            EmptyView()
        case .running(let version):
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Ollama" + (version.isEmpty ? "" : " \(version)")).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            .help("Ollama is running, and will pull and run the model")
        case .stopped(let installed):
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(installed ? "Ollama isn't running" : "Ollama isn't installed").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                if installed {
                    OctetButton(title: "Start", kind: .ghost, compact: true) { Task { _ = await downloads.startOllama() } }
                } else {
                    OctetButton(title: "Get Ollama", kind: .ghost, compact: true) {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                    }
                }
            }
            .help(installed ? "Ollama runs the model; Octet starts it when a download begins"
                            : "Ollama runs the model on this Mac; it's a free download from ollama.com")
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        let direct = HuggingFaceModel.parse(query)
        VStack(alignment: .leading, spacing: 0) {
            if let direct {
                RepoRow(repo: HuggingFaceModel.Repo(id: direct.repoId), selected: chosen?.repoId == direct.repoId) { choose(direct) }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
            if search.searching, search.results.isEmpty {
                LoadingLine(width: 40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = search.error, search.results.isEmpty {
                Text(error).font(Theme.uiFont).foregroundStyle(Theme.danger).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if search.results.isEmpty, direct == nil {
                Text(query.isEmpty ? "The most downloaded GGUF models" : "No GGUF models match \u{201C}\(query)\u{201D}")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if direct == nil {
                            Text(query.isEmpty ? "MOST DOWNLOADED" : "RESULTS")
                                .font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                        }
                        ForEach(search.results.filter { $0.id != direct?.repoId }) { repo in
                            RepoRow(repo: repo, selected: chosen?.repoId == repo.id) {
                                if let reference = repo.reference { choose(reference) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let chosen {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(HuggingFaceModel.Reference(owner: chosen.owner, repo: chosen.repo).displayName)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(chosen.repoId).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                        Button("Open on Hugging Face") { NSWorkspace.shared.open(chosen.pageURL) }
                            .buttonStyle(.plain).font(Theme.captionFont).foregroundStyle(Theme.accent)
                    }
                }
                Text("QUANTIZATION").font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
                if search.loadingQuantizations {
                    LoadingLine(width: 30)
                } else if let error = search.quantizationsError {
                    Text(error).font(Theme.uiFont).foregroundStyle(Theme.danger)
                } else if search.quantizations.isEmpty {
                    Text("This repo has no GGUF files, which Ollama needs. Look for a \u{201C}GGUF\u{201D} version of the model, often from bartowski, unsloth or TheBloke.")
                        .font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(search.quantizations) { option in
                                QuantizationRow(option: option, selected: quantization == option.name,
                                                suggested: option.name == HuggingFaceModel.defaultQuantization) {
                                    quantization = option.name
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Text("Smaller files are faster and need less memory; bigger ones answer better. Q4_K_M is the usual middle.")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    let picked = HuggingFaceModel.Reference(owner: chosen.owner, repo: chosen.repo, quantization: quantization)
                    let active = downloads.downloads.first { $0.reference == picked && $0.phase.isActive }
                    OctetButton(title: active != nil ? "Downloading…" : downloads.isDone(picked) ? "Download Again" : "Download",
                                icon: "square.and.arrow.down", kind: .primary) { start(picked) }
                        .disabled(quantization == nil || active != nil || search.loadingQuantizations)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                OctetIcon("square.and.arrow.down", size: 24).foregroundStyle(Theme.textTertiary)
                Text("Pick a model to see its downloads").font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                Text("Any Hugging Face link works too: paste the repo's page or a GGUF file's.")
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Downloads

    private var downloadsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DOWNLOADS").font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16).padding(.top, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(downloads.downloads) { download in
                        DownloadRow(download: download, session: session, use: { use(download) })
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: min(CGFloat(downloads.downloads.count) * 46 + 8, 150))
        }
    }

    // MARK: - Actions

    private func choose(_ reference: HuggingFaceModel.Reference) {
        guard chosen?.repoId != reference.repoId || (reference.quantization != nil && quantization != reference.quantization) else { return }
        chosen = reference
        quantization = reference.quantization
        search.loadQuantizations(reference.repoId) { options in
            guard chosen?.repoId == reference.repoId else { return }
            if quantization == nil || !options.contains(where: { $0.name == quantization }) {
                quantization = reference.quantization.flatMap { wanted in options.first { $0.name == wanted }?.name }
                    ?? HuggingFaceModel.suggested(options)
            }
        }
    }

    private func start(_ reference: HuggingFaceModel.Reference) {
        let session = session
        downloads.add(reference) { modelID in
            guard let session, session.engine == .opencode else { return }
            session.model = modelID
            session.effort = nil
            session.conversation.contextWindow = nil
        }
    }

    private func use(_ download: HuggingFaceDownloads.Download) {
        guard let session, session.engine == .opencode else { return }
        session.model = download.modelID
        session.effort = nil
        session.conversation.contextWindow = nil
        close?()
    }
}

/// Searching Hugging Face, and listing one repo's quantizations.
@MainActor
private final class HuggingFaceSearch: ObservableObject {
    @Published private(set) var results: [HuggingFaceModel.Repo] = []
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published private(set) var quantizations: [HuggingFaceModel.Quantization] = []
    @Published private(set) var loadingQuantizations = false
    @Published private(set) var quantizationsError: String?
    private var searchTask: Task<Void, Never>?
    private var quantizationTask: Task<Void, Never>?
    private var cache: [String: [HuggingFaceModel.Quantization]] = [:]

    /// Searches after a pause in typing; a pasted link isn't searched.
    func update(_ query: String) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard HuggingFaceModel.parse(text) == nil else { return }
        searching = true
        error = nil
        searchTask = Task { [weak self] in
            if !text.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: HuggingFaceModel.searchURL(text))
                let json = try JSONSerialization.jsonObject(with: data)
                guard !Task.isCancelled else { return }
                self?.results = HuggingFaceModel.repos(in: json)
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = "Couldn't reach Hugging Face: \(error.localizedDescription)"
            }
            self?.searching = false
        }
    }

    func loadQuantizations(_ repoId: String, done: @escaping @MainActor ([HuggingFaceModel.Quantization]) -> Void) {
        quantizationTask?.cancel()
        quantizationsError = nil
        if let cached = cache[repoId] {
            quantizations = cached
            loadingQuantizations = false
            done(cached)
            return
        }
        quantizations = []
        loadingQuantizations = true
        quantizationTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: HuggingFaceModel.repoURL(repoId))
                guard !Task.isCancelled else { return }
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    self?.quantizationsError = status == 404 ? "There's no \(repoId) on Hugging Face."
                        : status == 401 || status == 403 ? "\(repoId) is gated or private; Hugging Face won't list its files."
                        : "Hugging Face answered \(status)."
                } else {
                    let options = HuggingFaceModel.quantizations(in: try JSONSerialization.jsonObject(with: data))
                    self?.cache[repoId] = options
                    self?.quantizations = options
                    done(options)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.quantizationsError = "Couldn't reach Hugging Face: \(error.localizedDescription)"
            }
            self?.loadingQuantizations = false
        }
    }
}

private struct RepoRow: View {
    let repo: HuggingFaceModel.Repo
    let selected: Bool
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.reference.map { HuggingFaceModel.Reference(owner: $0.owner, repo: $0.repo).displayName } ?? repo.id)
                    .font(Theme.uiFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(repo.owner).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    if repo.downloads > 0 {
                        Text("\(Self.short(repo.downloads)) downloads").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    if repo.likes > 0 {
                        Text("\(Self.short(repo.likes)) likes").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(repo.id)
    }

    static func short(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}

private struct QuantizationRow: View {
    let option: HuggingFaceModel.Quantization
    let selected: Bool
    let suggested: Bool
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                OctetIcon("checkmark", size: 11).foregroundStyle(Theme.accent).opacity(selected ? 1 : 0).frame(width: 12)
                Text(option.name).font(Theme.monoFont).foregroundStyle(Theme.textPrimary)
                if suggested {
                    Text("recommended").font(Theme.captionFont).foregroundStyle(Theme.accent)
                }
                Spacer()
                Text(option.bytes > 0 ? ByteCountFormatter.string(fromByteCount: option.bytes, countStyle: .file) : "")
                    .font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// One download: its name, what's happening, and a bar while it pulls.
private struct DownloadRow: View {
    let download: HuggingFaceDownloads.Download
    let session: AgentSession?
    let use: () -> Void
    @ObservedObject private var downloads = HuggingFaceDownloads.shared

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(download.reference.displayName).font(Theme.uiFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(download.phase.text)
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(color)
                        .lineLimit(1).truncationMode(.middle)
                }
                if download.phase.isActive {
                    if let fraction = download.phase.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small).tint(Theme.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small).tint(Theme.accent)
                    }
                }
            }
            switch download.phase {
            case .waiting, .checking, .pulling, .registering:
                OctetButton(title: "Cancel", kind: .ghost, compact: true) { downloads.cancel(download.id) }
            case .failed:
                OctetButton(title: "Retry", kind: .ghost, compact: true) { downloads.retry(download.id) }
                OctetButton(title: "Remove", kind: .ghost, compact: true) { downloads.remove(download.id) }
            case .cancelled:
                OctetButton(title: "Retry", kind: .ghost, compact: true) { downloads.retry(download.id) }
                OctetButton(title: "Remove", kind: .ghost, compact: true) { downloads.remove(download.id) }
            case .done:
                if session?.engine == .opencode {
                    OctetButton(title: session?.model == download.modelID ? "In Use" : "Use", kind: .secondary, compact: true, action: use)
                        .disabled(session?.model == download.modelID)
                }
                OctetButton(title: "Remove", kind: .ghost, compact: true) { downloads.remove(download.id) }
                    .help("Takes it off this list; the model stays in Ollama and OpenCode")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(download.reference.displayName), \(download.phase.text)")
    }

    private var color: Color {
        switch download.phase {
        case .failed: Theme.danger
        case .done: Color.green
        default: Theme.textTertiary
        }
    }
}
