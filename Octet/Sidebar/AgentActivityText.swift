import SwiftUI

/// Phases come from actual stream events. Reduced motion swaps the text instantly.
struct AgentActivityText: View {
    let text: String
    @ObservedObject private var motion = MotionPreferences.shared
    var body: some View {
        ZStack(alignment: .leading) {
            Text(text).id(text)
                .transition(motion.animates(.agentStatus)
                    ? .asymmetric(insertion: .modifier(active: ActivityPhaseShift(offset: 6, blur: 3, opacity: 0),
                                                       identity: ActivityPhaseShift(offset: 0, blur: 0, opacity: 1)),
                                  removal: .modifier(active: ActivityPhaseShift(offset: -6, blur: 3, opacity: 0),
                                                     identity: ActivityPhaseShift(offset: 0, blur: 0, opacity: 1))) : .identity)
        }
        .animation(motion.animation(.agentStatus, .easeInOut(duration: 0.22)), value: text)
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

private struct ActivityPhaseShift: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double
    func body(content: Content) -> some View { content.offset(y: offset).blur(radius: blur).opacity(opacity) }
}
