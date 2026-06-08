import AppKit
import Foundation
@preconcurrency import SwiftTerm

// MARK: - PTY output-intercepting terminal view

/// Subclass of `LocalProcessTerminalView` that intercepts every raw byte chunk
/// received from the PTY before feeding it to the terminal emulator.  The
/// `onDataReceived` closure (set after construction) captures raw bytes so the
/// control server can accumulate them in its rolling output buffer.
final class ObservingLocalProcessTerminalView: LocalProcessTerminalView {
    var onDataReceived: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onDataReceived?(slice)
        super.dataReceived(slice: slice)
    }
}

// MARK: - TerminalViewHost

@MainActor
final class TerminalViewHost: NSObject, LocalProcessTerminalViewDelegate {
    private static let bracketedPasteReadinessTimeout: TimeInterval = 60
    private let hostView = TerminalHostView()
    private var startedLaunchToken: UUID?
    private var scheduledLaunchToken: UUID?
    private var initialInputTask: Task<Void, Never>?
    private var appliedAppearance: TerminalThemeAppearance?
    private var appliedFontSize: Double?
    private var appliedFontFamily: TerminalFontFamilyPreference?
    private var appliedBackgroundImageActive: Bool?
    private var onProcessStart: (() -> Void)?
    private var onTitleChange: ((String) -> Void)?
    private var onDirectoryChange: ((String?) -> Void)?
    private var onProcessExit: ((Int32?) -> Void)?

    override init() {
        super.init()
        hostView.terminalView.processDelegate = self
    }

    /// Install a closure that is called (on whatever queue `LocalProcess` dispatches to,
    /// typically main) for every raw byte chunk emitted by the PTY.  Pass `nil` to remove.
    func setDataReceivedCallback(_ callback: ((ArraySlice<UInt8>) -> Void)?) {
        hostView.terminalView.onDataReceived = callback
    }

    func setEventHandlers(
        onProcessStart: @escaping () -> Void,
        onTitleChange: @escaping (String) -> Void,
        onDirectoryChange: @escaping (String?) -> Void,
        onProcessExit: @escaping (Int32?) -> Void
    ) {
        self.onProcessStart = onProcessStart
        self.onTitleChange = onTitleChange
        self.onDirectoryChange = onDirectoryChange
        self.onProcessExit = onProcessExit
    }

    func mount(
        in container: TerminalMountContainerView,
        request: TerminalLaunchRequest,
        appearance: TerminalThemeAppearance,
        fontSize: Double,
        fontFamily: TerminalFontFamilyPreference,
        isActive: Bool,
        backgroundImageActive: Bool
    ) {
        container.mount(hostView)
        applyAppearance(appearance, backgroundImageActive: backgroundImageActive)
        applyFont(fontSize: fontSize, fontFamily: fontFamily)
        setActive(isActive)
        scheduleStartIfNeeded(for: request)
    }

    /// Start the PTY process without mounting into a visible window.
    /// Used by the control server so a session spawned via the API gets a live
    /// shell immediately, without waiting for the SwiftUI layer to render a tab.
    func startHeadless(request: TerminalLaunchRequest) {
        scheduleStartIfNeeded(for: request)
    }

    func unmount(from container: TerminalMountContainerView) {
        container.unmountHostedView()
    }

    nonisolated func terminate() {
        performSelector(onMainThread: #selector(terminateOnMainThread), with: nil, waitUntilDone: false)
    }

    /// Deliver text as raw input to the running PTY (for the control server write route).
    nonisolated func send(text: String) {
        Task { @MainActor [weak self] in
            self?.hostView.send(text)
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.onTitleChange?(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            self?.onDirectoryChange?(directory)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.onProcessExit?(exitCode)
        }
    }

    private func scheduleStartIfNeeded(for request: TerminalLaunchRequest) {
        let launchToken = request.launchToken
        guard startedLaunchToken != launchToken else { return }
        guard scheduledLaunchToken != launchToken else { return }
        scheduledLaunchToken = launchToken

        Task { @MainActor [weak self] in
            self?.startIfNeeded(for: request)
        }
    }

    private func startIfNeeded(for request: TerminalLaunchRequest) {
        scheduledLaunchToken = nil
        guard startedLaunchToken != request.launchToken else { return }
        startedLaunchToken = request.launchToken
        initialInputTask?.cancel()
        initialInputTask = nil

        if request.isLocal {
            startLocalProcess(for: request)
        } else {
            startSSHProcess(for: request)
        }

        onProcessStart?()
        if let workflowLaunchDiagnosticsContext = request.workflowLaunchDiagnosticsContext {
            Task {
                await request.workflowLaunchDiagnostics.recordTerminalProcessStarted(workflowLaunchDiagnosticsContext)
            }
        }
        deliverInitialInputIfNeeded(for: request)
    }

    private func startSSHProcess(for request: TerminalLaunchRequest) {
        let environment = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor"
        ]

        hostView.terminalView.startProcess(
            executable: "/usr/bin/ssh",
            args: request.sshArguments,
            environment: environment,
            execName: "ssh"
        )
    }

    private func startLocalProcess(for request: TerminalLaunchRequest) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        hostView.terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: request.localShellEnvironment,
            execName: (shell as NSString).lastPathComponent
        )
    }

    private func applyAppearance(_ appearance: TerminalThemeAppearance, backgroundImageActive: Bool) {
        guard appliedAppearance != appearance || appliedBackgroundImageActive != backgroundImageActive else { return }
        appliedAppearance = appearance
        appliedBackgroundImageActive = backgroundImageActive
        hostView.apply(appearance: appearance, backgroundImageActive: backgroundImageActive)
    }

    private func applyFont(fontSize: Double, fontFamily: TerminalFontFamilyPreference) {
        let clampedFontSize = TerminalFontPreference.clamped(fontSize)
        guard appliedFontSize != clampedFontSize || appliedFontFamily != fontFamily else { return }
        appliedFontSize = clampedFontSize
        appliedFontFamily = fontFamily
        hostView.apply(fontSize: clampedFontSize, fontFamily: fontFamily)
    }

    private func setActive(_ isActive: Bool) {
        hostView.isHidden = !isActive
        if !isActive {
            hostView.window?.makeFirstResponder(nil)
        } else {
            hostView.window?.makeFirstResponder(hostView.terminalView)
        }
    }

    @MainActor
    @objc
    private func terminateOnMainThread() {
        scheduledLaunchToken = nil
        startedLaunchToken = nil
        initialInputTask?.cancel()
        initialInputTask = nil
        hostView.terminalView.terminate()
    }

    private func deliverInitialInputIfNeeded(for request: TerminalLaunchRequest) {
        guard let initialInput = request.initialInput,
              !initialInput.isEmpty else { return }

        initialInputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let requiresBracketedPasteReadiness = request.workflowLaunchDiagnosticsContext != nil

            if let workflowLaunchDiagnosticsContext = request.workflowLaunchDiagnosticsContext {
                await request.workflowLaunchDiagnostics.recordInitialInputWaitStarted(
                    workflowLaunchDiagnosticsContext,
                    deadlineMilliseconds: Int(Self.bracketedPasteReadinessTimeout * 1000)
                )
            }

            let deadline = Date().addingTimeInterval(Self.bracketedPasteReadinessTimeout)
            while self.startedLaunchToken == request.launchToken,
                  self.hostView.terminalView.process.running,
                  Date() < deadline,
                  !Task.isCancelled {
                if self.hostView.terminalView.terminal.bracketedPasteMode {
                    if let workflowLaunchDiagnosticsContext = request.workflowLaunchDiagnosticsContext {
                        await request.workflowLaunchDiagnostics.recordBracketedPasteModeObserved(
                            workflowLaunchDiagnosticsContext,
                            stage: "pre_send"
                        )
                    }
                    self.hostView.submitBracketedPaste(initialInput)
                    if let workflowLaunchDiagnosticsContext = request.workflowLaunchDiagnosticsContext {
                        await request.workflowLaunchDiagnostics.recordInitialInputSent(
                            workflowLaunchDiagnosticsContext,
                            deliveryMode: .bracketedPaste,
                            reason: "bracketed_paste_mode_ready",
                            bracketedPasteModeAtSend: true
                        )
                    }
                    return
                }

                try? await Task.sleep(for: .milliseconds(120))
            }

            guard self.startedLaunchToken == request.launchToken else {
                if let workflowLaunchDiagnosticsContext = request.workflowLaunchDiagnosticsContext {
                    await request.workflowLaunchDiagnostics.recordInitialInputAborted(
                        workflowLaunchDiagnosticsContext,
                        reason: "launch_token_changed"
                    )
                }
                return
            }

            guard self.hostView.terminalView.process.running else {
                if let workflowLaunchDiagnosticsContext = request.workflowLaunchDiagnosticsContext {
                    await request.workflowLaunchDiagnostics.recordInitialInputAborted(
                        workflowLaunchDiagnosticsContext,
                        reason: "process_not_running"
                    )
                }
                return
            }

            guard !Task.isCancelled else {
                if let workflowLaunchDiagnosticsContext = request.workflowLaunchDiagnosticsContext {
                    await request.workflowLaunchDiagnostics.recordInitialInputAborted(
                        workflowLaunchDiagnosticsContext,
                        reason: "task_cancelled"
                    )
                }
                return
            }

            if requiresBracketedPasteReadiness {
                if let workflowLaunchDiagnosticsContext = request.workflowLaunchDiagnosticsContext {
                    await request.workflowLaunchDiagnostics.recordInitialInputAborted(
                        workflowLaunchDiagnosticsContext,
                        reason: "deadline_reached_without_bracketed_paste_mode"
                    )
                }
                return
            }

            self.hostView.submit(initialInput)
        }
    }
}

struct TerminalLaunchRequest {
    let sshArguments: [String]
    let launchToken: UUID
    let initialInput: String?
    let workflowLaunchDiagnostics: WorkflowLaunchDiagnostics
    let workflowLaunchDiagnosticsContext: WorkflowLaunchDiagnosticsContext?

    // Local-transport fields (isLocal == true).
    // When set, the terminal launches a local login shell instead of SSH.
    let isLocal: Bool
    let localShellEnvironment: [String]

    init(
        sshArguments: [String],
        launchToken: UUID,
        initialInput: String?,
        workflowLaunchDiagnostics: WorkflowLaunchDiagnostics,
        workflowLaunchDiagnosticsContext: WorkflowLaunchDiagnosticsContext?,
        isLocal: Bool = false,
        localShellEnvironment: [String] = []
    ) {
        self.sshArguments = sshArguments
        self.launchToken = launchToken
        self.initialInput = initialInput
        self.workflowLaunchDiagnostics = workflowLaunchDiagnostics
        self.workflowLaunchDiagnosticsContext = workflowLaunchDiagnosticsContext
        self.isLocal = isLocal
        self.localShellEnvironment = localShellEnvironment
    }
}

final class TerminalMountContainerView: NSView {
    private weak var hostedView: NSView?
    private var hostedConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mount(_ view: NSView) {
        if hostedView === view, view.superview === self {
            return
        }

        unmountHostedView()
        if let previousContainer = view.superview as? TerminalMountContainerView,
           previousContainer !== self {
            previousContainer.releaseHostedViewReference(ifMatching: view)
        }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        hostedView = view
        hostedConstraints = [
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(hostedConstraints)
    }

    func unmountHostedView() {
        NSLayoutConstraint.deactivate(hostedConstraints)
        hostedConstraints.removeAll(keepingCapacity: false)
        if hostedView?.superview === self {
            hostedView?.removeFromSuperview()
        }
        hostedView = nil
    }

    private func releaseHostedViewReference(ifMatching view: NSView) {
        guard hostedView === view else { return }
        NSLayoutConstraint.deactivate(hostedConstraints)
        hostedConstraints.removeAll(keepingCapacity: false)
        hostedView = nil
    }
}

final class TerminalHostView: NSView {
    let terminalView = ObservingLocalProcessTerminalView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(appearance: TerminalThemeAppearance, backgroundImageActive: Bool) {
        let backgroundColor = appearance.backgroundColor.nsColor
        let foregroundColor = appearance.foregroundColor.nsColor
        let terminalBackgroundColor = backgroundImageActive ? NSColor.clear : backgroundColor

        layer?.backgroundColor = terminalBackgroundColor.cgColor
        terminalView.nativeBackgroundColor = terminalBackgroundColor
        terminalView.nativeForegroundColor = foregroundColor
        terminalView.selectedTextBackgroundColor = foregroundColor.withAlphaComponent(0.28)
        terminalView.caretColor = foregroundColor
        terminalView.caretTextColor = backgroundImageActive ? NSColor.black.withAlphaComponent(0.72) : backgroundColor
        terminalView.installColors(appearance.ansiPalette.map(Self.makeTerminalColor(from:)))
    }

    func apply(fontSize: Double, fontFamily: TerminalFontFamilyPreference) {
        terminalView.font = fontFamily.font(size: fontSize)
    }

    func send(_ text: String) {
        send(bytes: Array(text.utf8))
    }

    func send(bytes: [UInt8]) {
        terminalView.process.send(data: bytes[...])
    }

    func sendReturn() {
        send("\r")
    }

    func submit(_ text: String) {
        send(bytes: TerminalInputSequence.standardSubmission(for: text))
    }

    func submitBracketedPaste(_ text: String) {
        send(bytes: TerminalInputSequence.bracketedPasteSubmission(for: text))
    }

    private static func makeTerminalColor(from themeColor: TerminalThemeColor) -> SwiftTerm.Color {
        let color = themeColor.nsColor.usingColorSpace(.deviceRGB) ?? .black
        return SwiftTerm.Color(
            red: UInt16(color.redComponent * 65535),
            green: UInt16(color.greenComponent * 65535),
            blue: UInt16(color.blueComponent * 65535)
        )
    }
}

enum TerminalInputSequence {
    private static let carriageReturn = UInt8(ascii: "\r")

    static func standardSubmission(for text: String) -> [UInt8] {
        Array(text.utf8) + [carriageReturn]
    }

    static func bracketedPasteSubmission(for text: String) -> [UInt8] {
        EscapeSequences.bracketedPasteStart +
            Array(text.utf8) +
            EscapeSequences.bracketedPasteEnd +
            [carriageReturn]
    }
}
