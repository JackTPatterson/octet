import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Holds an idle-sleep assertion while any agent is working, as
/// `KeepAwake` decides. The display may still sleep; the Mac doesn't, so
/// the work carries on. Closed tabs still running count too: they're
/// working, just out of sight.
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()

    private var assertion: IOPMAssertionID = 0
    private var heldReason: String?
    private var statuses: [EngineAgentStatus] = []
    private var powerSource: CFRunLoopSource?

    private init() {
        // Plugging in or unplugging changes the answer for `.pluggedIn`
        // without any agent changing state.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let guardian = Unmanaged<SleepGuard>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { guardian.update() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    /// The whole snapshot, holding workspace included.
    func observe(_ snapshot: EngineSnapshot) {
        let statuses = snapshot.agents.map(\.agentStatus)
        guard statuses != self.statuses else { return }
        self.statuses = statuses
        update()
    }

    /// Re-reads the setting; called when it changes.
    func update() {
        let reason = KeepAwake.reason(mode: SettingsStore.shared.values.keepAwake,
                                      statuses: statuses, onBattery: Self.onBattery())
        guard reason != heldReason else { return }
        release()
        guard let reason else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &id)
        guard result == kIOReturnSuccess else { return }
        assertion = id
        heldReason = reason
    }

    /// Whether the Mac is being kept awake right now.
    var isHolding: Bool { heldReason != nil }

    private func release() {
        if heldReason != nil { IOPMAssertionRelease(assertion) }
        assertion = 0
        heldReason = nil
    }

    private static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
