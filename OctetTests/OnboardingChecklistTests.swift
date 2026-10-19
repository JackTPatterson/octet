import XCTest
import SwiftUI
@testable import Octet

@MainActor
final class OnboardingChecklistTests: XCTestCase {
    func testProgressPersistsAndUnknownStepsAreIgnored() throws {
        let name = "onboarding-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["old-step", "project"], forKey: OnboardingChecklistStore.key)
        let store = OnboardingChecklistStore(defaults: defaults)
        XCTAssertEqual(store.completed, ["project"])
        XCTAssertEqual(store.progress, 0.2, accuracy: 0.001)
        store.set(.agent, complete: true)
        let restored = OnboardingChecklistStore(defaults: defaults)
        XCTAssertEqual(restored.completed, ["project", "agent"])
        restored.set(.project, complete: false)
        XCTAssertEqual(restored.completed, ["agent"])
    }

    func testChecklistRowRendersWithoutChangingProgress() throws {
        let name = "onboarding-view-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let checklist = OnboardingChecklistStore(defaults: defaults)
        checklist.set(.project, complete: true)
        let session = SessionStore(client: Octet.EngineClient(socketPath: "/tmp/octet-onboarding-unused.sock"))
        let context = WindowContext(spec: OctetWindowSpec(), store: session)
        let host = NSHostingView(rootView: OnboardingChecklistRow(checklist: checklist, openProject: {})
            .environmentObject(context).padding(8).frame(width: 260).background(Theme.sidebar))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 46)
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/octet-onboarding-row.png"))
        XCTAssertEqual(checklist.completed, ["project"])
    }
}
