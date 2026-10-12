import AppKit

// `@main` does not wire NSApp.delegate without a nib, so the entry point lives here.
let app = NSApplication.shared

// A top-level global: NSApplication.delegate is weak, so the delegate must be owned for the app's lifetime.
let delegate: NSApplicationDelegate = {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        // Running under XCTest: a minimal delegate avoids launching the full UI
        class TestAppDelegate: NSObject, NSApplicationDelegate {}
        return TestAppDelegate()
    }
    return MainActor.assumeIsolated { AppDelegate() }
}()

app.delegate = delegate
app.run()
