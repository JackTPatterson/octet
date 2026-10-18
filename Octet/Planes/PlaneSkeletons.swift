import SwiftUI

/// DEBUG previews keep the loading content visible without changing model data.
enum PlaneLoadingPreview {
    static func shows(_ kind: String) -> Bool {
        #if DEBUG
        let aliases = ["pullRequest": "pr", "pullRequests": "prs"]
        let value = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"]
        return value == "planes:\(kind):loading" || value == "planes:\(aliases[kind] ?? kind):loading"
        #else
        return false
        #endif
    }
}

struct PlaneSkeletonRow: View {
    var width: CGFloat = 140
    var height: CGFloat = 32
    var detail = false

    var body: some View {
        HStack(spacing: 10) {
            SkeletonCircle(size: 14)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonBlock(width: width, height: 12)
                if detail { SkeletonBlock(width: width * 0.7, height: 10) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct FilesPlaneSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<12, id: \.self) { row in
                PlaneSkeletonRow(width: CGFloat(80 + row % 4 * 20), height: 26)
                    .padding(.leading, 22 + CGFloat([0, 1, 2, 2, 1, 2, 0, 1, 1, 2, 2, 0][row]) * 14)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Reading files")
    }
}

struct DiffPlaneSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<2, id: \.self) { _ in
                PlaneSkeletonRow(width: 180, height: 36).padding(.horizontal, 12)
                SkeletonBlock(width: 160, height: 10).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.card)
                ForEach(0..<7, id: \.self) { line in
                    HStack(spacing: 12) {
                        SkeletonBlock(width: 24, height: 9)
                        SkeletonBlock(width: CGFloat(100 + line % 4 * 26), height: 10)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 20)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityLabel("Loading changes")
    }
}

struct GitPanelSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlaneSkeletonRow(width: 160, detail: true)
            HStack(spacing: 6) {
                SkeletonBlock(width: 80, height: 24)
                SkeletonBlock(width: 80, height: 24)
            }
            ForEach(0..<4, id: \.self) { row in
                PlaneSkeletonRow(width: CGFloat(110 + row % 3 * 25), height: 28)
            }
            SkeletonBlock(height: 60, radius: Theme.controlRadius)
            SkeletonBlock(width: 90, height: 11).padding(.top, 8)
            ForEach(0..<3, id: \.self) { _ in
                PlaneSkeletonRow(width: 170, height: 44, detail: true)
            }
        }
        .accessibilityLabel("Loading repository")
    }
}

struct PullRequestListSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<6, id: \.self) { row in
                PlaneSkeletonRow(width: CGFloat(170 + row % 3 * 20), height: 44, detail: true)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Loading pull requests")
    }
}

struct DeviceListSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 2) {
                    SkeletonBlock(width: 110, height: 11).padding(.bottom, 4)
                    ForEach(0..<3, id: \.self) { row in
                        HStack {
                            PlaneSkeletonRow(width: CGFloat(120 + row * 15), height: 40, detail: true)
                            SkeletonBlock(width: 48, height: 24)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .accessibilityLabel("Loading devices")
    }
}

struct TerminalPlaneSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(width: 180, height: 12)
            HStack(spacing: 8) {
                SkeletonBlock(width: 12, height: 12)
                SkeletonBlock(width: 80, height: 12)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.terminalBackground)
        .accessibilityLabel("Starting terminal")
    }
}

struct BrowserPlaneSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SkeletonBlock(width: 180, height: 22)
            SkeletonBlock(height: 12)
            SkeletonBlock(width: 220, height: 12)
            SkeletonBlock(height: 160, radius: Theme.controlRadius)
            ForEach(0..<3, id: \.self) { _ in SkeletonBlock(height: 12) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
        .accessibilityLabel("Loading page")
    }
}
