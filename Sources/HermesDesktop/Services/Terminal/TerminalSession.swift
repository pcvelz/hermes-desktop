import Foundation

@MainActor
final class TerminalSession: ObservableObject, @unchecked Sendable {
    let connection: ConnectionProfile
    let sshArguments: [String]
    let localShellEnvironment: [String]
    let startupInput: String?
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
        startupCommandLine: String? = nil,
        startupInput: String? = nil,
        workflowLaunchDiagnostics: WorkflowLaunchDiagnostics,
        workflowLaunchDiagnosticsContext: WorkflowLaunchDiagnosticsContext? = nil
    ) {
        self.connection = connection
        self.startupInput = startupInput
        self.workflowLaunchDiagnostics = workflowLaunchDiagnostics
        self.workflowLaunchDiagnosticsContext = workflowLaunchDiagnosticsContext

        if connection.isLocal {
            self.sshArguments = []
            self.localShellEnvironment = TerminalSession.buildLocalEnvironment(
                hermesHomeExpression: connection.remoteHermesHomeShellExpression,
                searchPathExpression: connection.remoteHermesSearchPathShellExpression,
                startupCommandLine: startupCommandLine
            )
        } else {
            self.sshArguments = sshTransport.shellArguments(
                for: connection,
                startupCommandLine: startupCommandLine
            )
            self.localShellEnvironment = []
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
            request: TerminalLaunchRequest(
                sshArguments: sshArguments,
                launchToken: launchToken,
                initialInput: startupInput,
                workflowLaunchDiagnostics: workflowLaunchDiagnostics,
                workflowLaunchDiagnosticsContext: workflowLaunchDiagnosticsContext,
                isLocal: connection.isLocal,
                localShellEnvironment: localShellEnvironment
            ),
            appearance: appearance,
            fontSize: fontSize,
            fontFamily: fontFamily,
            isActive: isActive,
            backgroundImageActive: backgroundImageActive
        )
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

    // MARK: - Local environment builder

    private static func buildLocalEnvironment(
        hermesHomeExpression: String,
        searchPathExpression: String,
        startupCommandLine: String?
    ) -> [String] {
        // Resolve HERMES_HOME by expanding $HOME references at process start time
        // (the expressions may contain $HOME which the shell will expand from the
        // login shell's environment, so we pass them as-is and let -l do the rest).
        var env = ProcessInfo.processInfo.environment

        // Override/inject the Hermes-specific vars so the login shell inherits them.
        // The expressions may reference $HOME; we pre-expand using the real HOME.
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

        // If a startup command was requested, inject it via HERMES_STARTUP_CMD so
        // the shell's ENV file or ZDOTDIR can run it — but the reliable approach is
        // to deliver it as initialInput (the existing bracketedPaste path).  We
        // store the command in the env so callers who need it can read it; the
        // primary delivery is through TerminalLaunchRequest.initialInput.
        if let startupCommandLine,
           !startupCommandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["HERMES_STARTUP_CMD"] = startupCommandLine
        }

        return env.map { "\($0.key)=\($0.value)" }
    }
}
