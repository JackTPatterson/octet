import SwiftUI

@MainActor
final class OnboardingChecklistStore: ObservableObject {
    static let shared = OnboardingChecklistStore()
    private let defaults: UserDefaults
    static let key = "octet.onboarding.checklist.v1"
    @Published private(set) var completed: Set<String>
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completed = OnboardingChecklistStep.valid(defaults.stringArray(forKey: Self.key) ?? [])
    }
    func set(_ step: OnboardingChecklistStep, complete: Bool) {
        if complete { completed.insert(step.rawValue) } else { completed.remove(step.rawValue) }
        defaults.set(completed.sorted(), forKey: Self.key)
    }
    var progress: Double { Double(completed.count) / Double(OnboardingChecklistStep.allCases.count) }
}

struct OnboardingChecklistRow: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var checklist: OnboardingChecklistStore = .shared
    let openProject: () -> Void
    @State private var showing = false
    @State private var hovered = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Theme.textTertiary.opacity(0.3), lineWidth: 2)
                    Circle().trim(from: 0, to: checklist.progress)
                        .stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 14, height: 14).frame(width: 18)
                Text("Onboarding checklist").font(Theme.uiFont).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 6).padding(.trailing, 4)
            .frame(height: 30).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered || showing ? Theme.hover : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Getting started · \(checklist.completed.count) of \(OnboardingChecklistStep.allCases.count) complete")
        .accessibilityLabel("Onboarding checklist")
        .accessibilityValue("\(checklist.completed.count) of \(OnboardingChecklistStep.allCases.count) complete")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Getting started").font(Theme.uiFontMedium)
                    Spacer()
                    Text("\(checklist.completed.count) of \(OnboardingChecklistStep.allCases.count)").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
                Text("Open each step, then check it off when you’re ready.").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                ForEach(OnboardingChecklistStep.allCases) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(step.title, isOn: Binding(get: { checklist.completed.contains(step.rawValue) }, set: { checklist.set(step, complete: $0) }))
                            .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Completed: " + step.title)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).font(Theme.uiFontMedium)
                            Text(step.detail).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 4)
                        OctetButton(title: "Open", kind: .ghost, compact: true) { open(step) }
                    }
                }
            }.padding(18).frame(width: 350).foregroundStyle(Theme.textPrimary).background(Theme.chrome)
        }
    }

    private func open(_ step: OnboardingChecklistStep) {
        showing = false
        switch step {
        case .project: openProject()
        case .agent, .notifications: SettingsOpener.open(.agents)
        case .appearance: SettingsOpener.open(.appearance)
        case .issues: window.ui.showPlane(.tickets)
        }
    }
}
