import AppKit
import SwiftUI

@main
struct HermesDesktopApp: App {
    @NSApplicationDelegateAdaptor(HermesApplicationDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Hermes Desktop") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: HermesSplitMetrics.minimumWindowWidth, minHeight: 520)
                .background(
                    HermesWindowTitleBarConfigurator(
                        backgroundImageActive: appState.connectionStore.isBackgroundImageActive,
                        windowOpacity: appState.connectionStore.windowOpacity,
                        windowMaterial: appState.connectionStore.windowMaterial
                    )
                )
                .onAppear {
                    // Provide the delegate with the fully-initialised AppState so the
                    // control server can reference the shared stores.  We use onAppear
                    // rather than applicationDidFinishLaunching because @StateObject is
                    // only guaranteed to be alive once the first view renders.
                    appDelegate.appState = appState
                    spawnControlServer(
                        connectionStore: appState.connectionStore,
                        sshTransport: appState.sshTransport,
                        terminalWorkspace: appState.terminalWorkspace
                    )
                }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            HermesDesktopCommands(appState: appState)
        }
    }
}
