#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

struct ConnectionsScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @State private var draft = ConnectionDraft()
    @State private var isPresentingEditor = false
    @State private var editingConnectionID: UUID?
    @State private var chatTestResult: String?
    @State private var isTestingChat = false
    @State private var showsConnectionGuide = true
    @State private var showsGatewayDiagnostics = false

    var body: some View {
        List {
            Section {
                activeWorkspaceSummary
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            connectionGuideSection

            nativeChatSection

            Section("Hosts") {
                if store.connections.isEmpty {
                    ContentUnavailableView("No Hosts", systemImage: "server.rack", description: Text("Add your Hermes host, then add one or more profiles inside it."))
                } else {
                    ForEach(savedConnectionGroups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(group.connections.count) Hermes \(group.connections.count == 1 ? "profile" : "profiles")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.activeHostFingerprint == group.id {
                                    Text("Active Host")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.green.opacity(0.15), in: Capsule())
                                } else {
                                    Button("Use Host") {
                                        store.activateHost(group.id)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Button {
                                    addProfile(to: group)
                                } label: {
                                    Label("Add Profile", systemImage: "plus")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                            }

                            ForEach(group.connections) { connection in
                                connectionRow(connection)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            store.removeConnection(connection)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                if connection.id != group.connections.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            Button {
                editingConnectionID = nil
                draft = ConnectionDraft()
                isPresentingEditor = true
            } label: {
                Label("Add Host", systemImage: "plus")
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            NavigationStack {
                ConnectionEditorView(draft: $draft, editingConnectionID: editingConnectionID)
                    .environmentObject(store)
            }
        }
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.refreshOverview()
            await store.nativeChatStore.refreshBootstrapStatus()
        }
    }

    private var activeWorkspaceSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Active Workspace")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let connection = store.activeConnection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.label)
                                .font(.title3.weight(.semibold))
                            Text(connection.displayDestination)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(connection.resolvedHermesProfileName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.16), in: Capsule())
                            Text(connection.displayProfileScope)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let overview = store.overview {
                        VStack(alignment: .leading, spacing: 8) {
                            workspaceMetric(label: "Remote Home", value: overview.remoteHome)
                            workspaceMetric(label: "Hermes Home", value: overview.hermesHome)
                            workspaceMetric(label: "Chat", value: "Native TUI Gateway over SSH")
                            workspaceMetric(label: "Session Store", value: overview.sessionStore?.path ?? "Not found")
                            workspaceMetric(label: "Profiles", value: overview.availableProfiles.map(\.name).joined(separator: " · "))
                        }
                    } else {
                        Text("Pull remote workspace details from here, then spend the rest of your time in Terminal, Sessions, and Files.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ContentUnavailableView("No Active Connection", systemImage: "server.rack", description: Text("Pick a saved connection to make Terminal, Sessions, and Files immediately usable."))
            }
        }
    }

    private func connectionRow(_ connection: ConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.label)
                        .font(.headline)
                    Text(connection.resolvedHermesProfileName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(nativeChatSummary(for: connection))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(".env: \(connection.remoteHermesHomePath)/.env")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button("Select") {
                    store.activateConnection(connection)
                }
                .buttonStyle(.bordered)

                Button("Edit") {
                    editingConnectionID = connection.id
                    draft = ConnectionDraft(connection: connection, credential: (try? store.credential(for: connection)) ?? SSHCredentialRecord())
                    isPresentingEditor = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private func workspaceMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }

    private var connectionGuideSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsConnectionGuide) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("La chat nativa usa il runtime Hermes TUI Gateway via SSH. Non richiede API server o porte esposte.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let connection = store.activeConnection {
                        ConnectionsGuideStep(title: "1. SSH funziona", detail: "Host e credenziali permettono connessioni non interattive.")
                        ConnectionsGuideStep(title: "2. Hermes CLI disponibile", detail: "Il comando hermes risponde a --version.")
                        ConnectionsGuideStep(title: "3. TUI Gateway importabile", detail: "python3 può importare tui_gateway.entry.")
                        ConnectionsGuideStep(title: "4. Usa Terminale come fallback", detail: "Se il gateway non è disponibile, Terminale conserva il runtime Hermes/TUI completo.")
                    } else {
                        ConnectionsGuideStep(title: "1. Aggiungi un host", detail: "Inserisci host, porta SSH e utente. È abbastanza per Terminale, Files e Chat.")
                        ConnectionsGuideStep(title: "2. Profilo Hermes opzionale", detail: "Default usa ~/.hermes/.env. Profili alternativi usano ~/.hermes/profiles/<nome>/.env.")
                    }

                    Text("Sicuro: la chat passa tramite SSH e non richiede esporre porte.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } label: {
                Label("Chat setup in 3 steps", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var nativeChatSection: some View {
        Section("Chat status") {
            if let bootstrap = store.nativeChatStore.bootstrapStatus {
                DetailRow(label: "SSH", value: bootstrap.sshConnected ? "Connected" : "Unavailable")
                DetailRow(label: "Python", value: bootstrap.pythonAvailable ? "Available" : "Unavailable")
                DetailRow(label: "Hermes CLI", value: bootstrap.hermesCLIAvailable ? "Available" : "Unavailable")
                DetailRow(label: "TUI Gateway", value: bootstrap.tuiGatewayAvailable ? "Available" : "Unavailable")
                if let fallbackReason = bootstrap.fallbackReason {
                    DetailRow(label: "What to check", value: fallbackReason)
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking native chat runtime...")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    await store.nativeChatStore.refreshBootstrapStatus(force: true)
                }
            } label: {
                Label("Refresh chat status", systemImage: "arrow.clockwise")
            }

            Button {
                Task {
                    isTestingChat = true
                    chatTestResult = await store.nativeChatStore.runChatTest()
                    isTestingChat = false
                }
            } label: {
                HStack {
                    if isTestingChat {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isTestingChat ? "Testing chat..." : "Test chat")
                }
            }
            .disabled(isTestingChat || !store.nativeChatStore.canUseNativeChat)

            if let chatTestResult {
                Text(chatTestResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Diagnostics", isExpanded: $showsGatewayDiagnostics) {
                if store.nativeChatStore.rawEvents.isEmpty {
                    Text("No gateway events captured yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.nativeChatStore.rawEvents.suffix(12).reversed())) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.type)
                                .font(.caption.weight(.semibold))
                            Text(event.rawLine ?? JSONValue.object(event.payload).displayString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
    }

    private func nativeChatSummary(for connection: ConnectionProfile) -> String {
        "Native chat · \(connection.resolvedHermesProfileName) · SSH"
    }

    private var savedConnectionGroups: [ConnectionHostGroup] {
        let grouped = Dictionary(grouping: store.connections, by: \.hostConnectionFingerprint)
        return grouped.values.map { connections in
            let sortedConnections = connections.sorted {
                if $0.resolvedHermesProfileName == $1.resolvedHermesProfileName {
                    return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                }
                return $0.resolvedHermesProfileName.localizedCaseInsensitiveCompare($1.resolvedHermesProfileName) == .orderedAscending
            }
            let first = sortedConnections[0]
            return ConnectionHostGroup(
                id: first.hostConnectionFingerprint,
                title: first.displayDestination,
                connections: sortedConnections
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func addProfile(to group: ConnectionHostGroup) {
        guard let base = group.connections.first else { return }
        let credential = (try? store.credential(for: base)) ?? SSHCredentialRecord()
        editingConnectionID = nil
        draft = ConnectionDraft(profileTemplateFrom: base, credential: credential)
        isPresentingEditor = true
    }
}

private struct ConnectionsGuideStep: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectionHostGroup: Identifiable {
    let id: String
    let title: String
    let connections: [ConnectionProfile]
}

#endif
