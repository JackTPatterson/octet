import AppKit
import SwiftUI

/// `/usage` (and `/cost`, `/context`, `/stats`) for any agent, drawn: how
/// full the context is and what fills it, the plan's allowance against an
/// even pace, what the conversation has cost, and the day's spend across
/// every conversation. One hue for amounts; amber and red, always with
/// words, only for "near the limit".
struct UsageCard: View {
    let report: UsageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if report.contextUsed != nil { context }
            if !report.windows.isEmpty { allowance }
            conversation
            if report.lastDay.contains(where: { $0 > 0 }) { lastDay }
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(report.summary)
    }

    private var header: some View {
        HStack(spacing: 8) {
            OctetIcon("clock", size: 13).foregroundStyle(Theme.textSecondary)
            Text("Usage").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            Text([report.agent, report.model, report.plan].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 4)
            Text(report.at, style: .time).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.summary, forType: .string)
            } label: { OctetIcon("doc.on.doc", size: 12) }
                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Copy as text")
        }
    }

    // MARK: - Context

    private var context: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Context")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageReport.tokens(report.contextUsed ?? 0))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                if let window = report.contextWindow, window > 0 {
                    Text("of \(UsageReport.tokens(window))").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                if let fraction = report.contextFraction {
                    LevelLabel(fraction: fraction, normal: "\(Int((fraction * 100).rounded()))% full",
                               high: "\(Int((fraction * 100).rounded()))% full · compacts soon",
                               critical: "\(Int((fraction * 100).rounded()))% full · nearly out")
                }
            }
            if let fraction = report.contextFraction {
                Meter(fraction: fraction).frame(height: 8)
            }
            if let tokens = report.tokens {
                let rows: [TokenBars.Row] = [
                    .init(label: "Read from cache", value: tokens.cacheRead),
                    .init(label: "Written to cache", value: tokens.cacheWrite),
                    .init(label: "New input", value: tokens.input),
                    .init(label: "Output", value: tokens.output),
                ]
                TokenBars(rows: rows.filter { $0.value > 0 })
            }
            if report.contextHistory.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("After each turn").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    Columns(values: report.contextHistory.map(Double.init), ceiling: report.contextWindow.map(Double.init)) { index, value in
                        "Turn \(index + 1) · \(UsageReport.tokens(Int(value)))"
                    }
                    .frame(height: 40)
                }
            }
        }
    }

    // MARK: - Allowance

    private var allowance: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Allowance")
            ForEach(report.windows, id: \.name) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(Self.windowTitle(window.name)).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 4)
                        LevelLabel(fraction: window.used, normal: "\(Int((window.used * 100).rounded()))%",
                                   high: "\(Int((window.used * 100).rounded()))% · getting close",
                                   critical: "\(Int((window.used * 100).rounded()))% · nearly out")
                    }
                    Meter(fraction: window.used, mark: UsageReport.expected(window, at: report.at)).frame(height: 8)
                    HStack(spacing: 6) {
                        if let reset = UsageReport.resetsIn(window.resetsAt, now: report.at) {
                            Text("Resets \(reset)")
                        }
                        if let pace = UsageReport.pace(window, at: report.at) {
                            Text("·")
                            Text(pace)
                        }
                    }
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
            }
            if report.windows.contains(where: { UsageReport.expected($0, at: report.at) != nil }) {
                Text("The tick marks where an even pace would be by now.")
                    .font(Theme.captionFont).foregroundStyle(Theme.textMuted)
            }
        }
    }

    static func windowTitle(_ name: String) -> String {
        switch name {
        case "5h": "5-hour window"
        case "7d": "Weekly"
        default:
            name.hasSuffix("d") || name.hasSuffix("h") ? name + " window" : name
        }
    }

    // MARK: - This conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("This conversation")
            HStack(spacing: 8) {
                if let cost = report.costUSD {
                    Tile(value: UsageLedger.money(cost), label: report.paysPerToken ? "spent" : "at API prices")
                }
                Tile(value: String(report.turns), label: report.turns == 1 ? "turn" : "turns")
                if let tokens = report.tokens {
                    Tile(value: UsageReport.tokens(tokens.output), label: "last reply's output")
                }
                if let started = report.startedAt {
                    Tile(value: Self.duration(report.at.timeIntervalSince(started)), label: "since it started")
                }
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / (24 * 60))d \(minutes % (24 * 60) / 60)h"
    }

    // MARK: - The day

    private var lastDay: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle("Last 24 hours, every conversation")
                Spacer()
                Text(UsageLedger.money(report.lastDay.reduce(0, +)) + " at API prices")
                    .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            }
            Columns(values: report.lastDay, ceiling: nil) { index, value in
                let hoursAgo = report.lastDay.count - index - 1
                return (hoursAgo == 0 ? "This hour" : "\(hoursAgo)h ago") + " · " + UsageLedger.money(value)
            }
            .frame(height: 44)
            HStack {
                Text("24h ago")
                Spacer()
                Text("now")
            }
            .font(Theme.captionFont).foregroundStyle(Theme.textMuted)
        }
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased()).font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
    }
}

/// A share of something as words, with amber or red and a mark past 70%
/// and 90%, so the level never rests on color alone.
private struct LevelLabel: View {
    let fraction: Double
    let normal: String
    let high: String
    let critical: String

    var body: some View {
        let level = UsageReport.level(fraction)
        HStack(spacing: 4) {
            if level != .normal {
                OctetIcon("exclamationmark.triangle.fill", size: 11).foregroundStyle(UsageMeter.color(fraction))
            }
            Text(level == .critical ? critical : level == .high ? high : normal)
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(level == .normal ? Theme.textSecondary : Theme.textPrimary)
        }
    }
}

/// A progress bar: a recessive track, a rounded fill in the accent (amber
/// or red near the limit), and an optional tick for where it "should" be.
private struct Meter: View {
    let fraction: Double
    var mark: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border.opacity(0.6))
                Capsule()
                    .fill(UsageMeter.color(fraction))
                    .frame(width: max(height, width * CGFloat(min(1, max(0, fraction)))))
                    .opacity(fraction > 0 ? 1 : 0)
                if let mark {
                    Rectangle()
                        .fill(Theme.textPrimary.opacity(0.75))
                        .frame(width: 2, height: height + 6)
                        .offset(x: max(0, min(width - 2, width * CGFloat(mark) - 1)))
                }
            }
            .frame(height: height)
        }
        .accessibilityHidden(true)
    }
}

/// Where the context's tokens went, as one bar each in the same hue.
private struct TokenBars: View {
    struct Row: Identifiable {
        let label: String
        let value: Int
        var id: String { label }
    }

    let rows: [Row]

    var body: some View {
        let top = Double(rows.map(\.value).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                let label = row.label, value = row.value
                HStack(spacing: 8) {
                    Text(label).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Theme.accent.opacity(0.85))
                            .frame(width: max(4, proxy.size.width * CGFloat(Double(value) / max(top, 1))), height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 10)
                    Text(UsageReport.tokens(value)).font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary).frame(width: 52, alignment: .trailing)
                }
            }
        }
    }
}

/// A row of thin columns, rounded at the top and anchored to the baseline,
/// each saying its value on hover.
private struct Columns: View {
    let values: [Double]
    /// The top of the scale, when there's a natural one (the context window).
    let ceiling: Double?
    let describe: (Int, Double) -> String
    @State private var hovered: Int?

    var body: some View {
        let top = max(ceiling ?? 0, values.max() ?? 0, 0.000_001)
        GeometryReader { proxy in
            let count = max(values.count, 1)
            let gap: CGFloat = 2
            let width = max(2, (proxy.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    let height = value > 0 ? max(2, proxy.size.height * CGFloat(value / top)) : 1
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        UnevenRoundedRectangle(topLeadingRadius: min(3, width / 2), topTrailingRadius: min(3, width / 2))
                            .fill(value > 0 ? (hovered == index ? Theme.accent : Theme.accent.opacity(0.7)) : Theme.border)
                            .frame(width: width, height: height)
                    }
                    .frame(width: width)
                    .contentShape(Rectangle())
                    .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
                    .help(describe(index, value))
                }
            }
            .overlay(alignment: .top) {
                if let hovered, values.indices.contains(hovered) {
                    Text(describe(hovered, values[hovered]))
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chrome))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
                        .offset(y: -22)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(values.enumerated().map { describe($0.offset, $0.element) }.joined(separator: ", "))
    }
}

private struct Tile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            Text(label).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(minWidth: 90, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
    }
}
