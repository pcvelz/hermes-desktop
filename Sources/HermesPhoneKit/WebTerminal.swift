@preconcurrency import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import SwiftUI
import UIKit
import WebKit

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

    var backgroundColor: Color {
        Color(uiColor: backgroundUIColor)
    }

    var foregroundColor: Color {
        Color(uiColor: foregroundUIColor)
    }

    var backgroundUIColor: UIColor {
        UIColor(terminalHex: backgroundHex) ?? UIColor(red: 9 / 255, green: 17 / 255, blue: 26 / 255, alpha: 1)
    }

    var foregroundUIColor: UIColor {
        UIColor(terminalHex: foregroundHex) ?? UIColor(red: 237 / 255, green: 241 / 255, blue: 247 / 255, alpha: 1)
    }

    var themeScript: String {
        let payload = """
        {
          "background": "\(backgroundHex)",
          "foreground": "\(foregroundHex)"
        }
        """
        return "window.HermesTerminal && window.HermesTerminal.setTheme(\(payload));"
    }
}

@MainActor
final class HermesTerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let connection: ConnectionProfile
    let startupCommandLine: String?
    let workspaceScopeFingerprint: String
    let hostConnectionFingerprint: String
    let profileName: String

    @Published var terminalStatus: String = "Ready"
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var hasStarted = false
    @Published var displayTitle: String

    private let sshTransport = SSHTransport()
    private var webView: WKWebView?
    private let messageProxy = TerminalMessageProxy()
    private var task: Task<Void, Never>?
    private var currentClient: SSHClient?
    private var currentWriter: TTYStdinWriter?
    private var activeAttemptID = UUID()
    private var resizeTask: Task<Void, Never>?
    private var layoutRefreshTask: Task<Void, Never>?
    private var lastSentWindowSize: TerminalWindowSize?
    private var currentWindowSize = TerminalWindowSize.fallback
    private var isTerminalReady = false
    private var pendingJavaScript: [String] = []
    private var transcriptBuffer = Data()
    private let maxTranscriptBytes = 1_000_000
    private var currentAppearance = TerminalAppearance.default

    init(
        connection: ConnectionProfile,
        startupCommandLine: String? = nil,
        titleHint: String? = nil
    ) {
        self.connection = connection
        self.startupCommandLine = startupCommandLine
        self.workspaceScopeFingerprint = connection.workspaceScopeFingerprint
        self.hostConnectionFingerprint = connection.hostConnectionFingerprint
        self.profileName = connection.resolvedHermesProfileName
        self.displayTitle = titleHint ?? connection.resolvedHermesProfileName
        messageProxy.session = self
    }

    var chipSubtitle: String {
        connection.label
    }

    func attach(to container: TerminalContainerView) {
        let webView = ensureWebView()
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.embed(webView: webView)
        }
        flushPendingJavaScriptIfNeeded()
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
        layoutRefreshTask?.cancel()
        layoutRefreshTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        HermesTerminalMessageName.allCases.forEach { name in
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: name.rawValue)
        }
        webView = nil
    }

    func dismissKeyboard() {
        webView?.endEditing(true)
        enqueueJavaScript("window.HermesTerminal && window.HermesTerminal.blur();")
    }

    func ensurePromptVisible() {
        enqueueJavaScript("window.HermesTerminal && window.HermesTerminal.scrollToBottom();")
    }

    func sendQuickKey(_ key: TerminalQuickKey) {
        sendInput(key.sequence)
    }

    func updateAppearance(_ appearance: TerminalAppearance) {
        guard currentAppearance != appearance else { return }
        currentAppearance = appearance
        enqueueJavaScript(appearance.themeScript)
        refreshLayout()
    }

    func refreshLayout() {
        layoutRefreshTask?.cancel()
        layoutRefreshTask = Task { [weak self] in
            guard let self else { return }
            self.lastSentWindowSize = nil
            self.enqueueJavaScript("window.HermesTerminal && window.HermesTerminal.refreshLayout();")
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self.enqueueJavaScript("window.HermesTerminal && window.HermesTerminal.refreshLayout();")
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            self.enqueueJavaScript("window.HermesTerminal && window.HermesTerminal.refreshLayout();")
        }
    }

    func terminalDidBecomeReady(windowSize: TerminalWindowSize) {
        isTerminalReady = true
        currentWindowSize = normalized(windowSize)
        enqueueJavaScript(currentAppearance.themeScript)
        resetAndReplayTranscript()
        flushPendingJavaScriptIfNeeded()
        handleViewportChange(currentWindowSize)
        enqueueJavaScript("window.HermesTerminal && window.HermesTerminal.focus();")
        refreshLayout()
    }

    func terminalDidResize(windowSize: TerminalWindowSize) {
        currentWindowSize = normalized(windowSize)
        handleViewportChange(currentWindowSize)
    }

    func terminalDidReceiveInput(_ data: String) {
        sendInput(sanitizedTerminalInput(data))
    }

    func terminalDidReceiveBinary(_ data: String) {
        let bytes = data.unicodeScalars.map { UInt8($0.value & 0xFF) }
        sendBytes(bytes)
    }

    func terminalContentDidStartLoading() {
        isTerminalReady = false
    }

    private func connect() {
        let attemptID = UUID()
        activeAttemptID = attemptID
        isConnecting = true
        isConnected = false
        hasStarted = false
        terminalStatus = "Connecting to \(connection.displayDestination)..."
        enqueueJavaScript("window.HermesTerminal && window.HermesTerminal.reset();")

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
                    self.enqueueJavaScript("window.HermesTerminal && window.HermesTerminal.focus();")
                }

                let bootstrap = self.sshTransport.shellBootstrapSequence(
                    for: self.connection,
                    startupCommandLine: self.startupCommandLine
                ) + "\n"
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
        guard let writer = currentWriter else { return }
        Task {
            try? await writer.write(ByteBuffer(bytes: bytes))
        }
    }

    private func writeToTerminal(_ bytes: [UInt8]) {
        appendToTranscript(bytes)
        guard isTerminalReady, let webView else { return }
        let script = makeWriteScript(for: bytes)
        webView.evaluateJavaScript(script)
    }

    private func appendToTranscript(_ bytes: [UInt8]) {
        transcriptBuffer.append(contentsOf: bytes)
        let overflow = transcriptBuffer.count - maxTranscriptBytes
        if overflow > 0 {
            transcriptBuffer.removeFirst(overflow)
        }
    }

    private func resetAndReplayTranscript() {
        guard isTerminalReady, let webView else { return }
        webView.evaluateJavaScript("window.HermesTerminal && window.HermesTerminal.reset();")
        guard !transcriptBuffer.isEmpty else { return }
        let chunkSize = 16_384
        var offset = 0
        while offset < transcriptBuffer.count {
            let upperBound = min(offset + chunkSize, transcriptBuffer.count)
            let chunk = Array(transcriptBuffer[offset..<upperBound])
            webView.evaluateJavaScript(makeWriteScript(for: chunk))
            offset = upperBound
        }
    }

    private func makeWriteScript(for bytes: [UInt8]) -> String {
        let base64 = Data(bytes).base64EncodedString()
        return "window.HermesTerminal && window.HermesTerminal.writeBase64('\(base64)');"
    }

    private func enqueueJavaScript(_ script: String) {
        guard let webView, isTerminalReady else {
            pendingJavaScript.append(script)
            return
        }
        webView.evaluateJavaScript(script)
    }

    private func flushPendingJavaScriptIfNeeded() {
        guard isTerminalReady, let webView, !pendingJavaScript.isEmpty else { return }
        let scripts = pendingJavaScript
        pendingJavaScript.removeAll()
        for script in scripts {
            webView.evaluateJavaScript(script)
        }
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

    private func ensureWebView() -> WKWebView {
        if let webView {
            return webView
        }

        let userContentController = WKUserContentController()
        HermesTerminalMessageName.allCases.forEach { name in
            userContentController.add(messageProxy, name: name.rawValue)
        }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.clipsToBounds = true
        webView.layer.masksToBounds = true
        webView.navigationDelegate = messageProxy
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        loadTerminalPage(into: webView)
        self.webView = webView
        return webView
    }

    private func loadTerminalPage(into webView: WKWebView) {
        guard
            let htmlURL = Bundle.module.url(
                forResource: "terminal",
                withExtension: "html",
                subdirectory: "TerminalWeb"
            )
        else {
            return
        }

        let rootURL = htmlURL.deletingLastPathComponent()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: rootURL)
    }

    private func sanitizedTerminalInput(_ data: String) -> String {
        var sanitized = data
        sanitized = removingOSCColorReply(code: "10", from: sanitized)
        sanitized = removingOSCColorReply(code: "11", from: sanitized)
        sanitized = removingOSCColorReply(code: "12", from: sanitized)
        return sanitized
    }

    private func removingOSCColorReply(code: String, from text: String) -> String {
        let prefix = "\u{1B}]\(code);rgb:"
        var remaining = text

        while let lowerBound = remaining.range(of: prefix)?.lowerBound {
            let searchStart = remaining.index(lowerBound, offsetBy: prefix.count)

            if let bellTerminator = remaining[searchStart...].firstIndex(of: "\u{07}") {
                remaining.removeSubrange(lowerBound...bellTerminator)
                continue
            }

            if let escapeIndex = remaining[searchStart...].firstIndex(of: "\u{1B}") {
                let slashIndex = remaining.index(after: escapeIndex)
                if slashIndex < remaining.endIndex, remaining[slashIndex] == "\\" {
                    remaining.removeSubrange(lowerBound...slashIndex)
                    continue
                }
            }

            break
        }

        return remaining
    }
}

@MainActor
final class HermesTerminalWorkspaceStore: ObservableObject {
    @Published private(set) var sessions: [HermesTerminalSession] = []
    @Published var selectedSessionID: UUID?

    var selectedSession: HermesTerminalSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var hasSessions: Bool {
        !sessions.isEmpty
    }

    func selectSession(_ sessionID: UUID?) {
        selectedSessionID = sessionID
    }

    func ensureInitialSession(for connection: ConnectionProfile) {
        if let existing = sessions.last(where: { $0.workspaceScopeFingerprint == connection.workspaceScopeFingerprint }) {
            selectedSessionID = existing.id
            existing.connectIfNeeded()
        } else {
            addSession(for: connection)
        }
    }

    @discardableResult
    func addSession(
        for connection: ConnectionProfile,
        startupCommandLine: String? = nil,
        titleHint: String? = nil
    ) -> HermesTerminalSession {
        let suffix = sessions.filter { $0.workspaceScopeFingerprint == connection.workspaceScopeFingerprint }.count + 1
        let defaultTitle = suffix == 1 ? "Shell" : "Shell \(suffix)"
        let session = HermesTerminalSession(
            connection: connection,
            startupCommandLine: startupCommandLine,
            titleHint: titleHint ?? defaultTitle
        )
        sessions.append(session)
        selectedSessionID = session.id
        session.connectIfNeeded()
        return session
    }

    func closeSession(_ session: HermesTerminalSession) {
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last(where: { $0.id != session.id })?.id
        }
        sessions.removeAll { $0.id == session.id }
        session.close()
    }

    func closeSessions(forConnectionID connectionID: UUID) {
        let removed = sessions.filter { $0.connection.id == connectionID }
        let removedIDs = Set(removed.map(\.id))
        if let selectedSessionID, removedIDs.contains(selectedSessionID) {
            self.selectedSessionID = sessions.last(where: { !removedIDs.contains($0.id) })?.id
        }
        sessions.removeAll { $0.connection.id == connectionID }
        removed.forEach { $0.close() }
    }
}

private enum HermesTerminalMessageName: String, CaseIterable {
    case ready = "terminalReady"
    case input = "terminalInput"
    case binary = "terminalBinary"
    case resize = "terminalResize"
}

final class TerminalContainerView: UIView {
    var onBoundsChange: (() -> Void)?
    private var lastBounds: CGRect = .zero

    func embed(webView: WKWebView) {
        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != .zero else { return }
        guard bounds.integral != lastBounds.integral else { return }
        lastBounds = bounds.integral
        onBoundsChange?()
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
}

final class TerminalMessageProxy: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var session: HermesTerminalSession?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let session, let container = webView.superview as? TerminalContainerView else { return }
        session.attach(to: container)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        session?.terminalContentDidStartLoading()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let session else { return }
        switch HermesTerminalMessageName(rawValue: message.name) {
        case .ready:
            if let payload = message.body as? [String: Any] {
                session.terminalDidBecomeReady(windowSize: windowSize(from: payload))
            }
        case .resize:
            if let payload = message.body as? [String: Any] {
                session.terminalDidResize(windowSize: windowSize(from: payload))
            }
        case .input:
            if let payload = message.body as? [String: Any], let data = payload["data"] as? String {
                session.terminalDidReceiveInput(data)
            }
        case .binary:
            if let payload = message.body as? [String: Any], let data = payload["data"] as? String {
                session.terminalDidReceiveBinary(data)
            }
        case nil:
            break
        }
    }

    private func windowSize(from payload: [String: Any]) -> TerminalWindowSize {
        TerminalWindowSize(
            cols: number(payload["cols"], fallback: TerminalWindowSize.fallback.cols),
            rows: number(payload["rows"], fallback: TerminalWindowSize.fallback.rows),
            pixelWidth: number(payload["pixelWidth"], fallback: TerminalWindowSize.fallback.pixelWidth),
            pixelHeight: number(payload["pixelHeight"], fallback: TerminalWindowSize.fallback.pixelHeight)
        )
    }

    private func number(_ value: Any?, fallback: Int) -> Int {
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue)
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        return fallback
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
