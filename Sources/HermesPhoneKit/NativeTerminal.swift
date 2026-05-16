@preconcurrency import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH
@preconcurrency import SwiftTerm
import SwiftUI
import UIKit

enum TerminalQuickKey: String, CaseIterable, Identifiable {
    case escape
    case tab
    case ctrlC
    case ctrlD
    case pipe
    case slash
    case dash
    case up
    case down
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .ctrlC: "^C"
        case .ctrlD: "^D"
        case .pipe: "|"
        case .slash: "/"
        case .dash: "-"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        }
    }

    var sequence: String {
        switch self {
        case .escape: "\u{1B}"
        case .tab: "\t"
        case .ctrlC: "\u{03}"
        case .ctrlD: "\u{04}"
        case .pipe: "|"
        case .slash: "/"
        case .dash: "-"
        case .up: "\u{1B}[A"
        case .down: "\u{1B}[B"
        case .left: "\u{1B}[D"
        case .right: "\u{1B}[C"
        }
    }
}

struct TerminalWindowSize: Equatable {
    let cols: Int
    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int

    static let fallback = TerminalWindowSize(cols: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
}

struct TerminalAppearance: Equatable {
    let backgroundHex: String
    let foregroundHex: String

    static let `default` = TerminalAppearance(
        backgroundHex: "#09111A",
        foregroundHex: "#EDF1F7"
    )

    var backgroundColor: SwiftUI.Color {
        SwiftUI.Color(uiColor: backgroundUIColor)
    }

    var foregroundColor: SwiftUI.Color {
        SwiftUI.Color(uiColor: foregroundUIColor)
    }

    var backgroundUIColor: UIColor {
        UIColor(terminalHex: backgroundHex) ?? UIColor(red: 9 / 255, green: 17 / 255, blue: 26 / 255, alpha: 1)
    }

    var foregroundUIColor: UIColor {
        UIColor(terminalHex: foregroundHex) ?? UIColor(red: 237 / 255, green: 241 / 255, blue: 247 / 255, alpha: 1)
    }

    var cursorUIColor: UIColor {
        foregroundUIColor.withAlphaComponent(0.92)
    }
}

struct PersistedTerminalWorkspace: Codable {
    var selectedSessionID: UUID?
    var sessions: [PersistedTerminalSession]
}

struct PersistedTerminalSession: Codable {
    let id: UUID
    let connection: ConnectionProfile
    let startupCommandLine: String?
    let titleHint: String
}

@MainActor
final class HermesTerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let connection: ConnectionProfile
    let startupCommandLine: String?
    let workspaceScopeFingerprint: String
    let hostConnectionFingerprint: String
    let contextLabel: String

    @Published var terminalStatus: String = "Ready"
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var hasStarted = false
    @Published var displayTitle: String

    var onSnapshotChange: (() -> Void)?

    private let sshTransport = SSHTransport()
    private let bridge = HermesTerminalBridge()
    private var hostView: HermesNativeTerminalHostView?
    private var task: Task<Void, Never>?
    private var currentClient: SSHClient?
    private var currentWriter: TTYStdinWriter?
    private var activeAttemptID = UUID()
    private var resizeTask: Task<Void, Never>?
    private var lastSentWindowSize: TerminalWindowSize?
    private var currentWindowSize = TerminalWindowSize.fallback
    private var transcriptBuffer = Data()
    private let maxTranscriptBytes = 1_000_000
    private var currentAppearance = TerminalAppearance.default

    init(
        id: UUID = UUID(),
        connection: ConnectionProfile,
        startupCommandLine: String? = nil,
        titleHint: String? = nil
    ) {
        self.id = id
        self.connection = connection
        self.startupCommandLine = startupCommandLine
        self.workspaceScopeFingerprint = connection.workspaceScopeFingerprint
        self.hostConnectionFingerprint = connection.hostConnectionFingerprint
        self.contextLabel = startupCommandLine == nil ? "Default shell" : connection.resolvedHermesProfileName
        self.displayTitle = titleHint ?? connection.resolvedHermesProfileName
        bridge.session = self
    }

    var chipSubtitle: String {
        contextLabel
    }

    var snapshot: PersistedTerminalSession {
        PersistedTerminalSession(
            id: id,
            connection: connection,
            startupCommandLine: startupCommandLine,
            titleHint: displayTitle
        )
    }

    func attach(to container: TerminalContainerView) {
        let hostView = ensureHostView()
        container.mount(hostView)
        applyAppearanceIfNeeded()
        refreshLayout()
    }

    func connectIfNeeded() {
        guard !isConnected, !isConnecting, task == nil else { return }
        connect()
    }

    func requestReconnect() {
        disconnect(updateStatus: false)
        connect()
    }

    func close() {
        disconnect(updateStatus: false)
        hostView?.terminalView.terminalDelegate = nil
        hostView = nil
    }

    func dismissKeyboard() {
        hostView?.dismissKeyboard()
    }

    func focusInput() {
        _ = hostView?.terminalView.becomeFirstResponder()
    }

    func ensurePromptVisible() {
        hostView?.scrollToBottom()
    }

    func sendQuickKey(_ key: TerminalQuickKey) {
        sendInput(key.sequence)
    }

    func updateAppearance(_ appearance: TerminalAppearance) {
        guard currentAppearance != appearance else { return }
        currentAppearance = appearance
        applyAppearanceIfNeeded()
    }

    func refreshLayout() {
        hostView?.refreshLayout()
        hostView?.scrollToBottomIfNearEnd()
    }

    func handleTerminalSizeChange(cols: Int, rows: Int, in terminalView: TerminalView) {
        currentWindowSize = normalized(
            TerminalWindowSize(
                cols: cols,
                rows: rows,
                pixelWidth: Int(terminalView.bounds.width * terminalView.contentScaleFactor),
                pixelHeight: Int(terminalView.bounds.height * terminalView.contentScaleFactor)
            )
        )
        handleViewportChange(currentWindowSize)
    }

    func updateDisplayTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayTitle else { return }
        displayTitle = trimmed
        onSnapshotChange?()
    }

    func openLink(_ link: String) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func copyToClipboard(_ content: Data) {
        if let string = String(data: content, encoding: .utf8), !string.isEmpty {
            UIPasteboard.general.string = string
        } else {
            UIPasteboard.general.setData(content, forPasteboardType: "public.data")
        }
    }

    func sendTerminalInput(_ data: ArraySlice<UInt8>) {
        sendBytes(Array(data))
    }

    private func connect() {
        let attemptID = UUID()
        activeAttemptID = attemptID
        isConnecting = true
        isConnected = false
        hasStarted = false
        terminalStatus = "Connecting to \(connection.displayDestination)..."

        if let hostView {
            resetTranscript(on: hostView.terminalView)
        }

        task = Task { [weak self] in
            await self?.run(attemptID: attemptID)
        }
    }

    private func disconnect(updateStatus: Bool) {
        let taskToCancel = task
        let clientToClose = currentClient
        activeAttemptID = UUID()
        resizeTask?.cancel()
        resizeTask = nil
        lastSentWindowSize = nil
        task = nil
        currentClient = nil
        currentWriter = nil
        isConnected = false
        isConnecting = false
        taskToCancel?.cancel()

        if updateStatus {
            terminalStatus = "Disconnected."
        }

        Task {
            try? await clientToClose?.close()
        }
    }

    private func run(attemptID: UUID) async {
        do {
            let credentialStore = ConnectionSecretsStore()
            guard let credential = try credentialStore.load(for: connection.id) else {
                throw HermesPhoneStoreError.missingCredential
            }

            let client = try await sshTransport.makeClient(connection: connection, credential: credential)
            guard isCurrentAttempt(attemptID) else {
                try? await client.close()
                return
            }
            currentClient = client
            lastSentWindowSize = nil
            let geometry = normalized(currentWindowSize)

            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: geometry.cols,
                terminalRowHeight: geometry.rows,
                terminalPixelWidth: geometry.pixelWidth,
                terminalPixelHeight: geometry.pixelHeight,
                terminalModes: .init([:])
            )

            try await client.withPTY(request) { @Sendable [weak self] inbound, outbound in
                guard let self else { return }
                await MainActor.run {
                    guard self.isCurrentAttempt(attemptID) else { return }
                    self.currentWriter = outbound
                    self.isConnected = true
                    self.isConnecting = false
                    self.hasStarted = true
                    self.terminalStatus = "Connected"
                    self.focusInput()
                }

                let bootstrap = await MainActor.run {
                    self.makeBootstrapSequence() + "\n"
                }
                try await outbound.write(ByteBuffer(string: bootstrap))

                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer):
                        let bytes = Array(buffer.readableBytesView)
                        await MainActor.run {
                            self.writeToTerminal(bytes)
                        }
                    }
                }
            }

            guard isCurrentAttempt(attemptID) else { return }
            currentClient = nil
            currentWriter = nil
            task = nil
            isConnected = false
            isConnecting = false
            terminalStatus = "Shell exited."
        } catch is CancellationError {
            guard isCurrentAttempt(attemptID) else { return }
            currentClient = nil
            currentWriter = nil
            task = nil
            isConnected = false
            isConnecting = false
        } catch {
            guard isCurrentAttempt(attemptID) else { return }
            currentClient = nil
            currentWriter = nil
            task = nil
            isConnected = false
            isConnecting = false
            let message = presentableTerminalError(error, connection: connection)
            terminalStatus = message
            writeToTerminal(Array("\r\n[HermesPhone] \(message)\r\n".utf8))
        }
    }

    private func makeBootstrapSequence() -> String {
        if startupCommandLine == nil {
            return connection.remoteShellBootstrapCommand()
        }
        return connection.remoteShellBootstrapCommand(startupCommandLine: startupCommandLine)
    }

    private func handleViewportChange(_ windowSize: TerminalWindowSize) {
        guard let writer = currentWriter else { return }
        let normalizedSize = normalized(windowSize)
        guard normalizedSize != lastSentWindowSize else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            try? await writer.changeSize(
                cols: normalizedSize.cols,
                rows: normalizedSize.rows,
                pixelWidth: normalizedSize.pixelWidth,
                pixelHeight: normalizedSize.pixelHeight
            )
            guard !Task.isCancelled else { return }
            self.lastSentWindowSize = normalizedSize
        }
    }

    private func sendInput(_ data: String) {
        guard !data.isEmpty, let writer = currentWriter else { return }
        Task {
            try? await writer.write(ByteBuffer(string: data))
        }
    }

    private func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let writer = currentWriter else { return }
        Task {
            try? await writer.write(ByteBuffer(bytes: bytes))
        }
    }

    private func writeToTerminal(_ bytes: [UInt8]) {
        appendToTranscript(bytes)
        hostView?.feed(byteArray: bytes)
    }

    private func appendToTranscript(_ bytes: [UInt8]) {
        transcriptBuffer.append(contentsOf: bytes)
        let overflow = transcriptBuffer.count - maxTranscriptBytes
        if overflow > 0 {
            transcriptBuffer.removeFirst(overflow)
        }
    }

    private func replayTranscriptIfNeeded(on terminalView: TerminalView) {
        guard !transcriptBuffer.isEmpty else { return }
        terminalView.feed(byteArray: Array(transcriptBuffer)[...])
    }

    private func resetTranscript(on terminalView: TerminalView) {
        transcriptBuffer.removeAll(keepingCapacity: true)
        terminalView.feed(text: "\u{1B}c")
    }

    private func ensureHostView() -> HermesNativeTerminalHostView {
        if let hostView {
            hostView.terminalView.terminalDelegate = bridge
            return hostView
        }

        let hostView = HermesNativeTerminalHostView(frame: .zero)
        hostView.terminalView.terminalDelegate = bridge
        self.hostView = hostView
        applyAppearance(to: hostView.terminalView)
        replayTranscriptIfNeeded(on: hostView.terminalView)
        return hostView
    }

    private func applyAppearanceIfNeeded() {
        guard let terminalView = hostView?.terminalView else { return }
        applyAppearance(to: terminalView)
    }

    private func applyAppearance(to terminalView: TerminalView) {
        terminalView.nativeBackgroundColor = currentAppearance.backgroundUIColor
        terminalView.nativeForegroundColor = currentAppearance.foregroundUIColor
        terminalView.caretColor = currentAppearance.cursorUIColor
        terminalView.keyboardAppearance = .dark
    }

    private func normalized(_ windowSize: TerminalWindowSize) -> TerminalWindowSize {
        TerminalWindowSize(
            cols: max(windowSize.cols, 2),
            rows: max(windowSize.rows, 2),
            pixelWidth: max(windowSize.pixelWidth, 0),
            pixelHeight: max(windowSize.pixelHeight, 0)
        )
    }

    private func isCurrentAttempt(_ attemptID: UUID) -> Bool {
        activeAttemptID == attemptID
    }

    private func presentableTerminalError(_ error: Error, connection: ConnectionProfile) -> String {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .inputClosed, .eof, .alreadyClosed:
                return "The terminal session on \(connection.displayDestination) was closed by the remote host."
            case .ioOnClosedChannel, .outputClosed:
                return "The terminal session on \(connection.displayDestination) closed unexpectedly."
            default:
                break
            }
        }

        let reflectedType = String(reflecting: type(of: error))
        if reflectedType.contains("ClientHandshakeHandler.Disconnected") {
            return "The SSH connection to \(connection.displayDestination) was closed during handshake."
        }

        return error.localizedDescription
    }
}

@MainActor
final class HermesTerminalWorkspaceStore: ObservableObject {
    @Published private(set) var sessions: [HermesTerminalSession] = []
    @Published var selectedSessionID: UUID?

    var onChange: (() -> Void)?

    var selectedSession: HermesTerminalSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var hasSessions: Bool {
        !sessions.isEmpty
    }

    func selectSession(_ sessionID: UUID?) {
        selectedSessionID = sessionID
        selectedSession?.connectIfNeeded()
        notifyChange()
    }

    func ensureInitialSession(for connection: ConnectionProfile) {
        if let existing = sessions.last(where: { $0.hostConnectionFingerprint == connection.hostConnectionFingerprint }) {
            if shouldReplace(existing, for: connection) {
                closeSession(existing)
                addSession(for: connection)
                return
            }
            selectedSessionID = existing.id
            existing.connectIfNeeded()
            notifyChange()
        } else {
            addSession(for: connection)
        }
    }

    @discardableResult
    func addSession(
        for connection: ConnectionProfile,
        startupCommandLine: String? = nil,
        titleHint: String? = nil,
        restoredID: UUID? = nil,
        connectImmediately: Bool = true
    ) -> HermesTerminalSession {
        let suffix = sessions.filter { $0.hostConnectionFingerprint == connection.hostConnectionFingerprint }.count + 1
        let defaultTitle = suffix == 1 ? "Shell" : "Shell \(suffix)"
        let session = HermesTerminalSession(
            id: restoredID ?? UUID(),
            connection: connection,
            startupCommandLine: startupCommandLine,
            titleHint: titleHint ?? defaultTitle
        )
        observe(session)
        sessions.append(session)
        selectedSessionID = session.id
        if connectImmediately {
            session.connectIfNeeded()
        }
        notifyChange()
        return session
    }

    func closeSession(_ session: HermesTerminalSession) {
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last(where: { $0.id != session.id })?.id
        }
        sessions.removeAll { $0.id == session.id }
        session.close()
        notifyChange()
    }

    func closeSessions(forConnectionID connectionID: UUID) {
        let removed = sessions.filter { $0.connection.id == connectionID }
        let removedIDs = Set(removed.map(\.id))
        if let selectedSessionID, removedIDs.contains(selectedSessionID) {
            self.selectedSessionID = sessions.last(where: { !removedIDs.contains($0.id) })?.id
        }
        sessions.removeAll { $0.connection.id == connectionID }
        removed.forEach { $0.close() }
        notifyChange()
    }

    func snapshot() -> PersistedTerminalWorkspace? {
        guard !sessions.isEmpty else { return nil }
        return PersistedTerminalWorkspace(
            selectedSessionID: selectedSessionID,
            sessions: sessions.map(\.snapshot)
        )
    }

    func restore(
        from snapshot: PersistedTerminalWorkspace?,
        availableConnections: [ConnectionProfile]
    ) {
        sessions.forEach { $0.close() }
        sessions = []
        selectedSessionID = nil

        guard let snapshot else { return }

        for persistedSession in snapshot.sessions {
            guard let connection = resolvedConnection(
                for: persistedSession.connection,
                startupCommandLine: persistedSession.startupCommandLine,
                availableConnections: availableConnections
            ) else {
                continue
            }

            _ = addSession(
                for: connection,
                startupCommandLine: persistedSession.startupCommandLine,
                titleHint: persistedSession.titleHint,
                restoredID: persistedSession.id,
                connectImmediately: false
            )
        }

        if let restoredSelection = snapshot.selectedSessionID,
           sessions.contains(where: { $0.id == restoredSelection }) {
            selectedSessionID = restoredSelection
        } else {
            selectedSessionID = sessions.first?.id
        }
        notifyChange()
    }

    private func observe(_ session: HermesTerminalSession) {
        session.onSnapshotChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.notifyChange()
            }
        }
    }

    private func notifyChange() {
        onChange?()
    }

    private func resolvedConnection(
        for persistedConnection: ConnectionProfile,
        startupCommandLine: String?,
        availableConnections: [ConnectionProfile]
    ) -> ConnectionProfile? {
        guard let currentConnection = availableConnections.first(where: { $0.id == persistedConnection.id }) else {
            return nil
        }

        if startupCommandLine == nil {
            return currentConnection.updated()
        }

        var merged = currentConnection
        merged.hermesProfile = persistedConnection.hermesProfile
        merged.customHermesHomePath = persistedConnection.customHermesHomePath
        return merged.updated()
    }

    private func shouldReplace(_ existing: HermesTerminalSession, for connection: ConnectionProfile) -> Bool {
        guard existing.startupCommandLine == nil else { return false }
        return existing.connection.workspaceScopeFingerprint != connection.workspaceScopeFingerprint ||
            existing.connection.hermesProfile != connection.hermesProfile ||
            existing.connection.customHermesHomePath != connection.customHermesHomePath
    }
}

private final class HermesTerminalBridge: NSObject, TerminalViewDelegate {
    weak var session: HermesTerminalSession?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak session] in
            session?.handleTerminalSizeChange(cols: newCols, rows: newRows, in: source)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor [weak session] in
            session?.updateDisplayTitle(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        Task { @MainActor [weak session] in
            session?.sendTerminalInput(data)
        }
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        Task { @MainActor [weak session] in
            session?.openLink(link)
        }
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        Task { @MainActor [weak session] in
            session?.copyToClipboard(content)
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class HermesNativeTerminalHostView: UIView {
    let terminalView = TerminalView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func refreshLayout() {
        setNeedsLayout()
        layoutIfNeeded()
        terminalView.setNeedsLayout()
        terminalView.layoutIfNeeded()
    }

    func scrollToBottom() {
        let bottomOffsetY = max(-terminalView.adjustedContentInset.top, terminalView.contentSize.height - terminalView.bounds.height + terminalView.adjustedContentInset.bottom)
        terminalView.setContentOffset(CGPoint(x: -terminalView.adjustedContentInset.left, y: bottomOffsetY), animated: false)
    }

    func scrollToBottomIfNearEnd() {
        let maxOffsetY = max(-terminalView.adjustedContentInset.top, terminalView.contentSize.height - terminalView.bounds.height + terminalView.adjustedContentInset.bottom)
        let distanceFromBottom = maxOffsetY - terminalView.contentOffset.y
        if distanceFromBottom < 160 {
            scrollToBottom()
        }
    }

    func dismissKeyboard() {
        terminalView.resignFirstResponder()
        terminalView.endEditing(true)
        window?.endEditing(true)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func feed(byteArray: [UInt8]) {
        guard !byteArray.isEmpty else { return }
        terminalView.feed(byteArray: byteArray[...])
        scrollToBottomIfNearEnd()
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = true

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.optionAsMetaKey = true
        terminalView.keyboardAppearance = .dark
        terminalView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = .white
        terminalView.caretColor = .white
        terminalView.inputAccessoryView = UIView(frame: .zero)
        addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        try? terminalView.setUseMetal(true)
    }
}

final class TerminalContainerView: UIView {
    var onBoundsChange: (() -> Void)?

    private weak var hostedView: UIView?
    private var hostedConstraints: [NSLayoutConstraint] = []
    private var lastBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
    }

    func mount(_ view: UIView) {
        if hostedView === view, view.superview === self {
            return
        }

        unmountHostedView()
        if let previousContainer = view.superview as? TerminalContainerView,
           previousContainer !== self {
            previousContainer.releaseHostedViewReference(ifMatching: view)
        }
        view.removeFromSuperview()
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraints = [
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(constraints)
        hostedConstraints = constraints
        hostedView = view
    }

    func unmountHostedView() {
        NSLayoutConstraint.deactivate(hostedConstraints)
        hostedConstraints.removeAll()
        hostedView?.removeFromSuperview()
        hostedView = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != .zero else { return }
        guard bounds.integral != lastBounds.integral else { return }
        lastBounds = bounds.integral
        onBoundsChange?()
    }

    private func releaseHostedViewReference(ifMatching view: UIView) {
        guard hostedView === view else { return }
        NSLayoutConstraint.deactivate(hostedConstraints)
        hostedConstraints.removeAll()
        hostedView = nil
    }
}

struct HermesTerminalRepresentable: UIViewRepresentable {
    @ObservedObject var session: HermesTerminalSession
    let appearance: TerminalAppearance

    func makeUIView(context: Context) -> TerminalContainerView {
        let view = TerminalContainerView(frame: .zero)
        view.onBoundsChange = {
            session.refreshLayout()
        }
        session.attach(to: view)
        session.updateAppearance(appearance)
        return view
    }

    func updateUIView(_ uiView: TerminalContainerView, context: Context) {
        uiView.onBoundsChange = {
            session.refreshLayout()
        }
        session.attach(to: uiView)
        session.updateAppearance(appearance)
        session.refreshLayout()
        session.connectIfNeeded()
    }

    static func dismantleUIView(_ uiView: TerminalContainerView, coordinator: ()) {
        uiView.unmountHostedView()
    }
}

extension UIColor {
    convenience init?(terminalHex: String) {
        let normalized = terminalHex
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .uppercased()

        guard normalized.count == 6 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: normalized).scanHexInt64(&value) else { return nil }

        self.init(
            red: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }

    var terminalHexString: String? {
        guard let components = cgColor.components else { return nil }

        let resolved: (CGFloat, CGFloat, CGFloat)
        switch components.count {
        case 4:
            resolved = (components[0], components[1], components[2])
        case 2:
            resolved = (components[0], components[0], components[0])
        default:
            return nil
        }

        let red = Int(round(resolved.0 * 255))
        let green = Int(round(resolved.1 * 255))
        let blue = Int(round(resolved.2 * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
