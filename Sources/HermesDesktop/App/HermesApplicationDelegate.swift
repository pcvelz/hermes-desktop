import AppKit

@MainActor
final class HermesApplicationDelegate: NSObject, NSApplicationDelegate {
    // Holds a reference to AppState so it can be inspected from outside the
    // SwiftUI scene (e.g. control server startup).  Set by HermesDesktopApp
    // on first .onAppear, before spawnControlServer is called.
    var appState: AppState?

    func applicationDidFinishLaunching(_ _: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        // NOTE: the control server is spawned from HermesDesktopApp.onAppear
        // so that AppState is fully initialised before we start accepting requests.
    }
}
