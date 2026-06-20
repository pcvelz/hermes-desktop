import AppKit
import Foundation

@MainActor
final class TerminalSession: ObservableObject, @unchecked Sendable {
    let connection: ConnectionProfile
    let processLaunch: ProcessLaunch
    let startupInput: String?
    let startupCommandLine: String?
    let exitAfterStartupCommand: Bool
    let workflowLaunchDiagnosticsContext: WorkflowLaunchDiagnosticsContext?
    private let workflowLaunchDiagnostics: WorkflowLaunchDiagnostics
    private let viewHost = TerminalViewHost()

    @Published var terminalTitle: String
    @Published var currentDirectory: String?
    @Published var exitCode: Int32?
    @Published var didStart = false
    @Published private(set) var launchToken = UUID()
    @Published private(set) var isRunning = false

    init(
        connection: ConnectionProfile,
        sshTransport: SSHTransport,
        terminalTheme: TerminalThemePreference = .defaultValue,
        startupCommandLine: String? = nil,
        exitAfterStartupCommand: Bool = false,
        startupInput: String? = nil,
        workflowLaunchDiagnostics: WorkflowLaunchDiagnostics,
        workflowLaunchDiagnosticsContext: WorkflowLaunchDiagnosticsContext? = nil
    ) {
        self.connection = connection
        self.startupInput = startupInput
        self.startupCommandLine = startupCommandLine
        self.exitAfterStartupCommand = exitAfterStartupCommand
        self.workflowLaunchDiagnostics = workflowLaunchDiagnostics
        self.workflowLaunchDiagnosticsContext = workflowLaunchDiagnosticsContext

        if connection.isLocal {
            // Local PTY: a `$SHELL` login shell carrying our full Hermes-aware
            // environment (HERMES_HOME, search PATH, offline-STT, TUI knobs, theme).
            // This keeps our local-transport / exit-after-startup / no-click-open /
            // theme-injection patches rather than upstream's bare `/bin/sh -c`
            // bootstrap, while still flowing through upstream's unified ProcessLaunch.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            self.processLaunch = ProcessLaunch(
                executablePath: shell,
                arguments: TerminalSession.localShellArguments(
                    shell: shell,
                    startupCommandLine: startupCommandLine,
                    exitAfterStartupCommand: exitAfterStartupCommand
                ),
                executableName: (shell as NSString).lastPathComponent,
                environment: TerminalSession.buildLocalEnvironment(
                    hermesHomeExpression: connection.remoteHermesHomeShellExpression,
                    searchPathExpression: connection.remoteHermesSearchPathShellExpression,
                    terminalTheme: terminalTheme
                )
            )
        } else {
            self.processLaunch = sshTransport.terminalLaunch(
                for: connection,
                startupCommandLine: startupCommandLine
            )
        }

        self.terminalTitle = "\(connection.label) · \(connection.resolvedHermesProfileName)"
        viewHost.setEventHandlers(
            onProcessStart: { [weak self] in
                self?.markStarted()
            },
            onTitleChange: { [weak self] title in
                self?.updateTitle(title)
            },
            onDirectoryChange: { [weak self] directory in
                self?.currentDirectory = directory
            },
            onProcessExit: { [weak self] exitCode in
                self?.markExited(exitCode)
            }
        )
    }

    deinit {
        viewHost.terminate()
    }

    func markStarted() {
        didStart = true
        isRunning = true
        exitCode = nil
    }

    func updateTitle(_ title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        terminalTitle = title
    }

    func markExited(_ code: Int32?) {
        isRunning = false
        exitCode = code
        if let workflowLaunchDiagnosticsContext {
            Task {
                await workflowLaunchDiagnostics.recordTerminalProcessExited(
                    workflowLaunchDiagnosticsContext,
                    exitCode: code
                )
            }
        }
    }

    func requestReconnect() {
        currentDirectory = nil
        exitCode = nil
        launchToken = UUID()
    }

    func mount(
        in container: TerminalMountContainerView,
        appearance: TerminalThemeAppearance,
        fontSize: Double,
        fontFamily: TerminalFontFamilyPreference,
        isActive: Bool,
        backgroundImageActive: Bool
    ) {
        viewHost.mount(
            in: container,
            request: makeLaunchRequest(),
            appearance: appearance,
            fontSize: fontSize,
            fontFamily: fontFamily,
            isActive: isActive,
            backgroundImageActive: backgroundImageActive
        )
    }

    /// Start the underlying PTY process immediately, without waiting for the SwiftUI
    /// layer to render a visible tab.  Used by the control server so a session spawned
    /// via the API gets a live shell right away and can capture output / accept writes.
    func startHeadless() {
        viewHost.startHeadless(request: makeLaunchRequest())
    }

    private func makeLaunchRequest() -> TerminalLaunchRequest {
        TerminalLaunchRequest(
            processLaunch: processLaunch,
            launchToken: launchToken,
            initialInput: startupInput,
            workflowLaunchDiagnostics: workflowLaunchDiagnostics,
            workflowLaunchDiagnosticsContext: workflowLaunchDiagnosticsContext
        )
    }

    /// Login-shell arguments for a local PTY. Mirrors the SSH `remoteShellBootstrapCommand`
    /// behaviour but preserves our exit-after-startup patch: when `exitAfterStartupCommand`
    /// is set the shell runs the startup command and exits (so `isRunning` tracks the Hermes
    /// TUI), otherwise it exec's a persistent login shell afterwards.
    private static func localShellArguments(
        shell: String,
        startupCommandLine: String?,
        exitAfterStartupCommand: Bool
    ) -> [String] {
        if let startup = startupCommandLine,
           !startup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if exitAfterStartupCommand {
                return ["-lc", startup]
            }
            return ["-lc", "\(startup); exec \(shell) -l"]
        }
        return ["-l"]
    }

    func unmount(from container: TerminalMountContainerView) {
        viewHost.unmount(from: container)
    }

    func stop() {
        viewHost.terminate()
        isRunning = false
        currentDirectory = nil
    }

    /// Send raw input bytes to the running PTY (used by the control server's
    /// POST /terminal/session/{id}/write endpoint).
    func sendInput(_ text: String) {
        viewHost.send(text: text)
    }

    /// Install a raw-bytes callback so every PTY output chunk is forwarded to `handler`.
    /// Called by the control server immediately after spawning a control-owned session so
    /// the GET /terminal/session/{id}/output buffer is populated with live data.
    func installOutputCapture(_ handler: ((ArraySlice<UInt8>) -> Void)?) {
        viewHost.setDataReceivedCallback(handler)
    }

    /// Resize the terminal emulator before the PTY is spawned so the shell opens at the
    /// requested dimensions.  Call before `startHeadless()`.
    func resize(cols: Int, rows: Int) {
        viewHost.resizeTerminal(cols: cols, rows: rows)
    }

    // MARK: - Local environment builder

    private static func buildLocalEnvironment(
        hermesHomeExpression: String,
        searchPathExpression: String,
        terminalTheme: TerminalThemePreference
    ) -> [String] {
        var env = ProcessInfo.processInfo.environment

        let homeDir = env["HOME"] ?? NSHomeDirectory()

        let hermesHome = hermesHomeExpression
            .replacingOccurrences(of: "$HOME", with: homeDir)
        let searchPath = searchPathExpression
            .replacingOccurrences(of: "$HOME", with: homeDir)
            .replacingOccurrences(of: "$PATH", with: env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin")

        env["HERMES_HOME"] = hermesHome
        env["PATH"] = searchPath
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"

        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"

        // Embedded TUIs only: stop the Hermes Ink TUI from opening clicked URLs
        // in the default browser. Mouse tracking forwards the click a user makes
        // to focus the Desktop window into the TUI, so a plain click landing on a
        // link cell would pop a browser tab (entry.tsx honours this knob).
        env["HERMES_TUI_NO_CLICK_OPEN"] = "1"

        let bgColor = terminalTheme.resolvedAppearance.backgroundColor
        let hexBg = bgColor.hexString
        env["HERMES_TUI_BACKGROUND"] = hexBg

        let luminance = Self.relativeLuminance(red: bgColor.red, green: bgColor.green, blue: bgColor.blue)
        if luminance > 0.5 {
            env["HERMES_TUI_LIGHT"] = "1"
        } else {
            env.removeValue(forKey: "HERMES_TUI_LIGHT")
        }

        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linearise(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearise(red) + 0.7152 * linearise(green) + 0.0722 * linearise(blue)
    }
}
