import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
enum AppWindows {
    static func openMain(using openWindow: OpenWindowAction) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    private static var lifecycleTestStarted = false

    // Opt-in native lifecycle check for development; no Accessibility permissions
    // or Apple Events needed. It exercises the same action as the menu item.
    static func startLifecycleTest(using openWindow: OpenWindowAction) {
        guard ProcessInfo.processInfo.environment["GIT_MANAGER_WINDOW_LIFECYCLE_TEST"] == "1",
              !lifecycleTestStarted else { return }
        lifecycleTestStarted = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }) else {
                fail("Main window did not open")
            }
            window.performClose(nil)
            try? await Task.sleep(for: .milliseconds(500))
            guard !window.isVisible else { fail("Main window did not close") }
            guard NSApp.windows.contains(where: { $0.level == .statusBar }) else {
                fail("Menu bar window disappeared after closing the main window")
            }
            openMain(using: openWindow)
            try? await Task.sleep(for: .milliseconds(500))
            guard NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) else {
                fail("Open Window did not reopen the main window")
            }
            print("WINDOW LIFECYCLE PASSED: closing kept the menu bar; Open Window reopened the main window")
            exit(0)
        }
    }

    private static func fail(_ reason: String) -> Never {
        print("WINDOW LIFECYCLE FAILED: \(reason)")
        exit(1)
    }
    #endif
}
